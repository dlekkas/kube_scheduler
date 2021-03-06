package scheduler

import (
	"context"
	"log"
	"sort"
	"time"

	"ethz.ch/ccsched/controller"
	"github.com/shirou/gopsutil/v3/cpu"
)

// A dyncamic scheduler that keeps memcached running on one dedicated core.
const (
	cpuWnd          = 3
	ncpu            = 4
	cpuStatInterval = 500 // time in ms between each cpu stat update.
	lowUsageThresh  = 40
	highUsageThresh = 85
)

type MC1Scheduler struct {
	jobs          map[string]*controller.JobInfo
	createdJobs   map[string]bool
	runningJobs   map[string]bool
	pausedJobs    map[string]bool
	completedJobs int
	mc1core       bool // whether memcached is running only on one core.
	cpuStat       [ncpu][cpuWnd]float64
}

func (s *MC1Scheduler) Init(ctx context.Context, cli *controller.Controller) {
	s.jobs = map[string]*controller.JobInfo{
		"ferret":       {Name: "ferret", Threads: 2, Eta: 400 * time.Second},
		"freqmine":     {Name: "freqmine", Threads: 2, Eta: 270 * time.Second},
		"blackscholes": {Name: "blackscholes", Threads: 2, Eta: 150 * time.Second},
		"splash2x-fft": {Name: "splash2x-fft", Threads: 2, Eta: 120 * time.Second},
		"dedup":        {Name: "dedup", Threads: 1, Eta: 60 * time.Second},
		"canneal":      {Name: "canneal", Threads: 1, Eta: 280 * time.Second},
	}

	s.createdJobs = make(map[string]bool)
	s.runningJobs = make(map[string]bool)
	s.pausedJobs = make(map[string]bool)
	for id, job := range s.jobs {
		cli.CreateJob(ctx, job)
		s.createdJobs[id] = true
	}

	for core, stat := range s.cpuStat {
		for t := range stat {
			s.cpuStat[core][t] = 100
		}
	}

	// Assume memcached run on 2 cores at the start.
	s.mc1core = false

}

func (s *MC1Scheduler) Run(ctx context.Context, cli *controller.Controller) {
	numJobs := len(s.jobs)
	for s.completedJobs != numJobs {
		s.updateCpuStat()

		cpu0HighUsage := true
		cpu0LowUsage := true
		for _, perc := range s.cpuStat[0] {
			if perc < highUsageThresh {
				cpu0HighUsage = false
			}
			if perc > lowUsageThresh {
				cpu0LowUsage = false
			}
		}

		// Get available jobs for single and double-threaded jobs respectively.
		availJobs1, availJobs2 := s.populateAvailableJobs()

		if cpu0HighUsage && s.mc1core {
			// memcached run on 2 cores to avoid SLO violation.
			cli.SetMemcachedCpuAffinity(controller.CpuList{0, 1})
			cpuJobs := s.getCpuJobs() // will not contain memcached for cpu1.
			for _, id := range cpuJobs[1] {
				s.pauseJob(ctx, cli, s.jobs[id])
			}
			s.mc1core = false
		}

		if cpu0LowUsage && !s.mc1core && len(availJobs1)+len(availJobs2) > 0 {
			// memcached run on 1 core to spare resources for PARSEC.
			cli.SetMemcachedCpuAffinity(controller.CpuList{0})
			s.mc1core = true
		}

		// Schedule jobs based on available cpus, favoring ones that are expected to finish earlier.
		cpuJobs := s.getCpuJobs()
		availCpus := make([]int, 0, ncpu)
		// Favor cpu2, cpu3 because jobs are less likely to be paused.
		for core := ncpu - 1; core >= 1; core-- {
			if len(cpuJobs[core]) == 0 {
				availCpus = append(availCpus, core)
			}
		}

		// Handle single and double-threaded jobs separately.
		if len(availCpus) >= 2 && len(availJobs2) > 0 {
			job := availJobs2[0]
			cli.SetJobCpuAffinity(ctx, job, availCpus)
			s.startOrUnpauseJob(ctx, cli, job)
			availCpus = availCpus[2:]
			availJobs2 = availJobs2[1:]
		}

		for len(availCpus) > 0 && len(availJobs1) > 0 {
			job := availJobs1[0]
			cli.SetJobCpuAffinity(ctx, job, availCpus[:1])
			s.startOrUnpauseJob(ctx, cli, job)
			availCpus = availCpus[1:]
			availJobs1 = availJobs1[1:]
		}

		// Check for completed jobs.
		for id := range s.runningJobs {
			res, err := cli.ContainerInspect(ctx, id)
			if err != nil {
				log.Fatal(err)
			}
			if res.State.Status == "exited" {
				// Job has completed.
				s.completedJobs++
				log.Println("Completed job", id)
				delete(s.runningJobs, id)
			}
		}

	}
}

// Find all available jobs and categorize them into single or multi-threaded jobs sorted by ETA.
func (s *MC1Scheduler) populateAvailableJobs() (singleThreaded, multiThreaded []*controller.JobInfo) {
	singleThreaded = make([]*controller.JobInfo, 0, len(s.jobs))
	multiThreaded = make([]*controller.JobInfo, 0, len(s.jobs))
	for id := range s.createdJobs {
		job := s.jobs[id]
		if job.Threads == 1 {
			singleThreaded = append(singleThreaded, job)
		} else {
			multiThreaded = append(multiThreaded, job)
		}
	}
	for id := range s.pausedJobs {
		job := s.jobs[id]
		if job.Threads == 1 {
			singleThreaded = append(singleThreaded, job)
		} else {
			multiThreaded = append(multiThreaded, job)
		}
	}

	sort.Slice(singleThreaded, func(i, j int) bool {
		return singleThreaded[i].Eta < singleThreaded[j].Eta
	})

	sort.Slice(multiThreaded, func(i, j int) bool {
		return multiThreaded[i].Eta < multiThreaded[j].Eta
	})
	return
}

func (s *MC1Scheduler) startJob(ctx context.Context, cli *controller.Controller, job *controller.JobInfo) {
	id := job.Name
	cli.StartJob(ctx, id)
	job.LastUnpaused = time.Now()
	s.runningJobs[id] = true
	delete(s.createdJobs, id)
}

func (s *MC1Scheduler) pauseJob(ctx context.Context, cli *controller.Controller, job *controller.JobInfo) {
	id := job.Name
	if err := cli.PauseJob(ctx, id); err != nil {
		log.Printf("Error pausing job %v: %v", id, err)
	} else {
		elapsedTime := time.Since(job.LastUnpaused)
		if elapsedTime > job.Eta {
			log.Println("ETA underestimated for job", job.Name)
			job.Eta = 15
		} else {
			job.Eta -= elapsedTime
		}
		delete(s.runningJobs, id)
		s.pausedJobs[id] = true
	}
}

func (s *MC1Scheduler) unpauseJob(ctx context.Context, cli *controller.Controller, job *controller.JobInfo) {
	id := job.Name
	cli.UnpauseJob(ctx, id)
	job.LastUnpaused = time.Now()
	delete(s.pausedJobs, id)
	s.runningJobs[id] = true
}

func (s *MC1Scheduler) startOrUnpauseJob(ctx context.Context, cli *controller.Controller, job *controller.JobInfo) {
	if _, isCreated := s.createdJobs[job.Name]; isCreated {
		s.startJob(ctx, cli, job)
	}
	if _, isPaused := s.pausedJobs[job.Name]; isPaused {
		s.unpauseJob(ctx, cli, job)
	}
}

// Maintain a window of cpu percentage usage per core.
func (s *MC1Scheduler) updateCpuStat() {
	cpuUsage, err := cpu.Percent(cpuStatInterval*time.Millisecond, true)
	if err != nil {
		log.Fatal("Error geting cpu usage:", err)
	}
	for c := 0; c < ncpu; c++ {
		for i := cpuWnd - 1; i >= 1; i-- {
			s.cpuStat[c][i] = s.cpuStat[c][i-1]
		}
		s.cpuStat[c][0] = cpuUsage[c]
	}

	log.Println("cpu usage: ", cpuUsage)
}

// Get running jobs on all cpus.
func (s *MC1Scheduler) getCpuJobs() (cpuJobs [ncpu][]string) {
	cpuJobs[0] = append(cpuJobs[0], "memcached")
	if !s.mc1core {
		cpuJobs[1] = append(cpuJobs[1], "memcached")
	}
	for id := range s.runningJobs {
		for _, core := range s.jobs[id].CpuList {
			cpuJobs[core] = append(cpuJobs[core], id)
		}
	}
	return
}

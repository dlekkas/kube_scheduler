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
// Only 1 PARSEC job is running at a time.

type MC1LargeScheduler struct {
	jobs          map[string]*controller.JobInfo
	createdJobs   map[string]bool
	runningJobs   map[string]bool
	pausedJobs    map[string]bool
	completedJobs int
	mc1core       bool // whether memcached is running only on one core.
	cpuStat       [ncpu][cpuWnd]float64
}

func (s *MC1LargeScheduler) Init(ctx context.Context, cli *controller.Controller) {
	s.jobs = map[string]*controller.JobInfo{
		"ferret":       {Name: "ferret", Threads: 3, Eta: 320 * time.Second},
		"freqmine":     {Name: "freqmine", Threads: 3, Eta: 200 * time.Second},
		"blackscholes": {Name: "blackscholes", Threads: 3, Eta: 90 * time.Second},
		"dedup":        {Name: "dedup", Threads: 3, Eta: 35 * time.Second},
		"canneal":      {Name: "canneal", Threads: 3, Eta: 240 * time.Second},
		"splash2x-fft": {Name: "splash2x-fft", Threads: 2, Eta: 110 * time.Second},
	}

	s.createdJobs = make(map[string]bool)
	s.runningJobs = make(map[string]bool)
	s.pausedJobs = make(map[string]bool)
	for id, job := range s.jobs {
		cli.CreateJob(ctx, job)
		s.createdJobs[id] = true
	}

	// Assume memcached run on 2 cores at the start.
	s.mc1core = false

}

func (s *MC1LargeScheduler) Run(ctx context.Context, cli *controller.Controller) {
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

		if cpu0HighUsage && s.mc1core {
			// memcached run on 2 cores to avoid SLO violation.
			cli.SetMemcachedCpuAffinity(controller.CpuList{0, 1})
			cpuJobs := s.getCpuJobs() // will not contain memcached for cpu1.
			for _, id := range cpuJobs[1] {
				cli.SetJobCpuAffinity(ctx, s.jobs[id], controller.CpuList{2, 3})
			}
			s.mc1core = false
		}

		if cpu0LowUsage && !s.mc1core {
			// memcached run on 1 core to spare resources for PARSEC.
			cli.SetMemcachedCpuAffinity(controller.CpuList{0})
			s.mc1core = true
		}

		cpuJobs := s.getCpuJobs()
		if len(cpuJobs[1]) == 0 {
			// Make use of the extra core.
			for id := range s.runningJobs {
				if id != "splash2x-fft" {
					cli.SetJobCpuAffinity(ctx, s.jobs[id], controller.CpuList{1, 2, 3})
				}
			}
		}

		// Handle fft jobs separately.
		fftJob := s.jobs["splash2x-fft"]
		cpuJobs = s.getCpuJobs()
		availCpus := make([]int, 0, ncpu)
		for core := ncpu - 1; core >= 1; core-- {
			if len(cpuJobs[core]) == 0 {
				availCpus = append(availCpus, core)
			}
		}
		_, fftRunning := s.runningJobs["splash2x-fft"]
		availJobs := s.populateAvailableJobs()
		if hasJob(availJobs, "splash2x-fft") {
			if (!s.mc1core && len(availCpus) == 2) ||
				(len(availJobs) == 1 && len(availCpus) >= 2) {
				cli.SetJobCpuAffinity(ctx, fftJob, availCpus)
				s.startOrUnpauseJob(ctx, cli, fftJob)
			}
		}
		if fftRunning && len(cpuJobs[1]) == 0 && len(availJobs) > 0 {
			// Pause fft if other jobs can make use of the extra cpu.
			s.pauseJob(ctx, cli, fftJob)
		}

		// Schedule jobs sequentially, favoring ones that are expected to finish earlier.
		cpuJobs = s.getCpuJobs()
		availCpus = make([]int, 0, ncpu)
		availJobs = s.populateAvailableJobs()
		for core := ncpu - 1; core >= 1; core-- {
			if len(cpuJobs[core]) == 0 {
				availCpus = append(availCpus, core)
			}
		}
		if len(availCpus) >= 2 && len(availJobs) > 0 {
			job := availJobs[0]
			cli.SetJobCpuAffinity(ctx, job, availCpus)
			s.startOrUnpauseJob(ctx, cli, job)
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
func (s *MC1LargeScheduler) populateAvailableJobs() (availJobs []*controller.JobInfo) {
	availJobs = make([]*controller.JobInfo, 0, len(s.jobs))
	for id := range s.createdJobs {
		job := s.jobs[id]
		availJobs = append(availJobs, job)
	}
	for id := range s.pausedJobs {
		job := s.jobs[id]
		availJobs = append(availJobs, job)
	}

	sort.Slice(availJobs, func(i, j int) bool {
		return availJobs[i].Eta < availJobs[j].Eta
	})
	return
}

func (s *MC1LargeScheduler) startJob(ctx context.Context, cli *controller.Controller, job *controller.JobInfo) {
	id := job.Name
	cli.StartJob(ctx, id)
	job.LastUnpaused = time.Now()
	s.runningJobs[id] = true
	delete(s.createdJobs, id)
}

func (s *MC1LargeScheduler) pauseJob(ctx context.Context, cli *controller.Controller, job *controller.JobInfo) {
	id := job.Name
	if err := cli.PauseJob(ctx, id); err != nil {
		log.Printf("Error pausing job %v: %v", id, err)
	} else {
		elapsedTime := time.Now().Sub(job.LastUnpaused)
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

func (s *MC1LargeScheduler) unpauseJob(ctx context.Context, cli *controller.Controller, job *controller.JobInfo) {
	id := job.Name
	cli.UnpauseJob(ctx, id)
	job.LastUnpaused = time.Now()
	delete(s.pausedJobs, id)
	s.runningJobs[id] = true
}

func (s *MC1LargeScheduler) startOrUnpauseJob(ctx context.Context, cli *controller.Controller, job *controller.JobInfo) {
	if _, isCreated := s.createdJobs[job.Name]; isCreated {
		s.startJob(ctx, cli, job)
	}
	if _, isPaused := s.pausedJobs[job.Name]; isPaused {
		s.unpauseJob(ctx, cli, job)
	}
}

// Maintain a window of cpu percentage usage per core.
func (s *MC1LargeScheduler) updateCpuStat() {
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
func (s *MC1LargeScheduler) getCpuJobs() (cpuJobs [ncpu][]string) {
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

func hasJob(s []*controller.JobInfo, e string) bool {
	for _, a := range s {
		if a.Name == e {
			return true
		}
	}
	return false
}

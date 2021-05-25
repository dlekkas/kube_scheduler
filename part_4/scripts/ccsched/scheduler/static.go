package scheduler

import (
	"context"
	"log"
	"time"

	"ethz.ch/ccsched/controller"
	"github.com/shirou/gopsutil/v3/cpu"
)

type StaticScheduler struct {
	jobInfos      []controller.JobInfo
	availableJobs []controller.JobInfo
	runningJobs   map[string]controller.JobInfo
	completedJobs int
}

func (scheduler *StaticScheduler) JobInfos() []controller.JobInfo {
	return scheduler.jobInfos
}

func (scheduler *StaticScheduler) Init(ctx context.Context, cli *controller.Controller) {
	scheduler.jobInfos = []controller.JobInfo{
		{Name: "blackscholes", Threads: 2},
		{Name: "ferret", Threads: 2},
		{Name: "freqmine", Threads: 2},
		{Name: "dedup", Threads: 1},
		{Name: "canneal", Threads: 1},
		{Name: "splash2x-fft", Threads: 2},
	}

	// Make all the jobs ready to run.
	for _, job := range scheduler.jobInfos {
		cli.CreateJob(ctx, &job)
		scheduler.availableJobs = append(scheduler.availableJobs, job)
	}

	scheduler.runningJobs = make(map[string]controller.JobInfo)
	scheduler.completedJobs = 0
}

func (scheduler *StaticScheduler) Run(ctx context.Context, cli *controller.Controller) {
	numJobs := len(scheduler.availableJobs)

	cli.SetMemcachedCpuAffinity([]int{0, 1})
	availableCpus := []int{2, 3}

	for scheduler.completedJobs != numJobs {
		if len(scheduler.availableJobs) > 0 {
			// There are still jobs not running.
			nextJob := scheduler.availableJobs[0]
			if nextJob.Threads <= len(availableCpus) {
				// Allocate the available cpu cores to the job.
				cli.SetJobCpuAffinity(ctx, &nextJob, availableCpus[:nextJob.Threads])
				availableCpus = availableCpus[nextJob.Threads:]

				// Start the job.
				cli.StartJob(ctx, nextJob.Name)
				scheduler.runningJobs[nextJob.Name] = nextJob
				scheduler.availableJobs = scheduler.availableJobs[1:]
			}
		}

		// Block for one second to get cpu stats.
		cpuUsage, err := cpu.Percent(time.Second, true)
		if err != nil {
			log.Println("Error geting cpu usage:", err)
		} else {
			log.Println("cpu usage: ", cpuUsage)
		}

		// Check for completed jobs.
		for jobName, job := range scheduler.runningJobs {
			res, err := cli.ContainerInspect(ctx, jobName)
			if err != nil {
				log.Fatal(err)
			}
			if res.State.Status == "exited" {
				// Job has completed.
				availableCpus = append(availableCpus, job.CpuList...)
				scheduler.completedJobs++
				log.Println("Completed job", jobName)
				delete(scheduler.runningJobs, jobName)
			}
		}
	}
}

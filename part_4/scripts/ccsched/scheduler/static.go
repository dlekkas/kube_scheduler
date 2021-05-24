package scheduler

import (
	"context"
	"log"
	"time"

	"ethz.ch/ccsched/controller"
	"github.com/docker/docker/api/types"
	"github.com/shirou/gopsutil/v3/cpu"
)

type StaticJob struct {
	controller.JobInfo
	// More fields here.
}

type StaticScheduler struct {
	jobInfos      []controller.JobInfo
	availableJobs []StaticJob
	runningJobs   map[string]StaticJob
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
		cli.CreateSingleJob(ctx, job)
		scheduler.availableJobs = append(scheduler.availableJobs, StaticJob{JobInfo: job})
	}

	scheduler.runningJobs = make(map[string]StaticJob)
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
				cli.SetJobCpuAffinity(ctx, &nextJob.JobInfo, availableCpus[:nextJob.Threads])
				availableCpus = availableCpus[nextJob.Threads:]

				// Start the job.
				if err := cli.ContainerStart(ctx, nextJob.Name,
					types.ContainerStartOptions{}); err != nil {
					log.Fatal(err)
				}
				scheduler.runningJobs[nextJob.Name] = nextJob
				scheduler.availableJobs = scheduler.availableJobs[1:]
				log.Println("Started job", nextJob.Name)
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
package scheduler

import (
	"context"

	"ethz.ch/ccsched/controller"
)

// A dyncamic scheduler that keeps memcached running on one dedicated core.

type MC1Scheduler struct {
	jobs          map[string]controller.JobInfo
	availableJobs map[string]bool
	runningJobs   map[string]bool
	completedJobs int
}

func (s *MC1Scheduler) JobInfos() []controller.JobInfo {
	v := make([]controller.JobInfo, 0, len(s.jobs))
	for _, val := range s.jobs {
		v = append(v, val)
	}
	return v
}

func (s *MC1Scheduler) Init(ctx context.Context, cli *controller.Controller) {
	s.jobs = map[string]controller.JobInfo{
		"blackscholes": {Name: "blackscholes", Threads: 2},
		"ferret":       {Name: "ferret", Threads: 2},
		"freqmine":     {Name: "freqmine", Threads: 2},
		"dedup":        {Name: "dedup", Threads: 1},
		"canneal":      {Name: "canneal", Threads: 1},
		"splash2x-fft": {Name: "splash2x-fft", Threads: 2},
	}

	s.availableJobs = make(map[string]bool)
	s.runningJobs = make(map[string]bool)
	for id, job := range s.jobs {
		cli.CreateSingleJob(ctx, job)
		s.availableJobs[id] = true
	}

}

func (s *MC1Scheduler) Run(ctx context.Context, cli *controller.Controller) {
}

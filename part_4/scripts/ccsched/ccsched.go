package main

import (
	"context"
	"fmt"
	"log"
	"os"

	"ethz.ch/ccsched/controller"
	"ethz.ch/ccsched/scheduler"
	"github.com/docker/docker/client"
)

type Scheduler interface {
	// Initialize the Scheduler and create jobs.
	Init(ctx context.Context, cli *controller.Controller)

	// Execute the scheduler.
	Run(ctx context.Context, cli *controller.Controller)

	// A list of all jobs' metadata.
	JobInfos() []controller.JobInfo
}

func main() {
	if len(os.Args) <= 1 {
		fmt.Println("Usage: ccsched <result-dir>")
		os.Exit(1)
	}
	resultDir := os.Args[1]

	var err error
	ctx := context.Background()
	dockerClient, err := client.NewClientWithOpts(client.FromEnv, client.WithAPIVersionNegotiation())
	if err != nil {
		log.Fatal(err)
	}

	cli := &controller.Controller{Client: dockerClient}

	var sched Scheduler = &scheduler.StaticScheduler{}
	sched.Init(ctx, cli)
	defer cli.RemoveContainers(ctx, sched.JobInfos())
	sched.Run(ctx, cli)
	cli.WriteLogs(ctx, resultDir, sched.JobInfos())

}

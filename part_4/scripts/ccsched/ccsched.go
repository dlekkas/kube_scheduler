package main

import (
	"context"
	"fmt"
	"io"
	"log"
	"os"
	"path"

	"ethz.ch/ccsched/controller"
	"ethz.ch/ccsched/scheduler"
	"github.com/docker/docker/client"
)

type Scheduler interface {
	// Initialize the Scheduler and create jobs.
	Init(ctx context.Context, cli *controller.Controller)

	// Execute the scheduler.
	Run(ctx context.Context, cli *controller.Controller)
}

func main() {
	if len(os.Args) <= 1 {
		fmt.Println("Usage: ccsched <result-dir>")
		os.Exit(1)
	}
	resultDir := os.Args[1]

	if err := os.MkdirAll(resultDir, 0755); err != nil {
		panic(err)
	}

	// Print logs to stdout and save it as a file.
	logFile, err := os.OpenFile(path.Join(resultDir, "scheduler.log"),
		os.O_CREATE|os.O_APPEND|os.O_RDWR, 0666)
	if err != nil {
		panic(err)
	}
	mw := io.MultiWriter(os.Stdout, logFile)
	log.SetOutput(mw)

	ctx := context.Background()
	dockerClient, err := client.NewClientWithOpts(client.FromEnv, client.WithAPIVersionNegotiation())
	if err != nil {
		log.Fatal(err)
	}

	cli := &controller.Controller{Client: dockerClient}
	allJobs := []controller.JobInfo{
		{Name: "blackscholes"},
		{Name: "ferret"},
		{Name: "freqmine"},
		{Name: "dedup"},
		{Name: "canneal"},
		{Name: "splash2x-fft"},
	}

	// Remove any existing containers.
	cli.RemoveContainers(ctx, allJobs)

	var sched Scheduler = &scheduler.MC1Scheduler{}
	log.Printf("Running with scheduler %T", sched)
	defer cli.RemoveContainers(ctx, allJobs)
	sched.Init(ctx, cli)
	sched.Run(ctx, cli)
	cli.WriteLogs(ctx, resultDir, allJobs)

}

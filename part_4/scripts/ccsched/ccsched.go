package main

import (
	"context"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"path"
	"strconv"
	"strings"
	"time"

	"github.com/docker/docker/api/types"
	"github.com/docker/docker/api/types/container"
	"github.com/docker/docker/client"
	"github.com/shirou/gopsutil/v3/cpu"
)

var (
	cli *client.Client
)

type CpuList []int

type Job struct {
	name    string  // The name of the job.
	threads int     // Number of threads for the job.
	cpuList CpuList // Which cpu(s) are the jobs running on.
	cpuSen  float64 // Cpu sensitivity of the job.
}

func (cpuList CpuList) String() string {
	cpuStrList := make([]string, len(cpuList))
	for i, v := range cpuList {
		cpuStrList[i] = strconv.Itoa(v)
	}
	return strings.Join(cpuStrList, ",")
}

func getCommand(pkg string, threads int) []string {
	return []string{"./bin/parsecmgmt", "-a", "run",
		"-p", pkg, "-i", "native", "-n", strconv.Itoa(threads)}
}

// Create a single job. After the job is created, the job is in READY state.
func createSingleJob(ctx context.Context, job Job) {
	imageName := fmt.Sprintf("anakli/parsec:%v-native-reduced", job.name)
	pkg := job.name
	if job.name == "splash2x-fft" {
		pkg = "splash2x.fft"
	}

	out, err := cli.ImagePull(ctx, imageName, types.ImagePullOptions{})
	if err != nil {
		panic(err)
	}

	io.Copy(os.Stdout, out)
	command := getCommand(pkg, job.threads)
	_, err = cli.ContainerCreate(ctx, &container.Config{
		Image: imageName,
		Cmd:   command,
	}, nil, nil, nil, job.name)
	if err != nil {
		panic(err)
	}

	log.Println("Created job", job.name)

}

// Stops and remove the jobs in the job list.
func removeContainers(ctx context.Context, jobs []Job) {
	for _, job := range jobs {
		err := cli.ContainerRemove(ctx, job.name, types.ContainerRemoveOptions{Force: true})
		if err != nil {
			log.Printf("Error removing job %v: %v", job.name, err)
		} else {
			log.Println("Removed job", job.name)
		}
	}

}

func setContainerCpuAffinity(ctx context.Context, id string, cpuList CpuList) {
	if _, err := cli.ContainerUpdate(ctx, id, container.UpdateConfig{
		Resources: container.Resources{
			CpusetCpus: cpuList.String(),
		},
	}); err != nil {
		panic(err)
	}
}

func setMemcachedCpuAffinity(cpuList CpuList) {
	cmd := exec.Command("bash", "-c",
		"pidof memcached | xargs sudo taskset -a -cp "+cpuList.String())
	if err := cmd.Run(); err != nil {
		panic(err)
	}
}

func (job *Job) SetCpuList(ctx context.Context, cpuList CpuList) {
	setContainerCpuAffinity(ctx, job.name, cpuList)
	job.cpuList = cpuList
	log.Printf("Job %v running on cpu %v", job.name, cpuList)
}

func runScheduler(ctx context.Context, jobs []Job) {
	numJobs := len(jobs)
	runningJobs := make(map[string]Job)
	completedJobs := 0

	// Make all the jobs ready to run.
	for _, job := range jobs {
		createSingleJob(ctx, job)
	}

	setMemcachedCpuAffinity([]int{0, 1})
	availableCpus := []int{2, 3}

	for completedJobs != numJobs {
		if len(jobs) > 0 {
			// There are still jobs not running.
			// TODO: co-locate some jobs on the same CPU.
			nextJob := jobs[0]
			if nextJob.threads <= len(availableCpus) {
				// Allocate the available cpu cores to the job.
				nextJob.SetCpuList(ctx, availableCpus[:nextJob.threads])
				availableCpus = availableCpus[nextJob.threads:]

				// Start the job.
				if err := cli.ContainerStart(ctx, nextJob.name,
					types.ContainerStartOptions{}); err != nil {
					panic(err)
				}
				runningJobs[nextJob.name] = nextJob
				jobs = jobs[1:]
				log.Println("Started job", nextJob.name)
			}
		}

		// Block for one second to get cpu stats.
		cpuUsage, err := cpu.Percent(time.Second, true)
		if err != nil {
			log.Println("Error geting cpu usage:", err)
		} else {
			log.Println("cpu usage: ", cpuUsage)
		}
		// TODO: dynamically adjust the resources.

		// Inspect completed jobs.
		for jobName, job := range runningJobs {
			res, err := cli.ContainerInspect(ctx, jobName)
			if err != nil {
				panic(err)
			}
			if res.State.Status == "exited" {
				// Job has completed.
				availableCpus = append(availableCpus, job.cpuList...)
				completedJobs++
				log.Println("Completed job", jobName)
				delete(runningJobs, jobName)
			}
		}
	}
}

func writeLogs(ctx context.Context, resultDir string, jobs []Job) {
	logPath := path.Join(resultDir, "logs")
	_ = os.Mkdir(logPath, 0755)
	for _, job := range jobs {
		reader, err := cli.ContainerLogs(ctx, job.name, types.ContainerLogsOptions{
			ShowStdout: true,
		})
		if err != nil {
			log.Printf("Error getting logs for %v: %v", job.name, err)
			continue
		}

		fLog, err := os.Create(path.Join(logPath, job.name+".out"))
		if err != nil {
			log.Printf("Error creating logs file for %v: %v", job.name, err)
			continue
		}
		defer fLog.Close()

		_, err = io.Copy(fLog, reader)
		if err != nil && err != io.EOF {
			log.Printf("Error writing logs for %v: %v", job.name, err)
			continue
		}
	}

	infoPath := path.Join(resultDir, "info")
	_ = os.Mkdir(infoPath, 0755)
	for _, job := range jobs {
		_, info, err := cli.ContainerInspectWithRaw(ctx, job.name, false)
		if err != nil {
			log.Printf("Error getting info for %v: %v", job.name, err)
			continue
		}

		fInfo, err := os.Create(path.Join(infoPath, job.name+".json"))
		if err != nil {
			log.Printf("Error creating info file for %v: %v", job.name, err)
			continue
		}
		defer fInfo.Close()

		_, err = fInfo.Write(info)
		if err != nil {
			log.Printf("Error writing info for %v: %v", job.name, err)
			continue
		}
	}
}

func main() {
	if len(os.Args) <= 1 {
		fmt.Println("Usage: ccsched <result-dir>")
		os.Exit(1)
	}
	resultDir := os.Args[1]

	var err error
	ctx := context.Background()
	cli, err = client.NewClientWithOpts(client.FromEnv, client.WithAPIVersionNegotiation())
	if err != nil {
		panic(err)
	}

	jobs := []Job{
		{name: "blackscholes", threads: 2},
		{name: "ferret", threads: 2},
		{name: "freqmine", threads: 2},
		{name: "dedup", threads: 1},
		{name: "canneal", threads: 1},
		{name: "splash2x-fft", threads: 2},
	}

	defer removeContainers(ctx, jobs)

	runScheduler(ctx, jobs)

	writeLogs(ctx, resultDir, jobs)

}

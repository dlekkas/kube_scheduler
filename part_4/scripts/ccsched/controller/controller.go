package controller

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

	"github.com/docker/docker/api/types"
	"github.com/docker/docker/api/types/container"
	"github.com/docker/docker/client"
)

type Controller struct {
	*client.Client
}
type CpuList []int

type JobInfo struct {
	Name    string
	Threads int
	CpuList CpuList
}

func (cpuList CpuList) String() string {
	cpuStrList := make([]string, len(cpuList))
	for i, v := range cpuList {
		cpuStrList[i] = strconv.Itoa(v)
	}
	return strings.Join(cpuStrList, ",")
}

func getStartCommand(job JobInfo) []string {
	pkg := job.Name
	if pkg == "splash2x-fft" {
		pkg = "splash2x.fft"
	}
	return []string{"./bin/parsecmgmt", "-a", "run",
		"-p", pkg, "-i", "native", "-n", strconv.Itoa(job.Threads)}
}

// Create a single job. After the job is created, the job is in READY state.
func (cli *Controller) CreateSingleJob(ctx context.Context, job JobInfo) {
	id := job.Name
	imageName := fmt.Sprintf("anakli/parsec:%v-native-reduced", id)

	_, err := cli.ImagePull(ctx, imageName, types.ImagePullOptions{})
	if err != nil {
		log.Fatal(err)
	}

	command := getStartCommand(job)
	_, err = cli.ContainerCreate(ctx, &container.Config{
		Image: imageName,
		Cmd:   command,
	}, nil, nil, nil, id)
	if err != nil {
		log.Fatal(err)
	}

	log.Println("Created job", id)

}

// Stops and remove the jobs in the job list.
func (cli *Controller) RemoveContainers(ctx context.Context, jobs []JobInfo) {
	for _, job := range jobs {
		id := job.Name
		err := cli.ContainerRemove(ctx, id, types.ContainerRemoveOptions{Force: true})
		if err != nil {
			log.Printf("Error removing job %v: %v", id, err)
		} else {
			log.Println("Removed job", id)
		}
	}

}

func (cli *Controller) setContainerCpuAffinity(ctx context.Context, id string, cpuList CpuList) {
	if _, err := cli.ContainerUpdate(ctx, id, container.UpdateConfig{
		Resources: container.Resources{
			CpusetCpus: cpuList.String(),
		},
	}); err != nil {
		log.Fatal(err)
	}
}

func (cli *Controller) SetJobCpuAffinity(ctx context.Context, job *JobInfo, cpuList CpuList) {
	cli.setContainerCpuAffinity(ctx, job.Name, cpuList)
	job.CpuList = cpuList
	log.Printf("Job %v running on cpu %v", job.Name, cpuList)
}

func (cli *Controller) SetMemcachedCpuAffinity(cpuList CpuList) {
	cmd := exec.Command("bash", "-c",
		"pidof memcached | xargs sudo taskset -a -cp "+cpuList.String())

	stdoutStderr, err := cmd.CombinedOutput()
	if err != nil {
		log.Fatal(err)
	}
	log.Printf("%s\n", stdoutStderr)
	log.Printf("memcached running on cpu %v", cpuList)
}

func (cli *Controller) WriteLogs(ctx context.Context, resultDir string, jobs []JobInfo) {
	logPath := path.Join(resultDir, "logs")
	_ = os.MkdirAll(logPath, 0755)
	for _, job := range jobs {
		id := job.Name
		reader, err := cli.ContainerLogs(ctx, id, types.ContainerLogsOptions{
			ShowStdout: true,
		})
		if err != nil {
			log.Printf("Error getting logs for %v: %v", id, err)
			continue
		}

		fLog, err := os.Create(path.Join(logPath, id+".out"))
		if err != nil {
			log.Printf("Error creating logs file for %v: %v", id, err)
			continue
		}
		defer fLog.Close()

		_, err = io.Copy(fLog, reader)
		if err != nil && err != io.EOF {
			log.Printf("Error writing logs for %v: %v", id, err)
			continue
		}
	}

	infoPath := path.Join(resultDir, "info")
	_ = os.MkdirAll(infoPath, 0755)
	for _, job := range jobs {
		id := job.Name
		_, info, err := cli.ContainerInspectWithRaw(ctx, id, false)
		if err != nil {
			log.Printf("Error getting info for %v: %v", id, err)
			continue
		}

		fInfo, err := os.Create(path.Join(infoPath, id+".json"))
		if err != nil {
			log.Printf("Error creating info file for %v: %v", id, err)
			continue
		}
		defer fInfo.Close()

		_, err = fInfo.Write(info)
		if err != nil {
			log.Printf("Error writing info for %v: %v", id, err)
			continue
		}
	}
}

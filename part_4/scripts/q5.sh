#!/bin/bash

## Script for running the scheduler in Question 4.2.4
set -x

login_key=$HOME/.ssh/cloud-computing

qps_interval=5

PROJ_ROOT_DIR=..
RESULTS_DIR=${PROJ_ROOT_DIR}/results/question_4_2_5
mkdir -p ${RESULTS_DIR}

MEMCACHED_NAME=$(kubectl get nodes | grep memcache-server | awk '{print $1}')
INTERNAL_MEMCACHED_IP=$(kubectl get nodes -o wide | grep memcache-server | awk '{print $6}')

AGENT_NAME=$(kubectl get nodes | grep client-agent | awk '{print $1}')
INTERNAL_AGENT_IP=$(kubectl get nodes -o wide | grep client-agent | awk '{print $6}')

CLIENT_MEASURE_NAME=$(kubectl get nodes | grep client-measure | awk '{print $1}')

# Compile the scheduler
cd ccsched
SCHEDULER_NAME=ccsched
go mod tidy
env GOOS=linux GOARCH=amd64 go build -o build/${SCHEDULER_NAME}
gcloud compute scp --ssh-key-file=${login_key} \
  build/${SCHEDULER_NAME} \
  ubuntu@${MEMCACHED_NAME}:~/${SCHEDULER_NAME}
cd ..

res_dir=${RESULTS_DIR}
mkdir -p ${res_dir}

for i in $(seq 1 1); do
  echo "################ Rep ${i} ################"

  # Use 2 threads for memcached server.
  gcloud compute ssh --ssh-key-file=${login_key} ubuntu@${MEMCACHED_NAME} \
    --command="sudo sed -i '/^-t /c\-t 2' /etc/memcached.conf; sudo systemctl restart memcached; \
      sleep 5; pidof memcached | xargs sudo taskset -a -cp 0-1"
  sleep 10

  # Stop running measure and agent
  gcloud compute ssh --ssh-key-file=${login_key} ubuntu@${CLIENT_MEASURE_NAME} \
    --command="pkill -f mcperf"
  gcloud compute ssh --ssh-key-file=${login_key} ubuntu@${AGENT_NAME} \
    --command="pkill -f mcperf"

  # Initiate agent.
  gcloud compute ssh --ssh-key-file=${login_key} --zone=europe-west3-a ubuntu@${AGENT_NAME} \
    --command="./memcache-perf-dynamic/mcperf -T 16 -A > agent.dat" &

  # Load data into memcached.
  gcloud compute ssh --ssh-key-file=${login_key} ubuntu@${CLIENT_MEASURE_NAME} \
    --command="./memcache-perf-dynamic/mcperf -s ${INTERNAL_MEMCACHED_IP} --loadonly"

  # Start the memcached measurement.
  measure_res=latencies.raw
  gcloud compute ssh --ssh-key-file=${login_key} --zone=europe-west3-a ubuntu@${CLIENT_MEASURE_NAME} \
    --command="./memcache-perf-dynamic/mcperf -s ${INTERNAL_MEMCACHED_IP} \
        -a ${INTERNAL_AGENT_IP} --noload -T 16 -C 4 -D 4 -Q 1000 -c 4 \
        -t 1800 --qps_interval ${qps_interval} --qps_min 5000 --qps_max 100000 \
        --qps_seed 42 > ${measure_res}" &
  measure_pid=$!

  # Run the scheduler.
  current_ts=$(date -u +"%Y-%m-%dT%H-%M-%SZ")
  scheduler_res="scheduler_${current_ts}"
  gcloud compute ssh --ssh-key-file=${login_key} ubuntu@${MEMCACHED_NAME} \
    --command="./${SCHEDULER_NAME} ${scheduler_res}"

  # Copy scheduler results to host machine
  gcloud compute scp --recurse --ssh-key-file=${login_key} \
    ubuntu@${MEMCACHED_NAME}:~/${scheduler_res} \
    ${res_dir}/${scheduler_res} >/dev/null

  # Wait for the measurement to finish.
  wait $measure_pid

  # copy latency results from measurement node to host machine
  gcloud compute scp --ssh-key-file=${login_key} \
    ubuntu@${CLIENT_MEASURE_NAME}:~/${measure_res} \
    ${res_dir}/${scheduler_res}/${measure_res} >/dev/null

  # format the results, keep only relevant data for our plots and store as CSV
  tail -n +7 ${res_dir}/${scheduler_res}/${measure_res} | awk '{print $13, $17, $18}' | strings |
    tr ' ' ',' >${res_dir}/${scheduler_res}/latencies.csv

  # pass the result files into a python script to generate those plots
  python3 plot_scheduler.py --results-dir ${res_dir}/${scheduler_res} --qps-interval ${qps_interval}
done

# stop agent
gcloud compute ssh --ssh-key-file=${login_key} ubuntu@${AGENT_NAME} \
  --command="pkill -f mcperf"

#!/bin/bash

## Script for running the scheduler in Question 4.2.3
set -x

n_reps=$1
if [ "$#" -ne 1 ]; then
	echo "Usage: ./run_scheduler.sh <n-reps>"
	exit 1
fi

login_key=$HOME/.ssh/cloud-computing

PROJ_ROOT_DIR=..
RESULTS_DIR=${PROJ_ROOT_DIR}/results/question_4_2_3
mkdir -p ${RESULTS_DIR}

MEMCACHED_NAME=$(kubectl get nodes | grep memcache-server | awk '{print $1}')
INTERNAL_MEMCACHED_IP=$(kubectl get nodes -o wide | grep memcache-server | awk '{print $6}')

AGENT_NAME=$(kubectl get nodes | grep client-agent | awk '{print $1}')
INTERNAL_AGENT_IP=$(kubectl get nodes -o wide | grep client-agent | awk '{print $6}')

CLIENT_MEASURE_NAME=$(kubectl get nodes | grep client-measure | awk '{print $1}')

# Use 2 threads for memcached server.
gcloud compute ssh --ssh-key-file=${login_key} ubuntu@${MEMCACHED_NAME} \
	--command="sudo sed -i '/^-t /c\-t 2' /etc/memcached.conf; sudo systemctl restart memcached"
sleep 10

# Load data into memcached.
gcloud compute ssh --ssh-key-file=${login_key} ubuntu@${CLIENT_MEASURE_NAME} \
	--command="./memcache-perf-dynamic/mcperf -s ${INTERNAL_MEMCACHED_IP} --loadonly"

# Stop running measure and agent
gcloud compute ssh --ssh-key-file=${login_key} ubuntu@${CLIENT_MEASURE_NAME} \
	--command="pkill -f mcperf"
gcloud compute ssh --ssh-key-file=${login_key} ubuntu@${AGENT_NAME} \
	--command="pkill -f mcperf"

# Initiate agent.
gcloud compute ssh --ssh-key-file=${login_key} --zone=europe-west3-a ubuntu@${AGENT_NAME} \
	--command="./memcache-perf-dynamic/mcperf -T 16 -A > agent.dat" &

# Compile the scheduler
cd ccsched
SCHEDULER_NAME=scheduler
go mod tidy
env GOOS=linux GOARCH=amd64 go build -o build/${SCHEDULER_NAME}
gcloud compute scp --ssh-key-file=${login_key} \
	build/${SCHEDULER_NAME} \
	ubuntu@${MEMCACHED_NAME}:~/${SCHEDULER_NAME}
cd ..

# # CSV that contains all the latencies of all runs and all different
# # combinations of threads and cores.
# final_csv=${RESULTS_DIR}/memcached_latencies.csv
# echo "T,C,p95,QPS,target" > ${final_csv}

for i in $(seq 1 ${n_reps}); do

	res_dir=${RESULTS_DIR}/rep_${i}
	mkdir -p ${res_dir}

	# Start the memcached measurement.
	measure_res=latencies.raw
	gcloud compute ssh --ssh-key-file=${login_key} --zone=europe-west3-a ubuntu@${CLIENT_MEASURE_NAME} \
		--command="./memcache-perf-dynamic/mcperf -s ${INTERNAL_MEMCACHED_IP} \
							-a ${INTERNAL_AGENT_IP} --noload -T 16 -C 4 -D 4 -Q 1000 -c 4 \
							-t 1800 --qps_interval 10 --qps_min 5000 --qps_max 100000 > ${measure_res}" &
	measure_pid=$!

	# Run the scheduler.
	parsec_res=parsec
	gcloud compute ssh --ssh-key-file=${login_key} ubuntu@${MEMCACHED_NAME} \
		--command="./${SCHEDULER_NAME} ${parsec_res}"
	
	# Copy scheduler results to host machine
	gcloud compute scp --ssh-key-file=${login_key} \
		ubuntu@${MEMCACHED_NAME}:~/${parsec_res} \
		${res_dir}/${parsec_res} >/dev/null

	# Wait for the measurement to finish.
	wait $measure_pid

	# copy latency results from measurement node to host machine
	gcloud compute scp --ssh-key-file=${login_key} \
		ubuntu@${CLIENT_MEASURE_NAME}:~/${measure_res} \
		${res_dir}/${measure_res} >/dev/null

	# format the results, keep only relevant data for our plots and store as CSV
	awk '{print $13, $17, $18}' ${res_dir}/${measure_res} | strings |
		tr ' ' ',' >${res_dir}/latencies.csv

	# # add results of current combination and run to final results
	# awk -v T=${T} -v C=${C} '{ printf("%d,%d,%s\n", T, C, $0); }' \
	# 	<(tail -n +2 ${res_dir}/latencies.csv) >>${final_csv}


done

# stop agent
gcloud compute ssh --ssh-key-file=${login_key} ubuntu@${AGENT_NAME} \
	--command="pkill -f mcperf"

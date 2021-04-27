#!/bin/bash

## Script for generating results for Question 4.2.1
set -x

login_key=$HOME/.ssh/cloud-computing

PROJ_ROOT_DIR=..
RESULTS_DIR=${PROJ_ROOT_DIR}/results/question_4_2_1
mkdir -p ${RESULTS_DIR}

n_reps=$1
if [ "$#" -ne 1 ]; then
	echo "Usage: ./memcache_perf.sh <n-reps>"
	exit 1
fi

max_threads=2
max_cores=2

MEMCACHED_NAME=`kubectl get nodes | grep memcache-server | awk '{print $1}'`
INTERNAL_MEMCACHED_IP=`kubectl get nodes -o wide | grep memcache-server | awk '{print $6}'`

AGENT_NAME=`kubectl get nodes | grep client-agent | awk '{print $1}'`
INTERNAL_AGENT_IP=`kubectl get nodes -o wide | grep client-agent | awk '{print $6}'`

CLIENT_MEASURE_NAME=`kubectl get nodes | grep client-measure | awk '{print $1}'`

# initiate agent
gcloud compute ssh --ssh-key-file=${login_key} ubuntu@${AGENT_NAME} \
	--command="./memcache-perf-dynamic/mcperf -T 16 -A > agent.dat" 2>/dev/null &

# CSV that contains all the latencies of all runs and all different
# combinations of threads and cores.
final_csv=${RESULTS_DIR}/memcached_latencies.csv
echo "T,C,p95,QPS,target" > ${final_csv}

for C in $( seq 1 ${max_cores} ); do

	for T in $( seq 1 ${max_threads} ); do

		for i in $( seq 1 ${n_reps} ); do

			res_dir=${RESULTS_DIR}/T${T}_C${C}/rep_${i}
			mkdir -p ${res_dir}

			# set the number of cores for memcached server
			gcloud compute ssh --ssh-key-file=${login_key} ubuntu@${MEMCACHED_NAME} \
				--command="sudo sed -i '/^-t /c\-t ${T}' /etc/memcached.conf; \
									 sudo systemctl restart memcached; sleep 10; \
									 pidof memcached | xargs sudo taskset -pc 0-$((C-1))"

			# we need to load memcached with values everytime it is restarted since it
			# only maintains data in memory and may be lost upon restarting the service
			gcloud compute ssh --ssh-key-file=${login_key} ubuntu@${CLIENT_MEASURE_NAME} \
				--command="./memcache-perf-dynamic/mcperf -s ${INTERNAL_MEMCACHED_IP} --loadonly"

			sleep 20

			measure_res=latencies.raw
			gcloud compute ssh --ssh-key-file=${login_key} ubuntu@${CLIENT_MEASURE_NAME} \
				--command="./memcache-perf-dynamic/mcperf -s ${INTERNAL_MEMCACHED_IP} \
									-a ${INTERNAL_AGENT_IP} --noload -T 16 -C 4 -D 4 -Q 1000 -c 4 \
									-t 5 --scan 5000:120000:5000 > ${measure_res}"

			# copy latency results from measurement node to host machine
			gcloud compute scp --ssh-key-file=${login_key} \
					ubuntu@${CLIENT_MEASURE_NAME}:~/${measure_res} \
					${res_dir}/${measure_res} >/dev/null

			# format the results, keep only relevant data for our plots and store as CSV
			awk '{print $13, $17, $18}' ${res_dir}/${measure_res} | strings  \
					| tr ' ' ',' > ${res_dir}/latencies.csv

			# add results of current combination and run to final results
			awk -v T=${T} -v C=${C} '{ printf("%d,%d,%s\n", T, C, $0); }' \
				<(tail -n +2 ${res_dir}/latencies.csv) >> ${final_csv}

		done
	done
done

# stop agent
gcloud compute ssh --ssh-key-file=${login_key} ubuntu@${AGENT_NAME} \
	--command="pkill -f mcperf"

# generate plot
python3 plot_q1.py --output ${RESULTS_DIR} --input-csv ${final_csv}

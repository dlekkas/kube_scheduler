#!/bin/bash
set -x

n_reps=$1
if [ "$#" -ne 1 ]; then
	echo "Usage: ./schedule.sh <n-reps>"
	exit 1
fi

login_key=$HOME/.ssh/cloud-computing

# A policy directory should contain a `parsec` directory inside which
# contains all the YAML files for the parsec jobs.
PROJ_ROOT_DIR=..
POLICY_DIR=${PROJ_ROOT_DIR}/scheduling/policy_1
RESULTS_DIR=${POLICY_DIR}/results

AGENT_A_NAME=`kubectl get nodes | grep client-agent-a | awk '{print $1}'`
AGENT_A_INTERNAL_IP=`kubectl get nodes -o wide | grep client-agent-a | awk '{print $6}'`
AGENT_B_INTERNAL_IP=`kubectl get nodes -o wide | grep client-agent-b | awk '{print $6}'`
AGENT_B_NAME=`kubectl get nodes | grep client-agent-b | awk '{print $1}'`

CLIENT_MEASURE_NAME=`kubectl get nodes | grep client-measure | awk '{print $1}'`

for i in $( seq 1 ${n_reps} ); do

	memcached_name=memcached-part3
	kubectl create -f ${PROJ_ROOT_DIR}/memcached.yaml
	kubectl expose pod memcached-pt3 --name ${memcached_name} --type LoadBalancer \
																	 --port 11211 --protocol TCP
	sleep 30

	# initiate agent A
	gcloud compute ssh --ssh-key-file=${login_key} ubuntu@${AGENT_A_NAME} \
		--zone=europe-west3-a --command="./memcache-perf/mcperf -T 2 -A > agent.dat" 2>/dev/null &
	# initiate agent B
	gcloud compute ssh --ssh-key-file=${login_key} ubuntu@${AGENT_B_NAME} \
		--zone=europe-west3-a --command="./memcache-perf/mcperf -T 4 -A > agent.dat" 2>/dev/null &

	MEMCACHED_IP=`kubectl get pods -o wide | grep memcached | awk '{print $6}'`
	gcloud compute ssh --ssh-key-file=${login_key} ubuntu@${CLIENT_MEASURE_NAME} \
		--zone=europe-west3-a --command="./memcache-perf/mcperf -s ${MEMCACHED_IP} --loadonly"

	res_dir=${RESULTS_DIR}/rep_${i}
	mkdir -p ${res_dir}

	# initiate monitoring
	python3 monitor.py --output ${res_dir}/utilization.png &

	# generate load at an approximately constant rate of 30K QPS and report latency
	# periodically every 20 sec
	measure_res=memcached_latencies.dat
	gcloud compute ssh --ssh-key-file=${login_key} ubuntu@${CLIENT_MEASURE_NAME} \
		--zone=europe-west3-a --command="./memcache-perf/mcperf -s ${MEMCACHED_IP} \
					 		-a ${AGENT_A_INTERNAL_IP} -a ${AGENT_B_INTERNAL_IP} --noload -T 6 \
							-C 4 -D 4 -Q 1000 -c 4 -t 20 --scan 30000:30300:10 > ${measure_res}"&
	current_ts=`date -u +"%Y-%m-%dT%H:%M:%SZ"`

	# allow for memcached load to warm-up
	sleep 10

	# create all Kubernetes jobs - order will be enforced through resource request
	for job in blackscholes dedup ferret freqmine canneal splash2x-fft; do
		kubectl create -f ${POLICY_DIR}/parsec/parsec-${job}.yaml
	done

	mkdir -p ${res_dir}/output
	for job in blackscholes dedup ferret freqmine canneal splash2x-fft; do
		parsec_job=parsec-${job}
		kubectl wait --for=condition=complete job/${parsec_job} --timeout=10m
		kubectl logs $(kubectl get pods --selector=job-name=${parsec_job} \
									 									--output=jsonpath='{.items[*].metadata.name}') \
																		> ${res_dir}/output/${parsec_job}.out
	done

	gcloud compute scp --ssh-key-file=${login_key} --zone=europe-west3-a \
				ubuntu@${CLIENT_MEASURE_NAME}:~/${measure_res} ${res_dir} >/dev/null

	kubectl get pods -o json > ${res_dir}/job_results.json
	python3 get_time_x.py ${res_dir}/job_results.json > ${res_dir}/job_times.txt
	python3 get_time_xx.py ${res_dir}/job_results.json ${current_ts} > \
												 ${res_dir}/job_results.csv

	# kill all spawned jobs
	kubectl delete jobs $(kubectl get jobs -o custom-columns=:.metadata.name)

	# stop monitoring
	pkill -SIGINT -f monitor.py

	# stop agent A
	gcloud compute ssh --ssh-key-file=${login_key} ubuntu@${AGENT_A_NAME} \
		--zone=europe-west3-a --command="pkill -f mcperf"
	# stop agent B
	gcloud compute ssh --ssh-key-file=${login_key} ubuntu@${AGENT_B_NAME} \
		--zone=europe-west3-a --command="pkill -f mcperf"

	# stop memcached load
	gcloud compute ssh --ssh-key-file=${login_key} ubuntu@${CLIENT_MEASURE_NAME} \
		--zone=europe-west3-a --command="pkill -f mcperf"

	kubectl delete service ${memcached_name}
	kubectl delete pods memcached-pt3

	sleep 30
done

# Generate all plots/tables required by the exercise
python3 res_aggregate.py --results-dir ${RESULTS_DIR} --n-reps ${n_reps}


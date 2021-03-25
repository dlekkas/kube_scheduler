#!/bin/bash

login_key=$HOME/.ssh/cloud-computing

CLIENT_AGENT_NAME=`kubectl get nodes -o wide | awk '{print $1}' | sed -n 2p`
CLIENT_MEASURE_NAME=`kubectl get nodes -o wide | awk '{print $1}' | sed -n 3p`

MEMCACHED_IP=`kubectl get pods -o wide | awk '{print $6}' | tail -n1`
INTERNAL_AGENT_IP=`kubectl get nodes -o wide | awk '{print $6}' | sed -n 2p`

agent_res=agents_results_part1.txt
measure_res=measure_results_part1.txt

# initiate the agent
gcloud compute ssh --ssh-key-file=${login_key} ubuntu@${CLIENT_AGENT_NAME} \
									 --command="./memcache-perf/mcperf -T 16 -A > ${agent_res}" &
# load the memcached database with key-value pairs
gcloud compute ssh --ssh-key-file=${login_key} ubuntu@${CLIENT_MEASURE_NAME} \
									 --command="./memcache-perf/mcperf -s ${MEMCACHED_IP} --loadonly"
# query memcached with throughput increasing from 5000 QPS to 55000 QPS in increments of 5000
gcloud compute ssh --ssh-key-file=${login_key} ubuntu@${CLIENT_MEASURE_NAME} \
									 --command="./memcache-perf/mcperf -s ${MEMCACHED_IP} -a ${INTERNAL_AGENT_IP} \
									 																	 --noload -T 16 -C 4 -D 4 -Q 1000 -c 4 -t 5 \
																										 --scan 5000:10000:5000 > ${measure_res}"
# stop the agent
gcloud compute ssh --ssh-key-file=${login_key} ubuntu@${CLIENT_AGENT_NAME} \
									 --command="pkill -f mcperf"

# copy result files to host machine from kubernetes nodes
gcloud compute scp --ssh-key-file=${login_key} ubuntu@${CLIENT_AGENT_NAME}:~/${agent_res} .
gcloud compute scp --ssh-key-file=${login_key} ubuntu@${CLIENT_MEASURE_NAME}:~/${measure_res} .

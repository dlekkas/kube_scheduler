#!/bin/bash

if [ "$#" -ne 2 ]; then
	echo "Usage: ./measure.sh <n-reps>"
	exit 1
fi

n_reps=$1

login_key=$HOME/.ssh/cloud-computing
results_dir=results
interf_dir=interference

CLIENT_AGENT_NAME=`kubectl get nodes -o wide | awk '{print $1}' | sed -n 2p`
CLIENT_MEASURE_NAME=`kubectl get nodes -o wide | awk '{print $1}' | sed -n 3p`
MEMCACHED_IP=`kubectl get pods -o wide | awk '{print $6}' | tail -n1`
INTERNAL_AGENT_IP=`kubectl get nodes -o wide | awk '{print $6}' | sed -n 2p`

mkdir -p ${results_dir}
results_dir=`realpath ${results_dir}`

agent_res=agent_results.dat
measure_res=measurements.dat

echo "-------------- No interference ---------------"
# initiate the agent
echo "Initiating client agent..."
gcloud compute ssh --ssh-key-file=${login_key} ubuntu@${CLIENT_AGENT_NAME} \
		--command="./memcache-perf/mcperf -T 16 -A > ${agent_res}" 2>/dev/null &

# load the memcached database with key-value pairs
echo "Loading memcached database with key-value pairs..."
gcloud compute ssh --ssh-key-file=${login_key} ubuntu@${CLIENT_MEASURE_NAME} \
		--command="./memcache-perf/mcperf -s ${MEMCACHED_IP} --loadonly"

for i in $( seq 1 ${n_reps} ); do
	# query memcached with throughput increasing from 5000 QPS to 55000 QPS in increments of 5000
	echo "Repetition ${i}: Querying memcached with increasing QPS..."
	gcloud compute ssh --ssh-key-file=${login_key} ubuntu@${CLIENT_MEASURE_NAME} \
			--command="./memcache-perf/mcperf -s ${MEMCACHED_IP} -a ${INTERNAL_AGENT_IP} \
																				--noload -T 16 -C 4 -D 4 -Q 1000 -c 4 -t 5 \
																				--scan 5000:55000:5000 > ${measure_res}"
	# copy results file from measurement node to host machine
	mkdir -p ${results_dir}/intf_none/rep_${i}
	res_file=${results_dir}/intf_none/rep_${i}/${measure_res}
	gcloud compute scp --ssh-key-file=${login_key} \
			ubuntu@${CLIENT_MEASURE_NAME}:~/${measure_res} ${res_file} >/dev/null

	# keep only the measurement lines and only relevant columns (P95 and QPS)
	sed -ni '1,12p' ${res_file}
	awk '{print $13, $17}' ${res_file} > tmpf && mv tmpf ${res_file}

	echo "Repetition ${i}: Measurements collected successfully."
	echo "Results stored in ${res_file}"
done

# stop the agent
echo "Stopping client agent..."
gcloud compute ssh --ssh-key-file=${login_key} ubuntu@${CLIENT_AGENT_NAME} \
		--command="pkill -f mcperf"
echo "----------------------------------------------"

cd ${interf_dir}
for f in *; do
	interf="${f%.*}"
	echo -e "\n-------------- Interference: ${interf} ---------------"

	# initiate the agent
	echo "Initiating client agent..."
	gcloud compute ssh --ssh-key-file=${login_key} ubuntu@${CLIENT_AGENT_NAME} \
			--command="./memcache-perf/mcperf -T 16 -A > ${agent_res}" 2>/dev/null &

	echo "Launching resource interference ${interf}..."
	kubectl create -f ${f}

	# make sure that resource has enough time to get created
	sleep 60

	# load the memcached database with key-value pairs
	echo "Loading memcached database with key-value pairs..."
	gcloud compute ssh --ssh-key-file=${login_key} ubuntu@${CLIENT_MEASURE_NAME} \
			--command="./memcache-perf/mcperf -s ${MEMCACHED_IP} --loadonly"

	for i in $( seq 1 ${n_reps} ); do
		# query memcached with throughput increasing from 5000 QPS to 55000 QPS in increments of 5000
		echo "Repetition ${i}: Querying memcached with increasing QPS..."
		gcloud compute ssh --ssh-key-file=${login_key} ubuntu@${CLIENT_MEASURE_NAME} \
				--command="./memcache-perf/mcperf -s ${MEMCACHED_IP} -a ${INTERNAL_AGENT_IP} \
																					--noload -T 16 -C 4 -D 4 -Q 1000 -c 4 -t 5 \
																					--scan 5000:55000:5000 > ${measure_res}"

		# copy results file from measurement node to host machine
		mkdir -p ${results_dir}/intf_${interf}/rep_${i}
		res_file=${results_dir}/intf_${interf}/rep_${i}/${measure_res}
		gcloud compute scp --ssh-key-file=${login_key} \
				ubuntu@${CLIENT_MEASURE_NAME}:~/${measure_res} ${res_file} >/dev/null

		# keep only the measurement lines and only relevant columns (P95 and QPS)
		sed -ni '1,12p' ${res_file}
		awk '{print $13, $17}' ${res_file} > tmpf && mv tmpf ${res_file}

		echo "Repetition ${i}: Measurements collected successfully."
		echo "Results stored in ${res_file}"
	done

	# stop the agent
	echo "Stopping client agent..."
	gcloud compute ssh --ssh-key-file=${login_key} ubuntu@${CLIENT_AGENT_NAME} \
			--command="pkill -f mcperf"

	# kill the interference job once we have finished collecting measurements
	echo "Killing interference job..."
	kubectl delete pods ${interf}

	echo "----------------------------------------------"
done



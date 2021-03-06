#!/bin/bash

ETH_ID="dilekkas"
GROUP_NO="035"
PROJ_ROOT_DIR=..

login_key=$HOME/.ssh/cloud-computing
bucket_id=gs://cca-eth-2021-group-${GROUP_NO}-${ETH_ID}/

# create a bucket in Google Cloud Storage (GCS) to store configuration only if
# the bucket doesn't already exist
gsutil ls -b ${bucket_id} &> /dev/null || gsutil mb ${bucket_id}

if [[ -z "$KOPS_STATE_STORE" ]]; then
	# make the env variable immediately available
	export KOPS_STATE_STORE=${bucket_id}
	# preserve the env variable - after running the script run `source ~/.bashrc`
	SHELL_CONF_FILE=$HOME/.`basename $SHELL`rc
	echo "export KOPS_STATE_STORE=${bucket_id}" >> $SHELL_CONF_FILE
	echo "Invoke 'source ~/.bashrc' to make KOPS_STATE_STORE env variable available"
fi

if [ ! -f ${login_key} ]; then
	echo "Creating an ssh key to login to Kubernetes nodes..."
	ssh-keygen -t rsa -b 4096 -f cloud-computing
fi

sed -i "s/group-XXX/group-${GROUP_NO}/g" ${PROJ_ROOT_DIR}/part1.yaml
sed -i "s/ethzid/${ETH_ID}/g" ${PROJ_ROOT_DIR}/part1.yaml

export PROJECT=`gcloud config get-value project`
export KOPS_FEATURE_FLAGS=AlphaAllowGCE   # to unlock GCE features

# create a kubernetes cluster based on the configuration file
kops create -f ${PROJ_ROOT_DIR}/part1.yaml
# add ssh key as a login key for our nodes
kops create secret --name part1.k8s.local sshpublickey admin -i ${login_key}.pub
# deploy cluster
kops update cluster --name part1.k8s.local --yes --admin
# validate cluster
kops validate cluster --wait 10m

echo "Cluster created successfully. Node details and status shown below:"
kubectl get nodes -o wide

echo "Launching memcached using Kubernetes..."
memcached_name=some-memcached-11211
kubectl create -f ${PROJ_ROOT_DIR}/memcache-t1-cpuset.yaml
kubectl expose pod some-memcached --name ${memcached_name} --type LoadBalancer \
																	--port 11211 --protocol TCP

# sleep enough for the deployed service to appear
sleep 60
kubectl get service ${memcached_name}

echo "Memcached service details are shown below:"
kubectl get pods -o wide

MEMCACHED_IPADDR=`kubectl get pods -o wide | awk '{print $6}' | tail -n1`

cat <<EOF >compile_mcperf.sh
#!/bin/bash
sudo apt-get update
sudo apt-get install libevent-dev libzmq3-dev git make g++ --yes
sudo cp /etc/apt/sources.list /etc/apt/sources.list~
sudo sed -Ei 's/^# deb-src /deb-src /' /etc/apt/sources.list
sudo apt-get update
sudo apt-get build-dep memcached --yes
cd && git clone https://github.com/shaygalon/memcache-perf.git
cd memcache-perf
make
EOF
chmod u+x compile_mcperf.sh

CLIENT_AGENT_NAME=`kubectl get nodes -o wide | awk '{print $1}' | sed -n 2p`
gcloud compute ssh --ssh-key-file=${login_key} ubuntu@${CLIENT_AGENT_NAME} \
									 --zone=europe-west3-a --command='bash -s' < compile_mcperf.sh

CLIENT_MEASURE_NAME=`kubectl get nodes -o wide | awk '{print $1}' | sed -n 3p`
gcloud compute ssh --ssh-key-file=${login_key} ubuntu@${CLIENT_MEASURE_NAME} \
									 --zone=europe-west3-a --command='bash -s' < compile_mcperf.sh

rm compile_mcperf.sh

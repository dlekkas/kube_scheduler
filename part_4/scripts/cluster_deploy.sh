#!/bin/bash
set -x

ETH_ID="dilekkas"
GROUP_NO="035"

PROJ_ROOT_DIR=..

login_key=$HOME/.ssh/cloud-computing
proj_id=cca-eth-2021-group-${GROUP_NO}

# create a bucket in Google Cloud Storage (GCS) to store configuration only if
# the bucket doesn't already exist
bucket_id=gs://${proj_id}-${ETH_ID}/
gsutil ls -b ${bucket_id} &> /dev/null || gsutil mb ${bucket_id}

if [ ! -f ${login_key} ]; then
	echo "Creating an ssh key to login to Kubernetes nodes..."
	ssh-keygen -t rsa -b 4096 -f cloud-computing
fi

export KOPS_STATE_STORE=${bucket_id}
export PROJECT=`gcloud config get-value project`
export KOPS_FEATURE_FLAGS=AlphaAllowGCE   # to unlock GCE features

# create a kubernetes cluster based on the configuration file
kops create -f ${PROJ_ROOT_DIR}/part4.yaml

# add ssh key as a login key for our nodes
kops create secret --name part4.k8s.local sshpublickey admin -i ${login_key}.pub

# deploy cluster
kops update cluster --name part4.k8s.local --yes --admin

# sleep to allow enough time for the cluster to deploy to reduce verbosity
sleep 180

# validate cluster
kops validate cluster --wait 10m

kubectl get nodes -o wide

cat <<EOF >install_mcperf_dynamic.sh
#!/bin/bash
sudo apt-get update
sudo apt-get install libevent-dev libzmq3-dev git make g++ --yes
sudo apt-get build-dep memcached --yes
git clone https://github.com/eth-easl/memcache-perf-dynamic.git
cd memcache-perf-dynamic
make
EOF
chmod u+x install_mcperf_dynamic.sh

sleep 20
CLIENT_AGENT_NAME=`kubectl get nodes | grep client-agent | awk '{print $1}'`
gcloud compute ssh --ssh-key-file=${login_key} ubuntu@${CLIENT_AGENT_NAME} \
									 --zone=europe-west3-a --command='bash -s' < install_mcperf_dynamic.sh

sleep 20
CLIENT_MEASURE_NAME=`kubectl get nodes | grep client-measure | awk '{print $1}'`
gcloud compute ssh --ssh-key-file=${login_key} ubuntu@${CLIENT_MEASURE_NAME} \
									 --zone=europe-west3-a --command='bash -s' < install_mcperf_dynamic.sh

sleep 20
INTERNAL_MEMCACHED_IP=`kubectl get nodes -o wide| grep memcache-server | awk '{print $6}'`

cat <<EOF >install_memcached.sh
#!/bin/bash
sudo apt update
sudo apt install -y memcached libmemcached-tools
sudo systemctl status memcached

# update the IP that memcached is listening on
sudo sed -i "/^-l /c\-l ${INTERNAL_MEMCACHED_IP}" /etc/memcached.conf
# update memcached's memory limit
sudo sed -i "/^-m /c\-m 1024" /etc/memcached.conf
# set a default number of memcached threads (default=1)
echo "-t 1" | sudo tee -a /etc/memcached.conf > /dev/null

# restart memcached to run with updated parameters
sudo systemctl restart memcached
EOF
chmod u+x install_memcached.sh

MEMCACHED_NAME=`kubectl get nodes | grep memcache-server | awk '{print $1}'`
gcloud compute ssh --ssh-key-file=${login_key} ubuntu@${MEMCACHED_NAME} \
									 --zone=europe-west3-a --command='bash -s' < install_memcached.sh

rm install_memcached.sh install_mcperf_dynamic.sh

# spin up metrics server for monitoring utilization across kube nodes
kubectl apply -f ${PROJ_ROOT_DIR}/metrics.yaml

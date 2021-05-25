#!/bin/bash
set -x

ETH_ID="dilekkas"
GROUP_NO="035"

PROJ_ROOT_DIR=..

login_key=$HOME/.ssh/cloud-computing
gcloud_id=cca-eth-2021-group-${GROUP_NO}
proj_id=cca-eth-2021-group-${GROUP_NO}-${ETH_ID}

# create a bucket in Google Cloud Storage (GCS) to store configuration only if
# the bucket doesn't already exist
bucket_id=gs://${proj_id}/
gsutil ls -b ${bucket_id} &> /dev/null || gsutil mb ${bucket_id}

if [ ! -f ${login_key} ]; then
	echo "Creating an ssh key to login to Kubernetes nodes..."
	ssh-keygen -t rsa -b 4096 -f cloud-computing
fi

sed -i "s/<your-gs-bucket>/${proj_id}/g" ${PROJ_ROOT_DIR}/part3.yaml

export KOPS_STATE_STORE=${bucket_id}
export PROJECT=${gcloud_id}
export KOPS_FEATURE_FLAGS=AlphaAllowGCE   # to unlock GCE features

# create a kubernetes cluster based on the configuration file
kops create -f ${PROJ_ROOT_DIR}/part3.yaml

# add ssh key as a login key for our nodes
kops create secret --name part3.k8s.local sshpublickey admin -i ${login_key}.pub

# deploy cluster
kops update cluster --name part3.k8s.local --yes --admin

# sleep to allow enough time for the cluster to deploy to reduce verbosity
sleep 180

# validate cluster
kops validate cluster --wait 10m

echo "Cluster created successfully. Node details and status shown below:"
kubectl get nodes -o wide

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

sleep 20
CLIENT_AGENT_A_NAME=`kubectl get nodes | grep client-agent-a | awk '{print $1}'`
gcloud compute ssh --ssh-key-file=${login_key} ubuntu@${CLIENT_AGENT_A_NAME} \
									 --zone=europe-west3-a --project=${gcloud_id} \
									 --command='bash -s' < compile_mcperf.sh

sleep 20
CLIENT_AGENT_B_NAME=`kubectl get nodes | grep client-agent-b | awk '{print $1}'`
gcloud compute ssh --ssh-key-file=${login_key} ubuntu@${CLIENT_AGENT_B_NAME} \
									 --zone=europe-west3-a --project=${gcloud_id} \
									 --command='bash -s' < compile_mcperf.sh

sleep 20
CLIENT_MEASURE_NAME=`kubectl get nodes | grep client-measure | awk '{print $1}'`
gcloud compute ssh --ssh-key-file=${login_key} ubuntu@${CLIENT_MEASURE_NAME} \
									 --zone=europe-west3-a --project=${gcloud_id} \
									 --command='bash -s' < compile_mcperf.sh

rm compile_mcperf.sh

# spin up metrics server for monitoring utilization across kube nodes
kubectl apply -f ${PROJ_ROOT_DIR}/metrics.yaml

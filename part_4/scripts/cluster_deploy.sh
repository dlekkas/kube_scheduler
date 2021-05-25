#!/bin/bash
set -e

ETH_ID="kaiszhang"
GROUP_NO="035"

PROJ_ROOT_DIR=..

login_key=$HOME/.ssh/cloud-computing
proj_id=cca-eth-2021-group-${GROUP_NO}

export KOPS_STATE_STORE=${bucket_id}
export PROJECT=$(gcloud config get-value project)
export KOPS_FEATURE_FLAGS=AlphaAllowGCE # to unlock GCE features

post_deploy=false
while getopts 'p' flag; do
  case "${flag}" in
  p) post_deploy=true ;;
  *) error "Unexpected option ${flag}" ;;
  esac
done

if [ "$post_deploy" = false ]; then
  # create a bucket in Google Cloud Storage (GCS) to store configuration only if
  # the bucket doesn't already exist
  bucket_id=gs://${proj_id}-${ETH_ID}/
  gsutil ls -b ${bucket_id} &>/dev/null || gsutil mb ${bucket_id}

  # modify part4.yaml bucket id.
  perl -i -pe "s/(?<= configBase: gs:\/\/${proj_id}-).*(?=\/part4.k8s.local)/${ETH_ID}/" ../part4.yaml

  if [ ! -f ${login_key} ]; then
    echo "Creating an ssh key to login to Kubernetes nodes..."
    ssh-keygen -t rsa -b 4096 -f cloud-computing
  fi

  # create a kubernetes cluster based on the configuration file
  kops create -f ${PROJ_ROOT_DIR}/part4.yaml

  # add ssh key as a login key for our nodes
  kops create secret --name part4.k8s.local sshpublickey admin -i ${login_key}.pub

  # deploy cluster
  kops update cluster --name part4.k8s.local --yes --admin

  # sleep to allow enough time for the cluster to deploy to reduce verbosity
  sleep 180
fi

# validate cluster
kops validate cluster --wait 10m

kubectl get nodes -o wide

echo "Configuring cluster..."

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
CLIENT_AGENT_NAME=$(kubectl get nodes | grep client-agent | awk '{print $1}')
echo "Installing mcperf_dynamic on ${CLIENT_AGENT_NAME}..."
gcloud compute ssh --ssh-key-file=${login_key} ubuntu@${CLIENT_AGENT_NAME} \
  --zone=europe-west3-a --command='bash -s' <install_mcperf_dynamic.sh

sleep 20
CLIENT_MEASURE_NAME=$(kubectl get nodes | grep client-measure | awk '{print $1}')
echo "Installing mcperf_dynamic on ${CLIENT_MEASURE_NAME}..."
gcloud compute ssh --ssh-key-file=${login_key} ubuntu@${CLIENT_MEASURE_NAME} \
  --zone=europe-west3-a --command='bash -s' <install_mcperf_dynamic.sh

sleep 20
INTERNAL_MEMCACHED_IP=$(kubectl get nodes -o wide | grep memcache-server | awk '{print $6}')

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

cat <<EOF >pull_parsec_images.sh
#!/bin/bash
# Pull all docker images beforehand.
docker pull -q anakli/parsec:splash2x-fft-native-reduced 
docker pull -q anakli/parsec:freqmine-native-reduced
docker pull -q anakli/parsec:ferret-native-reduced
docker pull -q anakli/parsec:canneal-native-reduced
docker pull -q anakli/parsec:dedup-native-reduced
docker pull -q anakli/parsec:blackscholes-native-reduced
EOF
chmod u+x pull_parsec_images.sh

MEMCACHED_NAME=$(kubectl get nodes | grep memcache-server | awk '{print $1}')
echo "Installing memcached on ${MEMCACHED_NAME}..."
gcloud compute ssh --ssh-key-file=${login_key} ubuntu@${MEMCACHED_NAME} \
  --zone=europe-west3-a --command='bash -s' <install_memcached.sh
echo "Adding user ubuntu to docker group..."
gcloud compute ssh --ssh-key-file=${login_key} ubuntu@${MEMCACHED_NAME} \
  --zone=europe-west3-a --command='sudo usermod -a -G docker ubuntu'

echo "Pulling all PARSEC images..."
gcloud compute ssh --ssh-key-file=${login_key} ubuntu@${MEMCACHED_NAME} \
  --zone=europe-west3-a --command='bash -s' <pull_parsec_images.sh

rm install_memcached.sh install_mcperf_dynamic.sh pull_parsec_images.sh

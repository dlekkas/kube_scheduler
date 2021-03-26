#!/bin/bash

ETH_ID="dilekkas"
GROUP_NO="035"

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

login_key=$HOME/.ssh/cloud-computing.pub
if [ ! -f ${login_key} ]; then
	echo "Creating an ssh key to login to Kubernetes nodes..."
	ssh-keygen -t rsa -b 4096 -f cloud-computing
fi

sed -i "s/group-XXX/group-${GROUP_NO}/g" part1.yaml
sed -i "s/ethzid/${ETH_ID}/g" part1.yaml

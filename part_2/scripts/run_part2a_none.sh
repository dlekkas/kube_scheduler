#!/bin/bash
set -e

if [ "$#" -ne 1 ]; then
  echo "Usage: ./run_parta.sh <n-reps>"
  exit 1
fi

n_reps=$1

results_dir=../results/part2a
mkdir -p ${results_dir}
ps_dir=../parsec-benchmarks/part2a

PARSEC_NODE=$(kubectl get nodes -o wide | awk '{print $1}' | sed -n 3p)

ib_name="none"

for i in $(seq 1 ${n_reps}); do
  echo "Rep ${i}: Running PARSEC jobs..."
  for fps in ${ps_dir}/*; do
    ps_name=$(yq eval ".metadata.name" ${fps})
    kubectl create -f ${fps}

    # Wait for job to finish.
    kubectl wait --for=condition=complete job/${ps_name} --timeout=20m

    fres=${results_dir}/${ib_name}/${ps_name}
    mkdir -p $fres
    kubectl logs $(kubectl get pods --selector=job-name=${ps_name} \
      --output=jsonpath='{.items[*].metadata.name}') >${fres}/raw.$i
  done
  kubectl delete jobs --all
done
kubectl delete pods --all

. ./env.sh
kops delete cluster part2a.k8s.local --yes

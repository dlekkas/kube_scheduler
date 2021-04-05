#!/bin/bash
set -e

if [ "$#" -ne 1 ]; then
  echo "Usage: ./run_partb.sh <n-reps>"
  exit 1
fi

n_reps=$1

results_dir=../results/part2b
mkdir -p ${results_dir}
ps_dir=../parsec-benchmarks/part2b

PARSEC_NODE=$(kubectl get nodes -o wide | awk '{print $1}' | sed -n 3p)

for i in $(seq 1 ${n_reps}); do
  for t in {1,2,4,8}; do
    echo "---- Rep ${i}: Running PARSEC jobs on ${t} thread(s) ----"
    for fps in ${ps_dir}/*.${t}.yaml; do
      ps_name=$(yq eval '.metadata.name' ${fps})
      kubectl create -f ${fps}

      # Wait for job to finish.
      kubectl wait --for=condition=complete job/${ps_name} --timeout=20m

      fres=${results_dir}/${ps_name}/t${t}
      mkdir -p $fres
      kubectl logs $(kubectl get pods --selector=job-name=${ps_name} \
        --output=jsonpath='{.items[*].metadata.name}') >${fres}/raw.$i
    done
    kubectl delete jobs --all
  done
done
kubectl delete pods --all
. ./env.sh
kops delete cluster part2b.k8s.local --yes

if [ "$#" -ne 1 ]; then
  echo "Usage: ./deploy.sh <part>"
  exit 1
fi

part=$1

export KOPS_STATE_STORE=gs://cca-eth-2021-group-035-kaiszhang/
PROJECT=$(gcloud config get-value project)
export KOPS_FEATURE_FLAGS=AlphaAllowGCE # to unlock the GCE features
kops create -f ../part2${part}.yaml
kops update cluster part2${part}.k8s.local --yes --admin
kops validate cluster --wait 10m
kubectl get nodes -o wide

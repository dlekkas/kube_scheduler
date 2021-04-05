if [ "$#" -ne 1 ]; then
  echo "Usage: ./deploy.sh <part>"
  exit 1
fi

part=$1

. ./env.sh
kops create -f ../part2${part}.yaml
kops update cluster part2${part}.k8s.local --yes --admin
kops validate cluster --wait 10m
kubectl get nodes -o wide

## _Part 1_

First, we need to deploy a 3 node cluster in Kubernetes. Two VMs will have 2 cores. One of these VMs will be the node where `memcached` and `iBench` will be deployed and another will be used for the `mcperf` memcached client which will measure the round-trip latency of memcached requests.

In order to deploy the cluster needed for part 1 of the exercise (along with creation of config store and ssh key if needed) we need to execute the following script (make sure to change ETHID variable in the script):
```
cd scripts
./cluster_deploy.sh
```

In order to collect measurements of running `memcached` alone and with each iBench source of interference (cpu, l1d, l1i, l2, llc, membw) we need to execute the following script while specifying the number of repetitions we want:
```
cd scripts
./measure.sh <n-reps>
```

Once the collection of measurements has finished it is important to destroy the cluster:
```
kops delete cluster part1.k8s.local --yes
```

The results are stored in the `results/` directory following a structure similar to the one presented in the exercise session: `results/intf_Y/rep_Z/measurements.dat` where Y refers to the interference component, and Z to the repetition number.

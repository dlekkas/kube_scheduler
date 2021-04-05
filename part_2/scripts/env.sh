export KOPS_STATE_STORE=gs://cca-eth-2021-group-035-kaiszhang/
PROJECT=$(gcloud config get-value project)
export KOPS_FEATURE_FLAGS=AlphaAllowGCE # to unlock the GCE features

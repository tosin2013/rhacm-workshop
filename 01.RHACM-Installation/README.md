# Exercise 1 - Advanced Cluster Management Installation 

In this exercise you will install the Advanced Cluster Management for Kubernetes operator. In order to comply with the workshop's rationale please install Red Hat Advanced Cluster Management for Kubernetes 2.10. During the installation, when choosing the update channel, select **release-2.10**.
https://access.redhat.com/documentation/en-us/red_hat_advanced_cluster_management_for_kubernetes/2.10

To install the up-to-date instance of Advanced Cluster Management, follow the steps presented in the **Installation** section of the workshop’s presentation - [https://docs.google.com/presentation/d/114op7K07TIOUhpTO1tVZUrJj6r1gzl6S7bu5OZl6rr8/edit?usp=sharing](https://docs.google.com/presentation/d/114op7K07TIOUhpTO1tVZUrJj6r1gzl6S7bu5OZl6rr8/edit?usp=sharing).

## Deploy OpenShift Cluster on AWS
This is an script used to deploy OpenShift on AWS
Pre-requisite: Install wget package as needed based on your OS.
```
sudo yum install wget
```

```
curl -OL https://gist.githubusercontent.com/tosin2013/76e47de3f32de4486ab4699c21b2188e/raw/959ae5dd2117edf124e4531cfae5216c722a3358/openshift-ai-workload.sh
# optional change  .compute[0].replicas to 3
vim openshift-ai-workload.sh
chmod +x openshift-ai-workload.sh
export aws_access_key_id="YOUR_ACCESS_KEY_ID"
export aws_secret_access_key="YOUR_SECRET_ACCESS_KEY"
export aws_region="YOUR_AWS_REGION"
./openshift-ai-workload.sh m6i.2xlarge
```

## Recommend: Configure SSL Certs
Pre-requisite: Install podman/docker
``` sudo yum install podman
```

```
export KUBECONFIG=/home/lab-user/cluster/auth/kubeconfig
curl -OL https://gist.githubusercontent.com/tosin2013/866522a1420ac22f477d2253121b4416/raw/35d6fa88675d63b6ecf58a827df32356ccf3ddde/configure-keys-on-openshift.sh
chmod +x configure-keys-on-openshift.sh
./configure-keys-on-openshift.sh <AWS_ACCESS_KEY> <AWS_SECRET_ACCESS_KEY> podman 
```
TIP: If facing issues with directory creation for letsencrypt, switch DIR (/home/lab-user/letsencrypt) in the script, instead of placing it /etc/letsencrypt/

# Deploy RHACM using kustommize
```
oc create -k https://github.com/tosin2013/sno-quickstarts/gitops/cluster-config/rhacm-operator/base
oc create -k https://github.com/tosin2013/sno-quickstarts/gitops/cluster-config/rhacm-instance/overlays/basic
```

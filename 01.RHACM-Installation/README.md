# Exercise 1 - Advanced Cluster Management Installation & Cluster Provisioning

In this exercise you will verify the Advanced Cluster Management for Kubernetes installation and provision managed clusters using Hive. This workshop targets **Red Hat Advanced Cluster Management 2.15** on **OpenShift 4.20**.

https://access.redhat.com/documentation/en-us/red_hat_advanced_cluster_management_for_kubernetes/2.15

## 1.1 Verify ACM Installation

If ACM is already installed on your hub cluster (as in this workshop environment), verify it:

```
<hub> $ oc get multiclusterhub -A
NAMESPACE                 NAME              STATUS    AGE
open-cluster-management   multiclusterhub   Running   ...

<hub> $ oc get csv -n open-cluster-management | grep advanced-cluster-management
advanced-cluster-management.v2.15.1   Advanced Cluster Management for Kubernetes   2.15.1   Succeeded
```

Confirm the subscription channel:
```
<hub> $ oc get sub advanced-cluster-management -n open-cluster-management -o jsonpath='{.spec.channel}'
release-2.15
```

## 1.2 Install ACM (If Not Pre-Installed)

If ACM is not yet installed, install the operator by selecting **release-2.15** as the update channel. Follow the steps in the **Installation** section of the workshop's presentation - [https://docs.google.com/presentation/d/114op7K07TIOUhpTO1tVZUrJj6r1gzl6S7bu5OZl6rr8/edit?usp=sharing](https://docs.google.com/presentation/d/114op7K07TIOUhpTO1tVZUrJj6r1gzl6S7bu5OZl6rr8/edit?usp=sharing).

Alternatively, deploy using Kustomize:
```
oc create -k https://github.com/tosin2013/sno-quickstarts/gitops/cluster-config/rhacm-operator/base
oc create -k https://github.com/tosin2013/sno-quickstarts/gitops/cluster-config/rhacm-instance/overlays/basic
```

## 1.3 Provision Managed Clusters via Hive on AWS

In this section you will provision two additional managed clusters using ACM's Hive provisioning to create a true multicluster environment:

- **standard-cluster** — SNO on `m6i.2xlarge` for application deployment and policy exercises
- **gpu-cluster** — SNO on `g6.4xlarge` with an NVIDIA L4 GPU for AI workload placement

### Step 1 - Create AWS Credential in ACM Console

Create the AWS credential through the ACM Console. This stores your AWS keys, pull secret, SSH keys, and base domain in a single managed credential.

1. Open the ACM Console — navigate to **Infrastructure → Credentials → Add credential**
2. Select **Amazon Web Services** as the provider type
3. Set:
   - **Credential name**: `aws-credentials`
   - **Namespace**: `aws-credentials` (create new)
4. Enter your **AWS Access Key ID** and **Secret Access Key**
5. Enter your **Base DNS domain** (your Route53 base domain, e.g., `sandbox1234.opentlc.com`)
6. Paste your **Red Hat pull secret** (from https://console.redhat.com/openshift/install/pull-secret)
7. Paste your **SSH public** and **private keys**
8. Click **Add**

Verify the credential was created:
```
<hub> $ oc get secret aws-credentials -n aws-credentials -o jsonpath='{.metadata.labels.cluster\.open-cluster-management\.io/type}'
aws
```

### Step 2 - Update Cluster Configurations

Extract the base domain and SSH public key from your credential:
```
<hub> $ export BASE_DOMAIN=$(oc get secret aws-credentials -n aws-credentials -o jsonpath='{.data.baseDomain}' | base64 -d)
<hub> $ export SSH_PUB_KEY=$(oc get secret aws-credentials -n aws-credentials -o jsonpath='{.data.ssh-publickey}' | base64 -d)
<hub> $ echo "Base domain: $BASE_DOMAIN"
```

Replace the placeholders in both cluster YAML files:
```
<hub> $ cd 01.RHACM-Installation/cluster-provisioning/
<hub> $ sed -i "s|<YOUR_BASE_DOMAIN>|${BASE_DOMAIN}|g" standard-cluster.yaml gpu-cluster.yaml
<hub> $ sed -i "s|<YOUR_SSH_PUBLIC_KEY>|${SSH_PUB_KEY}|g" standard-cluster.yaml gpu-cluster.yaml
<hub> $ cd -
```

### Step 3 - Copy Secrets to Cluster Namespaces and Provision

The Hive ClusterDeployment requires AWS credentials and the pull secret in each cluster's namespace. Copy them from the central credential:
```
<hub> $ for NS in standard-cluster gpu-cluster; do
  oc create namespace $NS --dry-run=client -o yaml | oc apply -f -
  oc create secret generic aws-credentials -n $NS \
    --from-literal=aws_access_key_id="$(oc get secret aws-credentials -n aws-credentials -o jsonpath='{.data.aws_access_key_id}' | base64 -d)" \
    --from-literal=aws_secret_access_key="$(oc get secret aws-credentials -n aws-credentials -o jsonpath='{.data.aws_secret_access_key}' | base64 -d)" \
    --dry-run=client -o yaml | oc apply -f -
  oc create secret generic pull-secret -n $NS \
    --from-literal=.dockerconfigjson="$(oc get secret aws-credentials -n aws-credentials -o jsonpath='{.data.pullSecret}' | base64 -d)" \
    --type=kubernetes.io/dockerconfigjson \
    --dry-run=client -o yaml | oc apply -f -
done
```

Provision the clusters:
```
<hub> $ oc apply -f 01.RHACM-Installation/cluster-provisioning/standard-cluster.yaml
<hub> $ oc apply -f 01.RHACM-Installation/cluster-provisioning/gpu-cluster.yaml
```

Cluster provisioning takes approximately 30-45 minutes. You can proceed with **Module 02** on `local-cluster` while the clusters provision.

Monitor provisioning status:
```
<hub> $ oc get clusterdeployment -A
NAMESPACE          NAME               PLATFORM   REGION      INSTALLED   VERSION   POWERSTATE
gpu-cluster        gpu-cluster        aws        us-east-2   false
standard-cluster   standard-cluster   aws        us-east-2   false
```

### Step 4 - Install NVIDIA GPU Operator on GPU Cluster

After the gpu-cluster is ready, apply the GPU Operator policy. This ACM policy automatically installs the NVIDIA GPU Operator on any cluster labeled `gpu=true`:

```
<hub> $ oc apply -f 01.RHACM-Installation/cluster-provisioning/gpu-operator-policy.yaml
```

### Step 5 - Verify All Clusters

Once provisioning completes, verify all managed clusters are available:
```
<hub> $ oc get managedclusters
NAME               HUB ACCEPTED   MANAGED CLUSTER URLS   JOINED   AVAILABLE   AGE
local-cluster      true           https://...            True     True        ...
standard-cluster   true           https://...            True     True        ...
gpu-cluster        true           https://...            True     True        ...
```

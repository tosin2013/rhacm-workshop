# Exercise 1 - Advanced Cluster Management Installation & Cluster Provisioning

In this exercise you will verify the Advanced Cluster Management for Kubernetes installation and provision managed clusters using Hive. This workshop targets **Red Hat Advanced Cluster Management 2.15** on **OpenShift 4.20**.

> **Tip:** This workshop was built on top of the **[Advanced Cluster Management for Kubernetes Demo](https://catalog.demo.redhat.com/catalog?item=babylon-catalog-prod/published.ocp4-acm-demo.prod&utm_source=webapp&utm_medium=share-link)** from the Red Hat Demo Platform. Order this catalog item to get a pre-configured hub cluster with ACM already installed, then continue with the verification steps below.

> **Platform note:** The commands below were written for **RHEL 9**. If you are running on **macOS**, be aware of two differences:
> - Replace `base64 -d` with `base64 -D` (or install GNU coreutils: `brew install coreutils` and use `gbase64 -d`).
> - Replace `sed -i "s|...|...|g"` with `sed -i '' "s|...|...|g"` (BSD sed requires an explicit empty backup suffix), or install GNU sed: `brew install gnu-sed` and use `gsed`.

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

> **Tip:** If you are using **ROSA (Red Hat OpenShift Service on AWS)** with Hosted Control Planes, ACM can provision and auto-import ROSA HCP clusters using CAPI instead of Hive. See the [Deploy ROSA with RHACM](https://cloud.redhat.com/experts/rosa/acm/) guide for that workflow.

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

### Optional — Raise maxPods Limit and Pre-Deployment Prerequisites Check

SNO hub clusters default to 250 pods, which can be exhausted during later exercises (Observability, ArgoCD). Raise the limit to 350 now — the node reboot (~10-15 min) will complete while you continue with the prerequisites check:

```
<hub> $ bash scripts/bump-max-pods.sh 350
```

Each SNO cluster requires ~3 Elastic IPs for NAT gateways (one per AZ). The default AWS quota is 5 EIPs, which is insufficient for two clusters. Run the pre-deployment script to check quotas, clean up orphaned resources, and request a quota increase if needed:

```
<hub> $ bash 01.RHACM-Installation/cluster-provisioning/pre-deploy-check.sh
```

The script detects your platform (RHEL or macOS) and will:
- Verify required tools are installed (`oc`, `curl`, `bc`, `unzip`) before proceeding
- Install the AWS CLI if not present (Linux zip installer or macOS pkg installer)
- Load AWS credentials from the ACM credential secret
- Check your Elastic IP quota and request an increase to 10 if below 6
- Release any orphaned (unassociated) Elastic IPs from failed deployments
- Check vCPU quotas for the instance types used

### Step 2 - Update Cluster Configurations

Extract the base domain and SSH public key from your credential:
```
# RHEL / Linux:
<hub> $ export BASE_DOMAIN=$(oc get secret aws-credentials -n aws-credentials -o jsonpath='{.data.baseDomain}' | base64 -d)
<hub> $ export SSH_PUB_KEY=$(oc get secret aws-credentials -n aws-credentials -o jsonpath='{.data.ssh-publickey}' | base64 -d)

# macOS — use -D instead of -d:
<hub> $ export BASE_DOMAIN=$(oc get secret aws-credentials -n aws-credentials -o jsonpath='{.data.baseDomain}' | base64 -D)
<hub> $ export SSH_PUB_KEY=$(oc get secret aws-credentials -n aws-credentials -o jsonpath='{.data.ssh-publickey}' | base64 -D)

<hub> $ echo "Base domain: $BASE_DOMAIN"
```

Replace the placeholders in both cluster YAML files:
```
<hub> $ cd 01.RHACM-Installation/cluster-provisioning/

# RHEL / Linux (GNU sed):
<hub> $ sed -i "s|<YOUR_BASE_DOMAIN>|${BASE_DOMAIN}|g" standard-cluster.yaml gpu-cluster.yaml
<hub> $ sed -i "s|<YOUR_SSH_PUBLIC_KEY>|${SSH_PUB_KEY}|g" standard-cluster.yaml gpu-cluster.yaml

# macOS (BSD sed) — note the empty quotes after -i:
<hub> $ sed -i '' "s|<YOUR_BASE_DOMAIN>|${BASE_DOMAIN}|g" standard-cluster.yaml gpu-cluster.yaml
<hub> $ sed -i '' "s|<YOUR_SSH_PUBLIC_KEY>|${SSH_PUB_KEY}|g" standard-cluster.yaml gpu-cluster.yaml

<hub> $ cd -
```

### Step 3 - Copy Secrets to Cluster Namespaces and Provision

The Hive ClusterDeployment requires AWS credentials and the pull secret in each cluster's namespace. Copy them from the central credential.

```
# RHEL / Linux:
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

# macOS — use base64 -D instead of base64 -d:
<hub> $ for NS in standard-cluster gpu-cluster; do
  oc create namespace $NS --dry-run=client -o yaml | oc apply -f -
  oc create secret generic aws-credentials -n $NS \
    --from-literal=aws_access_key_id="$(oc get secret aws-credentials -n aws-credentials -o jsonpath='{.data.aws_access_key_id}' | base64 -D)" \
    --from-literal=aws_secret_access_key="$(oc get secret aws-credentials -n aws-credentials -o jsonpath='{.data.aws_secret_access_key}' | base64 -D)" \
    --dry-run=client -o yaml | oc apply -f -
  oc create secret generic pull-secret -n $NS \
    --from-literal=.dockerconfigjson="$(oc get secret aws-credentials -n aws-credentials -o jsonpath='{.data.pullSecret}' | base64 -D)" \
    --type=kubernetes.io/dockerconfigjson \
    --dry-run=client -o yaml | oc apply -f -
done
```

Provision the clusters (run from the repo root, or adjust the paths if you already `cd`'d into the directory):
```
<hub> $ cd /home/vpcuser/rhacm-workshop
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

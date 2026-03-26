# Advanced Cluster Management Workshop

This document contains exercises and demonstrations for the Advanced Cluster Management workshop. The workshop is presented in - [https://docs.google.com/presentation/d/114op7K07TIOUhpTO1tVZUrJj6r1gzl6S7bu5OZl6rr8/edit?usp=sharing](https://docs.google.com/presentation/d/114op7K07TIOUhpTO1tVZUrJj6r1gzl6S7bu5OZl6rr8/edit?usp=sharing)

**Target versions:** OpenShift 4.20 / RHACM 2.15

## Base Environment

This workshop was built on top of the **[Advanced Cluster Management for Kubernetes Demo](https://catalog.demo.redhat.com/catalog?item=babylon-catalog-prod/published.ocp4-acm-demo.prod&utm_source=webapp&utm_medium=share-link)** from the Red Hat Demo Platform. Order this catalog item to get a pre-configured hub cluster with ACM already installed, then follow the modules below.

## Prerequisites

Participants in the workshop must have -
* A running OpenShift 4.20+ cluster with RHACM 2.15 installed (see **Base Environment** above).
* The `oc` CLI tool installed (the setup script will attempt to install it if missing).
* The `kubectl` CLI tool installed (the setup script will attempt to install it if missing).
* The `git` CLI tool installed.
* A GitHub account
* AWS credentials (for provisioning managed clusters via Hive)

## Platform Compatibility

| Platform | Status |
|----------|--------|
| **RHEL 9** (Red Hat Demo Platform bastion) | Fully tested |
| **macOS** | Supported, not fully tested. Scripts detect your OS and install tools via Homebrew. Some module exercises use GNU `sed -i` syntax -- you may need `brew install gnu-sed` and use `gsed` in place of `sed`. |
| **Windows** | Not supported. Use WSL2 or the RHEL bastion. |

## Quick Start

Clone the repository and run the setup validation script:
```
git clone https://github.com/tosin2013/rhacm-workshop.git
cd rhacm-workshop
./setup.sh
```

The setup script will:
1. Detect your platform (Linux or macOS) and check for required CLI tools (`oc`, `kubectl`, `git`).
2. Attempt to auto-install any missing tools via `dnf` (RHEL/Fedora) or `brew` (macOS).
3. Validate your OpenShift cluster, ACM installation, managed clusters, storage, and APIs.
4. Check AWS credentials if provisioning managed clusters (skip with `--skip-aws`).

## Workshop Modules

The repository is separated into 7 sections. Each section represents a stage in the workshop.
* [RHACM Installation & Cluster Provisioning](./01.RHACM-Installation)
* [Cluster Management](./02.Cluster-Management)
* [Observability](./03.Observability)
* [Application Lifecycle](./04.Application-Lifecycle)
* [Governance Risk and Compliance](./05.Governance-Risk-Compliance)
* [Advanced Policy Management](./06.Advanced-Policy-Management)
* [AI-Powered Operations](./07.AI-Operations)

Each section contains a `README.md` file that contains exercises which summarize the topic. When the participants finish the relevant section in the [workshop](https://docs.google.com/presentation/d/1LCPvIT_nF5hwnrfYdlD0Zie4zdDxc0kxZtW3Io5jfFk/edit?usp=sharing), they may start working on the associated exercise.

## Troubleshooting

### "Too many pods" / FailedScheduling

If you see pods stuck in `Pending` with an event like:

```
0/1 nodes are available: 1 Too many pods. preemption: 0/1 nodes are available: 1 No preemption victims found for incoming pod.
```

This means the node has hit the Kubernetes `maxPods` limit (default 250 on SNO clusters). This commonly happens during Exercise 3 (Observability) or Exercise 4 (ArgoCD) when many pods are deployed.

**Fix:** Run the included script to raise the limit to 350. This creates a `KubeletConfig` and triggers a node reboot (~10-15 minutes):

```
bash scripts/bump-max-pods.sh 350
```

Monitor the rollout with `oc get mcp master -w`. After the node returns, pending pods will schedule automatically.

### switch-to-grafana-admin.sh errors (Exercise 3)

This script lives in the `multicluster-observability-operator` repo, not this workshop repo. You must:

1. Clone the repo: `git clone --depth 1 https://github.com/stolostron/multicluster-observability-operator.git`
2. **Log into the Dev Grafana URL in your browser first** (the script looks up your user in the Grafana database -- if you haven't logged in, the user doesn't exist yet)
3. Run from the `tools` directory: `cd multicluster-observability-operator/tools && bash switch-to-grafana-admin.sh kube:admin`

## Workshop Architecture

```
Hub Cluster (OCP 4.20, ACM 2.15, SNO)
  ├── local-cluster   (self-managed, labels: environment=hub)
  ├── standard-cluster (Hive AWS SNO, labels: environment=dev / environment=production)
  └── gpu-cluster      (Hive AWS SNO g6.4xlarge, labels: gpu=true, accelerator=nvidia-l4)
```

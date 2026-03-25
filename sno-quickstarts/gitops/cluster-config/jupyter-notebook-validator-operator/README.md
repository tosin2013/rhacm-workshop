# Jupyter Notebook Validator Operator

Kubernetes operator for validating Jupyter notebooks in MLOps workflows.

> **Note**: This is a development deployment for manual installation. The operator is in the process of being submitted to OperatorHub.

## Prerequisites

- OpenShift 4.18, 4.19, or 4.20
- cert-manager installed on the cluster
- cluster-admin privileges

## Version Mapping

| Overlay | OpenShift Version | Operator Version | Image Tag |
|---------|-------------------|------------------|-----------|
| dev-ocp4.18 | 4.18+ | 1.0.7 | `quay.io/takinosh/jupyter-notebook-validator-operator:1.0.7-ocp4.18` |
| dev-ocp4.19 | 4.19+ | 1.0.8 | `quay.io/takinosh/jupyter-notebook-validator-operator:1.0.8-ocp4.19` |
| dev-ocp4.20 | 4.20+ | 1.0.9 | `quay.io/takinosh/jupyter-notebook-validator-operator:1.0.9-ocp4.20` |

## Manual Deployment

### Deploy the Operator

Choose the overlay matching your OpenShift version:

```bash
# For OpenShift 4.20
kustomize build gitops/cluster-config/jupyter-notebook-validator-operator/operator/overlays/dev-ocp4.20 | oc apply -f -

# For OpenShift 4.19
kustomize build gitops/cluster-config/jupyter-notebook-validator-operator/operator/overlays/dev-ocp4.19 | oc apply -f -

# For OpenShift 4.18
kustomize build gitops/cluster-config/jupyter-notebook-validator-operator/operator/overlays/dev-ocp4.18 | oc apply -f -
```

### Verify Deployment

```bash
# Check the operator pod is running
oc get pods -n jupyter-notebook-validator-operator

# Check the CRD is installed
oc get crd notebookvalidationjobs.mlops.mlops.dev
```

### Uninstall

```bash
# For OpenShift 4.20
kustomize build gitops/cluster-config/jupyter-notebook-validator-operator/operator/overlays/dev-ocp4.20 | oc delete -f -
```

## Usage Examples

### Basic Notebook Validation

Create a NotebookValidationJob to validate a notebook:

```yaml
apiVersion: mlops.mlops.dev/v1alpha1
kind: NotebookValidationJob
metadata:
  name: my-notebook-validation
  namespace: jupyter-notebook-validator-operator
spec:
  notebook:
    git:
      url: "https://github.com/tosin2013/jupyter-notebook-validator-test-notebooks.git"
      ref: "main"
    path: "notebooks/tier1-simple/01-hello-world.ipynb"
  podConfig:
    containerImage: "quay.io/jupyter/scipy-notebook:latest"
    resources:
      limits:
        cpu: "1000m"
        memory: "1Gi"
      requests:
        cpu: "500m"
        memory: "512Mi"
  timeout: "30m"
```

### Notebook Validation with Volumes

Mount PersistentVolumeClaims, ConfigMaps, or Secrets into your validation pods:

```yaml
apiVersion: mlops.mlops.dev/v1alpha1
kind: NotebookValidationJob
metadata:
  name: model-training-validation
  namespace: jupyter-notebook-validator-operator
spec:
  notebook:
    git:
      url: "https://github.com/tosin2013/jupyter-notebook-validator-test-notebooks.git"
      ref: "main"
    path: "notebooks/tier3-ml/train-model.ipynb"
  podConfig:
    containerImage: "quay.io/jupyter/pytorch-notebook:latest"
    resources:
      limits:
        cpu: "4000m"
        memory: "8Gi"
      requests:
        cpu: "2000m"
        memory: "4Gi"
    # Define volumes to attach to the pod
    volumes:
      # PVC for storing trained models (can be used with KServe pvc:// storageUri)
      - name: model-storage
        persistentVolumeClaim:
          claimName: model-outputs-pvc
      # PVC for input datasets
      - name: datasets
        persistentVolumeClaim:
          claimName: training-datasets
          readOnly: true
      # ConfigMap for configuration files
      - name: training-config
        configMap:
          name: hyperparameters
      # EmptyDir for temporary scratch space
      - name: scratch
        emptyDir:
          medium: ""
          sizeLimit: "5Gi"
    # Mount the volumes into the container
    volumeMounts:
      - name: model-storage
        mountPath: /models
      - name: datasets
        mountPath: /data
        readOnly: true
      - name: training-config
        mountPath: /config
      - name: scratch
        mountPath: /tmp/scratch
  timeout: "2h"
```

#### Creating the Required PVCs

Before running the validation job, create the PVCs:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: model-outputs-pvc
  namespace: jupyter-notebook-validator-operator
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
  storageClassName: ocs-storagecluster-ceph-rbd
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: training-datasets
  namespace: jupyter-notebook-validator-operator
spec:
  accessModes:
    - ReadOnlyMany
  resources:
    requests:
      storage: 50Gi
  storageClassName: ocs-storagecluster-cephfs
```

#### Supported Volume Types

| Type | Use Case |
|------|----------|
| `persistentVolumeClaim` | Persistent storage for models, datasets, outputs |
| `configMap` | Configuration files, hyperparameters |
| `secret` | Certificates, credentials, API keys |
| `emptyDir` | Temporary scratch space (ephemeral) |

## Features

- **Git Integration**: Clone notebooks from Git repositories (HTTPS, SSH) with credential support
- **Papermill Execution**: Execute notebooks using Papermill with configurable parameters
- **Golden Notebook Comparison**: Compare outputs against golden notebooks with configurable tolerances
- **Model Validation**: Validate notebooks against deployed ML models (KServe, OpenShift AI, vLLM, etc.)
- **Build Integration**: Auto-detect requirements.txt and build custom images using S2I or Tekton

## Documentation

- [GitHub Repository](https://github.com/tosin2013/jupyter-notebook-validator-operator)
- [Architecture Overview](https://github.com/tosin2013/jupyter-notebook-validator-operator/blob/main/docs/ARCHITECTURE_OVERVIEW.md)
- [Testing Guide](https://github.com/tosin2013/jupyter-notebook-validator-operator/blob/main/docs/TESTING_GUIDE.md)


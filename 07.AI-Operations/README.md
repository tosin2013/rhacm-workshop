# Exercise 7 - AI-Powered Operations

This module introduces AI-powered multicluster operations with Red Hat Advanced Cluster Management. You will:

- Deploy an AI inference workload to GPU-capable clusters using ArgoCD ApplicationSets and the Placement API
- Enable the OpenShift Lightspeed MCP Server to query your RHACM fleet via the MCP protocol

**Prerequisites:**
- Completed Module 01 (clusters provisioned and GPU Operator installed on gpu-cluster)
- The gpu-cluster has the label `gpu=true` and the NVIDIA GPU Operator installed
- OpenShift GitOps (ArgoCD) is installed on the hub cluster
- OpenShift Lightspeed is installed on the hub cluster

## 7A - AI Workload Placement via ApplicationSet

In this exercise, you will build a Flask-based GPU inference app from source on the target cluster using an OpenShift BuildConfig, and deploy it via an ArgoCD ApplicationSet that uses ACM's Placement API to route workloads to GPU-enabled clusters.

### Step 1 - Apply the GPU Operator Policy

If not already applied during Module 01, install the NVIDIA GPU Operator on all `gpu=true` clusters:

```
<hub> $ oc apply -f 01.RHACM-Installation/cluster-provisioning/gpu-operator-policy.yaml
```

Verify it becomes Compliant:

```
<hub> $ oc get policy policy-nvidia-gpu-operator -n rhacm-policies
NAME                         REMEDIATION ACTION   COMPLIANCE STATE   AGE
policy-nvidia-gpu-operator   enforce              Compliant          ...
```

### Step 2 - Verify GPU Cluster Readiness

Confirm the gpu-cluster is available:

```
<hub> $ oc get managedcluster gpu-cluster
NAME          HUB ACCEPTED   MANAGED CLUSTER URLS   JOINED   AVAILABLE   AGE
gpu-cluster   true           https://...            True     True        ...
```

### Step 3 - Register gpu-cluster in ArgoCD

The gpu-cluster lives in the `default` ManagedClusterSet but is not registered in ArgoCD by default. Apply the hub resources to register it:

```
<hub> $ oc apply -f 07.AI-Operations/exercise-placement/hub/managedclustersetbinding.yaml
<hub> $ oc apply -f 07.AI-Operations/exercise-placement/hub/placement.yaml
<hub> $ oc apply -f 07.AI-Operations/exercise-placement/hub/gitopscluster.yaml
```

This creates:
- A **ManagedClusterSetBinding** that makes the `default` ClusterSet available in the `openshift-gitops` namespace
- A **Placement** (`gpu-clusters`) that selects clusters with `gpu=true` and scores them by CPU and memory
- A **GitOpsCluster** that registers matched clusters in ArgoCD

Verify gpu-cluster appears as an ArgoCD cluster:

```
<hub> $ oc get secret -n openshift-gitops -l apps.open-cluster-management.io/acm-cluster
NAME                                               TYPE     DATA   AGE
gpu-cluster-application-manager-cluster-secret     Opaque   3      ...
local-cluster-application-manager-cluster-secret   Opaque   3      ...
```

Check the PlacementDecision selected gpu-cluster:

```
<hub> $ oc get placementdecision -n openshift-gitops -l cluster.open-cluster-management.io/placement=gpu-clusters \
    -o jsonpath='{.items[0].status.decisions[*].clusterName}'
gpu-cluster
```

### Step 4 - Review the AI Inference App

The app source code lives in `07.AI-Operations/exercise-placement/app/`:

| File | Purpose |
|------|---------|
| `app.py` | Flask app with `/health`, `/gpu` (runs nvidia-smi), `/predict` (matrix multiply), `/info` |
| `requirements.txt` | flask, numpy, gunicorn |
| `Dockerfile` | Based on UBI9 Python 3.11 |

The Kubernetes manifests in `07.AI-Operations/exercise-placement/manifests/` include:
- **BuildConfig**: Builds the image from the git repo directly on the target cluster
- **ImageStream**: Stores the built image
- **Deployment**: Runs the app requesting `nvidia.com/gpu: "1"`
- **Service** and **Route**: Expose the app externally

### Step 5 - Deploy via ApplicationSet

Apply the ApplicationSet that uses the `clusterDecisionResource` generator to read from the gpu-clusters PlacementDecision:

```
<hub> $ oc apply -f 07.AI-Operations/exercise-placement/hub/applicationset.yaml
```

Verify the Application was created and is syncing:

```
<hub> $ oc get application.argoproj.io -n openshift-gitops
NAME                       SYNC STATUS   HEALTH STATUS
ai-gpu-flask-gpu-cluster   Synced        Healthy
```

The ApplicationSet automatically:
1. Reads the PlacementDecision to find gpu-cluster
2. Creates an ArgoCD Application targeting gpu-cluster
3. Deploys all manifests (namespace, buildconfig, deployment, service, route)
4. The BuildConfig triggers a build on gpu-cluster from the git source

### Step 6 - Test Placement Behavior

Patch the Placement to require `gpu-count >= 2`:

```
<hub> $ oc patch placement gpu-clusters -n openshift-gitops --type=merge -p '
spec:
  predicates:
    - requiredClusterSelector:
        labelSelector:
          matchLabels:
            gpu: "true"
        claimSelector:
          matchExpressions:
            - key: gpu-count
              operator: Gt
              values:
                - "1"
'
```

Check the PlacementDecision:

```
<hub> $ oc get placementdecision -n openshift-gitops -l cluster.open-cluster-management.io/placement=gpu-clusters \
    -o jsonpath='{.items[0].status.decisions}'
[]
```

No cluster matches because no cluster has `gpu-count >= 2`. The ApplicationSet controller will remove the Application on its next reconcile cycle. This demonstrates how ACM prevents workload misplacement.

Revert to the original Placement:

```
<hub> $ oc apply -f 07.AI-Operations/exercise-placement/hub/placement.yaml
```

### Step 7 - Cleanup

```
<hub> $ oc delete -f 07.AI-Operations/exercise-placement/hub/applicationset.yaml
<hub> $ oc delete -f 07.AI-Operations/exercise-placement/hub/gitopscluster.yaml
<hub> $ oc delete -f 07.AI-Operations/exercise-placement/hub/placement.yaml
<hub> $ oc delete -f 07.AI-Operations/exercise-placement/hub/managedclustersetbinding.yaml
```

---

## 7B - OpenShift Lightspeed MCP Server

OpenShift Lightspeed includes a built-in **Kubernetes MCP Server** (`openshift-mcp-server`) that runs as a sidecar container in the `lightspeed-app-server` pod. This server implements the [Model Context Protocol](https://modelcontextprotocol.io/) and provides 14 read-only tools for querying cluster resources via any MCP-compatible AI client.

### How It Works

```
┌─────────────────────────────────────────────────────┐
│  lightspeed-app-server Pod                          │
│                                                     │
│  ┌─────────────────────┐  ┌──────────────────────┐  │
│  │ lightspeed-service-  │  │ openshift-mcp-server │  │
│  │ api         :8443    │  │              :8080    │  │
│  └─────────────────────┘  └──────────┬───────────┘  │
│                                      │              │
└──────────────────────────────────────┼──────────────┘
                                       │ uses SA token
                                       ▼
                               Kubernetes API
                                       │
                          ┌────────────┼────────────┐
                          ▼            ▼            ▼
                   ManagedClusters  Policies  PlacementDecisions
```

The MCP server:
- Runs as `/openshift-mcp-server --read-only --port 8080`
- Exposes endpoints: `/mcp` (streamable HTTP), `/sse`, `/healthz`, `/stats`, `/metrics`
- Uses the `lightspeed-app-server` ServiceAccount to authenticate to the Kubernetes API
- Supports MCP protocol version `2024-11-05` with JSON-RPC 2.0

Available tools: `resources_list`, `resources_get`, `pods_list`, `pods_get`, `pods_log`, `pods_list_in_namespace`, `pods_top`, `nodes_top`, `nodes_log`, `nodes_stats_summary`, `events_list`, `namespaces_list`, `projects_list`, `configuration_view`

### Step 1 - Grant RBAC for RHACM Resource Access

By default, the `lightspeed-app-server` ServiceAccount only has permissions for token reviews and subject access reviews. The MCP server needs `cluster-reader` access to query RHACM resources (ManagedClusters, Policies, PlacementDecisions, etc.):

```
<hub> $ oc apply -f 07.AI-Operations/exercise-lightspeed/lightspeed-mcp-rbac.yaml
```

This creates a ClusterRoleBinding granting `cluster-reader` to the `lightspeed-app-server` SA.

### Step 2 - Expose the MCP Server

The OLS API runs on port 8443, but the MCP server runs on port 8080. Create a dedicated Service and Route for the MCP endpoint:

```
<hub> $ oc apply -f 07.AI-Operations/exercise-lightspeed/lightspeed-mcp-service.yaml
<hub> $ oc apply -f 07.AI-Operations/exercise-lightspeed/lightspeed-route.yaml
```

Get the MCP endpoint:

```
<hub> $ export MCP_URL=$(oc get route lightspeed-mcp -n openshift-lightspeed -o jsonpath='{.spec.host}')
<hub> $ echo "MCP endpoint: https://${MCP_URL}"
```

### Step 3 - Verify the MCP Server

Test the health endpoint:

```
<hub> $ curl -sk https://${MCP_URL}/healthz
<hub> $ curl -sk https://${MCP_URL}/stats
```

Test a full MCP session querying managed clusters:

```
<hub> $ SESSION_ID=$(curl -sk -D - -X POST https://${MCP_URL}/mcp \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}' \
    | grep -i "mcp-session-id" | tr -d "\r" | awk '{print $2}')

<hub> $ curl -sk -X POST https://${MCP_URL}/mcp \
    -H "Content-Type: application/json" \
    -H "Mcp-Session-Id: $SESSION_ID" \
    -d '{"jsonrpc":"2.0","method":"notifications/initialized"}'

<hub> $ curl -sk -X POST https://${MCP_URL}/mcp \
    -H "Content-Type: application/json" \
    -H "Mcp-Session-Id: $SESSION_ID" \
    -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"resources_list","arguments":{"apiVersion":"cluster.open-cluster-management.io/v1","kind":"ManagedCluster"}}}'
```

You should see all three managed clusters (gpu-cluster, local-cluster, standard-cluster) returned with their labels and status.

### Step 4 - Connect Your IDE

For **Cursor**, add to `.cursor/mcp.json`:

```json
{
  "mcpServers": {
    "openshift-mcp": {
      "url": "https://<your-lightspeed-mcp-route>/sse"
    }
  }
}
```

For a **local Kubernetes MCP server** (alternative approach using npx), first create a service account and kubeconfig:

```
<hub> $ oc apply -f 07.AI-Operations/exercise-mcp/mcp-serviceaccount.yaml
<hub> $ export MCP_TOKEN=$(oc create token mcp-viewer -n mcp --duration=2h)
<hub> $ export API_SERVER=$(oc whoami --show-server)
<hub> $ export CA_DATA=$(oc get configmap kube-root-ca.crt -n mcp -o jsonpath='{.data.ca\.crt}' | base64 -w0)
<hub> $ cat > /tmp/mcp-kubeconfig.yaml << EOF
apiVersion: v1
kind: Config
clusters:
  - cluster:
      server: ${API_SERVER}
      certificate-authority-data: ${CA_DATA}
    name: hub-cluster
contexts:
  - context:
      cluster: hub-cluster
      user: mcp-viewer
    name: mcp-context
current-context: mcp-context
users:
  - name: mcp-viewer
    user:
      token: ${MCP_TOKEN}
EOF
```

Then add to `.cursor/mcp.json`:

```json
{
  "mcpServers": {
    "kubernetes": {
      "command": "npx",
      "args": ["-y", "kubernetes-mcp-server@latest", "--kubeconfig", "/tmp/mcp-kubeconfig.yaml", "--read-only"]
    }
  }
}
```

### Step 5 - Query Your Fleet

Once connected, you can ask your AI assistant questions about the RHACM fleet:

- "Show me all managed clusters and their status"
- "List all pods in the open-cluster-management namespace"
- "What policies are non-compliant across my fleet?"
- "Show me the GPU node capacity on gpu-cluster"
- "What PlacementDecisions exist and which clusters are they targeting?"

### Cleanup

```
<hub> $ oc delete -f 07.AI-Operations/exercise-lightspeed/lightspeed-route.yaml
<hub> $ oc delete -f 07.AI-Operations/exercise-lightspeed/lightspeed-mcp-service.yaml
<hub> $ oc delete -f 07.AI-Operations/exercise-lightspeed/lightspeed-mcp-rbac.yaml
```

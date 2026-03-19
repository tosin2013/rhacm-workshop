#!/bin/bash
set -euo pipefail

NS="open-cluster-management-observability"
OBC_NAME="observability-bucket"
OBC_SC="openshift-storage.noobaa.io"

echo "=== ACM Observability Setup (using ODF NooBaa) ==="

# ── 1. Create namespace ─────────────────────────────────────────────
echo "[1/6] Creating namespace ${NS}..."
oc create namespace "${NS}" --dry-run=client -o yaml | oc apply -f -

# ── 2. Copy pull secret ─────────────────────────────────────────────
echo "[2/6] Copying pull secret..."
DOCKER_CONFIG_JSON=$(oc extract secret/pull-secret -n openshift-config --to=- 2>/dev/null)
oc create secret generic multiclusterhub-operator-pull-secret \
  -n "${NS}" \
  --from-literal=.dockerconfigjson="${DOCKER_CONFIG_JSON}" \
  --type=kubernetes.io/dockerconfigjson \
  --dry-run=client -o yaml | oc apply -f -

# ── 3. Create ObjectBucketClaim ──────────────────────────────────────
echo "[3/6] Creating ObjectBucketClaim via NooBaa..."
cat <<EOF | oc apply -f -
apiVersion: objectbucket.io/v1alpha1
kind: ObjectBucketClaim
metadata:
  name: ${OBC_NAME}
  namespace: ${NS}
spec:
  generateBucketName: observability
  storageClassName: ${OBC_SC}
EOF

echo "       Waiting for OBC to bind..."
oc wait --for=jsonpath='{.status.phase}'=Bound \
  objectbucketclaim/${OBC_NAME} -n "${NS}" --timeout=120s

# ── 4. Extract OBC credentials and create thanos secret ──────────────
echo "[4/6] Extracting OBC credentials and creating thanos-object-storage secret..."
BUCKET_NAME=$(oc get configmap "${OBC_NAME}" -n "${NS}" -o jsonpath='{.data.BUCKET_NAME}')
BUCKET_HOST=$(oc get configmap "${OBC_NAME}" -n "${NS}" -o jsonpath='{.data.BUCKET_HOST}')
ACCESS_KEY=$(oc get secret "${OBC_NAME}" -n "${NS}" -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' | base64 -d)
SECRET_KEY=$(oc get secret "${OBC_NAME}" -n "${NS}" -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' | base64 -d)

# NooBaa S3 service exposes HTTP on port 80 and HTTPS on port 443.
# Use HTTP to avoid TLS certificate trust issues with Thanos components.
S3_ENDPOINT="${BUCKET_HOST}:80"

echo "       Bucket  : ${BUCKET_NAME}"
echo "       Endpoint: ${S3_ENDPOINT} (HTTP)"

oc create secret generic thanos-object-storage -n "${NS}" \
  --from-literal=thanos.yaml="$(cat <<THANOS
type: s3
config:
  bucket: ${BUCKET_NAME}
  endpoint: ${S3_ENDPOINT}
  insecure: true
  access_key: ${ACCESS_KEY}
  secret_key: ${SECRET_KEY}
THANOS
)" --dry-run=client -o yaml | oc apply -f -

# ── 5. Detect storage class ──────────────────────────────────────────
echo "[5/6] Detecting statefulset storage class..."
STATEFUL_SC=$(oc get sc -o name | grep -v 'noobaa\|cephfs\|immediate' | head -1 | sed 's|storageclass.storage.k8s.io/||')
if [[ -z "${STATEFUL_SC}" ]]; then
  STATEFUL_SC="gp3-csi"
fi
echo "       Using storage class: ${STATEFUL_SC}"

# ── 6. Apply MultiClusterObservability CR ─────────────────────────────
echo "[6/6] Applying MultiClusterObservability CR..."
cat <<EOF | oc apply -f -
apiVersion: observability.open-cluster-management.io/v1beta2
kind: MultiClusterObservability
metadata:
  name: observability
spec:
  availabilityConfig: High
  enableDownSampling: false
  imagePullPolicy: Always
  observabilityAddonSpec:
    enableMetrics: true
    interval: 30
  retentionResolution1h: 30d
  retentionResolution5m: 14d
  retentionResolutionRaw: 5d
  storageConfig:
    metricObjectStorage:
      name: thanos-object-storage
      key: thanos.yaml
    statefulSetSize: 10Gi
    statefulSetStorageClass: ${STATEFUL_SC}
EOF

echo ""
echo "=== Observability deployment initiated ==="
echo "Run the following to monitor pod status:"
echo "  oc get pods -n ${NS} -w"
echo ""
echo "It typically takes 3-5 minutes for all pods to reach Running state."

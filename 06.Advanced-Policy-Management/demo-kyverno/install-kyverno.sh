#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANAGED_KUBECONFIG="${MANAGED_KUBECONFIG:?MANAGED_KUBECONFIG must be set to the managed cluster kubeconfig path}"
HELM="${HELM:-helm}"
KYVERNO_NAMESPACE="kyverno"
POLICY_NAMESPACE="rhacm-policies"
TEST_NAMESPACE="kyverno-test"
PASS=0
FAIL=0

info()  { echo -e "\n\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[PASS]\033[0m  $*"; PASS=$((PASS+1)); }
fail()  { echo -e "\033[1;31m[FAIL]\033[0m  $*"; FAIL=$((FAIL+1)); }
hub()   { oc "$@"; }
mc()    { oc --kubeconfig="$MANAGED_KUBECONFIG" "$@"; }

# ── Pre-flight ───────────────────────────────────────────────────────────────
info "Pre-flight checks"
command -v oc >/dev/null   || { echo "oc not found"; exit 1; }
command -v "$HELM" >/dev/null || { echo "helm not found (set HELM= to override path)"; exit 1; }
hub cluster-info --request-timeout=5s >/dev/null 2>&1  || { echo "Cannot reach hub cluster"; exit 1; }
mc  cluster-info --request-timeout=5s >/dev/null 2>&1  || { echo "Cannot reach managed cluster"; exit 1; }
echo "  Hub:     $(hub whoami --show-server)"
echo "  Managed: $(mc whoami --show-server)"

# ── Install Kyverno via Helm ─────────────────────────────────────────────────
info "Installing Kyverno via Helm on managed cluster"
KUBECONFIG="$MANAGED_KUBECONFIG" "$HELM" repo add kyverno https://kyverno.github.io/kyverno/ 2>/dev/null || true
KUBECONFIG="$MANAGED_KUBECONFIG" "$HELM" repo update

if KUBECONFIG="$MANAGED_KUBECONFIG" "$HELM" status kyverno -n "$KYVERNO_NAMESPACE" >/dev/null 2>&1; then
  echo "  Kyverno Helm release already exists — upgrading"
  KUBECONFIG="$MANAGED_KUBECONFIG" "$HELM" upgrade kyverno kyverno/kyverno \
    -n "$KYVERNO_NAMESPACE" --no-hooks --wait --timeout=5m
else
  KUBECONFIG="$MANAGED_KUBECONFIG" "$HELM" install kyverno kyverno/kyverno \
    -n "$KYVERNO_NAMESPACE" --create-namespace --no-hooks --wait --timeout=5m
fi

info "Waiting for Kyverno pods to be ready"
mc wait --for=condition=Ready pods --all -n "$KYVERNO_NAMESPACE" --timeout=300s
mc get pods -n "$KYVERNO_NAMESPACE"

# ── Ensure rhacm-policies namespace on hub ───────────────────────────────────
info "Ensuring ${POLICY_NAMESPACE} namespace exists on hub"
hub create namespace "$POLICY_NAMESPACE" 2>/dev/null || true

# ── Apply Kyverno install policy on hub ──────────────────────────────────────
info "Applying Kyverno install policy on hub"
hub apply -f "${SCRIPT_DIR}/policy-kyverno-install.yaml"

# ── Clean up broken OLM resources ────────────────────────────────────────────
info "Cleaning up stale OLM resources in ${KYVERNO_NAMESPACE} namespace"
mc delete subscription.operators.coreos.com kyverno-operator -n "$KYVERNO_NAMESPACE" --ignore-not-found 2>&1 || true
mc delete operatorgroup kyverno -n "$KYVERNO_NAMESPACE" --ignore-not-found 2>&1 || true
mc delete csv -n "$KYVERNO_NAMESPACE" --all --ignore-not-found 2>&1 || true

# ── Apply Placement (shared by both policies) ───────────────────────────────
info "Applying Kyverno Placement on hub"
hub apply -f - <<'PLACEMENT_EOF'
apiVersion: cluster.open-cluster-management.io/v1beta1
kind: Placement
metadata:
  name: placement-policy-kyverno
  namespace: rhacm-policies
spec:
  predicates:
    - requiredClusterSelector:
        labelSelector:
          matchExpressions:
            - key: environment
              operator: In
              values:
                - production
PLACEMENT_EOF

# ── Apply ACM Kyverno policies ───────────────────────────────────────────────
info "Applying Kyverno require-labels policy"
hub apply -f "${SCRIPT_DIR}/policy-kyverno-require-labels.yaml"

info "Applying Kyverno disallow-privileged policy"
hub apply -f "${SCRIPT_DIR}/policy-kyverno-disallow-privileged.yaml"

info "Waiting for policies to become Compliant (up to 3 min)"
for policy in policy-kyverno-install policy-kyverno-require-labels policy-kyverno-disallow-privileged; do
  for i in $(seq 1 18); do
    state=$(hub get policy "$policy" -n "$POLICY_NAMESPACE" -o jsonpath='{.status.compliant}' 2>/dev/null || echo "")
    if [ "$state" = "Compliant" ]; then
      echo "  $policy: Compliant"
      break
    fi
    if [ "$i" -eq 18 ]; then
      echo "  WARNING: $policy did not reach Compliant within timeout (current: $state)"
    fi
    sleep 10
  done
done

# ── Tests ────────────────────────────────────────────────────────────────────
info "Running Kyverno policy tests on managed cluster"

# Ensure test namespace is clean and active
mc delete namespace "$TEST_NAMESPACE" --ignore-not-found 2>/dev/null || true
for i in $(seq 1 30); do
  if ! mc get namespace "$TEST_NAMESPACE" >/dev/null 2>&1; then break; fi
  sleep 2
done
mc create namespace "$TEST_NAMESPACE"

info "Test 1: Pod without required label (expect DENIED)"
TEST1_OUT=$(mc run nginx --image=registry.access.redhat.com/ubi9/nginx-124:latest -n "$TEST_NAMESPACE" 2>&1) || true
if echo "$TEST1_OUT" | grep -qi "denied\|forbidden\|violated\|blocked"; then
  ok "Pod without label was correctly denied"
else
  fail "Pod without label was NOT denied (expected denial). Output: $TEST1_OUT"
  mc delete pod nginx -n "$TEST_NAMESPACE" --ignore-not-found 2>/dev/null || true
fi

info "Test 2: Pod with required label (expect SUCCESS)"
TEST2_OUT=$(mc run nginx --image=registry.access.redhat.com/ubi9/nginx-124:latest -n "$TEST_NAMESPACE" \
    --labels="app.kubernetes.io/name=nginx" 2>&1) || true
if echo "$TEST2_OUT" | grep -qi "created"; then
  ok "Pod with label was correctly allowed"
else
  fail "Pod with label was NOT allowed (expected success). Output: $TEST2_OUT"
fi
mc delete pod nginx -n "$TEST_NAMESPACE" --ignore-not-found 2>/dev/null || true

info "Test 3: Privileged pod (expect DENIED)"
PRIV_RESULT=$(cat <<'POD_EOF' | mc apply -n "$TEST_NAMESPACE" -f - 2>&1 || true
apiVersion: v1
kind: Pod
metadata:
  name: privileged-pod
  labels:
    app.kubernetes.io/name: test
spec:
  containers:
  - name: nginx
    image: registry.access.redhat.com/ubi9/nginx-124:latest
    securityContext:
      privileged: true
POD_EOF
)
if echo "$PRIV_RESULT" | grep -qi "denied\|forbidden\|violated\|blocked"; then
  ok "Privileged pod was correctly denied"
else
  fail "Privileged pod was NOT denied (expected denial). Output: $PRIV_RESULT"
  mc delete pod privileged-pod -n "$TEST_NAMESPACE" --ignore-not-found 2>/dev/null || true
fi

info "Test 4: Safe pod (expect SUCCESS)"
SAFE_RESULT=$(cat <<'POD_EOF' | mc apply -n "$TEST_NAMESPACE" -f - 2>&1 || true
apiVersion: v1
kind: Pod
metadata:
  name: safe-pod
  labels:
    app.kubernetes.io/name: test
spec:
  containers:
  - name: nginx
    image: registry.access.redhat.com/ubi9/nginx-124:latest
POD_EOF
)
if echo "$SAFE_RESULT" | grep -qi "created\|configured\|unchanged"; then
  ok "Safe pod was correctly allowed"
else
  fail "Safe pod was NOT allowed (expected success). Output: $SAFE_RESULT"
fi
mc delete pod safe-pod -n "$TEST_NAMESPACE" --ignore-not-found 2>/dev/null || true

# ── Cleanup ──────────────────────────────────────────────────────────────────
info "Cleaning up test namespace"
mc delete namespace "$TEST_NAMESPACE" --ignore-not-found

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "=========================================="
echo "  Kyverno Module 06 Results"
echo "=========================================="
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
echo "=========================================="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi

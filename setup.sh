#!/usr/bin/env bash
set -euo pipefail

# RHACM Workshop Setup Script
# Validates the cluster environment and installs prerequisites for the workshop.
# Usage: ./setup.sh [--skip-aws] [--help]

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

SKIP_AWS=false
ERRORS=0

usage() {
  echo "Usage: $0 [--skip-aws] [--help]"
  echo "  --skip-aws   Skip AWS credential validation (no Hive cluster provisioning)"
  echo "  --help       Show this help message"
  exit 0
}

for arg in "$@"; do
  case $arg in
    --skip-aws) SKIP_AWS=true ;;
    --help) usage ;;
  esac
done

pass() { echo -e "  ${GREEN}✓${NC} $1"; }
fail() { echo -e "  ${RED}✗${NC} $1"; ERRORS=$((ERRORS + 1)); }
warn() { echo -e "  ${YELLOW}!${NC} $1"; }
header() { echo -e "\n${YELLOW}=== $1 ===${NC}"; }

header "Cluster Connectivity"

if ! oc whoami &>/dev/null; then
  fail "Not logged into an OpenShift cluster. Run 'oc login' first."
  echo -e "\n${RED}Cannot continue without cluster access.${NC}"
  exit 1
fi
CLUSTER_USER=$(oc whoami)
pass "Logged in as: $CLUSTER_USER"

API_URL=$(oc whoami --show-server)
pass "API server: $API_URL"

header "OpenShift Version"

OCP_VERSION=$(oc get clusterversion version -o jsonpath='{.status.desired.version}')
pass "OCP version: $OCP_VERSION"

OCP_MAJOR_MINOR=$(echo "$OCP_VERSION" | cut -d. -f1,2)
if [[ "$OCP_MAJOR_MINOR" == "4.20" ]]; then
  pass "OCP 4.20 confirmed (workshop target)"
else
  warn "OCP version is $OCP_MAJOR_MINOR — workshop targets 4.20. Some exercises may need adjustment."
fi

header "Node Resources"

NODE_COUNT=$(oc get nodes --no-headers 2>/dev/null | wc -l)
pass "Node count: $NODE_COUNT"
if [[ "$NODE_COUNT" -eq 1 ]]; then
  warn "Single-node cluster detected (SNO). Cluster upgrade exercise (Module 02 section 2.3) should be skipped."
fi

NODE_CPU=$(oc get nodes -o jsonpath='{.items[0].status.allocatable.cpu}')
NODE_MEM=$(oc get nodes -o jsonpath='{.items[0].status.allocatable.memory}')
pass "Allocatable CPU: $NODE_CPU"
pass "Allocatable Memory: $NODE_MEM"

header "Advanced Cluster Management"

if oc get multiclusterhub -A &>/dev/null; then
  MCH_NS=$(oc get multiclusterhub -A -o jsonpath='{.items[0].metadata.namespace}')
  MCH_STATUS=$(oc get multiclusterhub -n "$MCH_NS" -o jsonpath='{.items[0].status.phase}')
  MCH_VERSION=$(oc get multiclusterhub -n "$MCH_NS" -o jsonpath='{.items[0].status.currentVersion}')
  if [[ "$MCH_STATUS" == "Running" ]]; then
    pass "ACM $MCH_VERSION is installed and running in namespace $MCH_NS"
  else
    fail "ACM is installed but status is: $MCH_STATUS"
  fi
else
  fail "MultiClusterHub not found. ACM is not installed."
fi

ACM_CHANNEL=$(oc get sub advanced-cluster-management -n open-cluster-management -o jsonpath='{.spec.channel}' 2>/dev/null || echo "unknown")
pass "ACM subscription channel: $ACM_CHANNEL"

header "Managed Clusters"

MC_COUNT=$(oc get managedclusters --no-headers 2>/dev/null | wc -l)
pass "Managed cluster count: $MC_COUNT"
oc get managedclusters --no-headers 2>/dev/null | while read -r line; do
  MC_NAME=$(echo "$line" | awk '{print $1}')
  MC_AVAIL=$(echo "$line" | awk '{print $5}')
  if [[ "$MC_AVAIL" == "True" ]]; then
    pass "  $MC_NAME: Available"
  else
    warn "  $MC_NAME: Not available ($MC_AVAIL)"
  fi
done

header "Storage Classes"

SC_DEFAULT=$(oc get sc -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}' 2>/dev/null)
if [[ -n "$SC_DEFAULT" ]]; then
  pass "Default storage class: $SC_DEFAULT"
else
  warn "No default storage class found"
fi

if oc get sc ocs-external-storagecluster-ceph-rbd &>/dev/null; then
  pass "ODF Ceph RBD storage class available"
elif oc get sc gp2 &>/dev/null; then
  pass "AWS gp2 storage class available"
elif oc get sc gp3-csi &>/dev/null; then
  pass "AWS gp3-csi storage class available"
else
  warn "No recognized storage class found (gp2, gp3-csi, ocs-external-storagecluster-ceph-rbd)"
fi

header "Required APIs"

REQUIRED_APIS=(
  "placements.cluster.open-cluster-management.io"
  "placementbindings.policy.open-cluster-management.io"
  "multiclusterobservabilities.observability.open-cluster-management.io"
  "managedclusters.cluster.open-cluster-management.io"
)
for api in "${REQUIRED_APIS[@]}"; do
  if oc api-resources --api-group="$(echo "$api" | cut -d. -f2-)" 2>/dev/null | grep -q "$(echo "$api" | cut -d. -f1)"; then
    pass "$api"
  else
    fail "Missing API: $api"
  fi
done

header "Operator Marketplace"

REQUIRED_PACKAGES=(
  "openshift-gitops-operator"
  "compliance-operator"
  "gatekeeper-operator-product"
)
for pkg in "${REQUIRED_PACKAGES[@]}"; do
  if oc get packagemanifest "$pkg" -n openshift-marketplace &>/dev/null; then
    pass "Available: $pkg"
  else
    fail "Not available in marketplace: $pkg"
  fi
done

header "Installed Operators"

for ns_op in "open-cluster-management:advanced-cluster-management" "multicluster-engine:multicluster-engine"; do
  ns=$(echo "$ns_op" | cut -d: -f1)
  op=$(echo "$ns_op" | cut -d: -f2)
  CSV=$(oc get csv -n "$ns" -l "operators.coreos.com/${op}.${ns}=" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  if [[ -n "$CSV" ]]; then
    VERSION=$(oc get csv "$CSV" -n "$ns" -o jsonpath='{.spec.version}' 2>/dev/null || echo "unknown")
    pass "$op v$VERSION"
  else
    warn "$op not found in $ns"
  fi
done

if ! "$SKIP_AWS"; then
  header "AWS Credentials (for Hive Cluster Provisioning)"

  if [[ -n "${AWS_ACCESS_KEY_ID:-}" && -n "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
    pass "AWS_ACCESS_KEY_ID is set"
    pass "AWS_SECRET_ACCESS_KEY is set"
    AWS_REGION="${AWS_DEFAULT_REGION:-us-east-2}"
    pass "AWS region: $AWS_REGION"
  else
    warn "AWS credentials not set in environment."
    echo "    To provision managed clusters, export the following before running setup:"
    echo "      export AWS_ACCESS_KEY_ID=<your-key>"
    echo "      export AWS_SECRET_ACCESS_KEY=<your-secret>"
    echo "      export AWS_DEFAULT_REGION=us-east-2  # optional, defaults to us-east-2"
  fi
fi

header "OpenShift Lightspeed"

if oc get csv -n openshift-lightspeed -l "operators.coreos.com/lightspeed-operator.openshift-lightspeed=" -o name &>/dev/null 2>&1; then
  LS_VERSION=$(oc get csv -n openshift-lightspeed -o jsonpath='{.items[0].spec.version}' 2>/dev/null || echo "unknown")
  pass "OpenShift Lightspeed v$LS_VERSION installed (Module 07B)"
else
  warn "OpenShift Lightspeed not installed. Module 07B (Lightspeed MCP) will require installation."
fi

header "Setup Actions"

echo "Setting labels on local-cluster..."
oc label managedcluster local-cluster environment=hub --overwrite 2>/dev/null && pass "Label environment=hub set on local-cluster" || warn "Could not label local-cluster"

if ! oc get project rhacm-policies &>/dev/null 2>&1; then
  oc new-project rhacm-policies &>/dev/null && pass "Created namespace: rhacm-policies" || warn "Could not create rhacm-policies namespace"
else
  pass "Namespace rhacm-policies already exists"
fi

header "Summary"

if [[ $ERRORS -eq 0 ]]; then
  echo -e "\n${GREEN}All checks passed. The cluster is ready for the RHACM workshop.${NC}"
else
  echo -e "\n${RED}$ERRORS check(s) failed. Review the issues above before starting the workshop.${NC}"
fi

echo ""
echo "Next steps:"
echo "  1. Review Module 01 (RHACM-Installation/README.md) to verify ACM and provision clusters"
echo "  2. If provisioning AWS clusters, ensure AWS credentials are set and run:"
echo "     oc apply -f 01.RHACM-Installation/cluster-provisioning/"
echo "  3. While clusters provision (~30-45 min), proceed with Module 02 on local-cluster"
echo ""

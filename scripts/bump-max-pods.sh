#!/bin/bash
set -euo pipefail

MAX_PODS="${1:-350}"
MCP="master"

echo "==> Bumping maxPods to ${MAX_PODS} on MachineConfigPool '${MCP}'"
echo "    WARNING: This will trigger a node reboot (~10-15 minutes)"
echo ""

cat <<EOF | oc apply -f -
apiVersion: machineconfiguration.openshift.io/v1
kind: KubeletConfig
metadata:
  name: set-max-pods
spec:
  machineConfigPoolSelector:
    matchLabels:
      pools.operator.machineconfiguration.openshift.io/${MCP}: ""
  kubeletConfig:
    maxPods: ${MAX_PODS}
EOF

echo ""
echo "==> KubeletConfig applied. Waiting for MachineConfigPool '${MCP}' to begin updating..."

for i in $(seq 1 30); do
  UPDATING=$(oc get mcp "${MCP}" -o jsonpath='{.status.conditions[?(@.type=="Updating")].status}' 2>/dev/null || echo "Unknown")
  if [ "${UPDATING}" = "True" ]; then
    echo "    MCP is updating (attempt ${i}/30)"
    break
  fi
  echo "    Waiting for MCP update to start... (${i}/30)"
  sleep 10
done

echo ""
echo "==> Waiting for MachineConfigPool '${MCP}' to finish rollout..."
oc wait mcp "${MCP}" --for=condition=Updated=True --timeout=20m 2>/dev/null || {
  echo "    Timeout waiting for MCP. Checking status..."
  oc get mcp "${MCP}"
  echo ""
  echo "    Node may still be rebooting. Monitor with:"
  echo "      oc get mcp ${MCP} -w"
  echo "      oc get nodes"
  exit 1
}

echo ""
echo "==> MCP rollout complete. Verifying maxPods..."
NODE=$(oc get nodes -o jsonpath='{.items[0].metadata.name}')
CURRENT_MAX=$(oc get node "${NODE}" -o jsonpath='{.status.allocatable.pods}')
echo "    Node: ${NODE}"
echo "    Allocatable pods: ${CURRENT_MAX}"

if [ "${CURRENT_MAX}" -ge "${MAX_PODS}" ]; then
  echo "==> Success! maxPods is now ${CURRENT_MAX}"
else
  echo "==> WARNING: maxPods (${CURRENT_MAX}) is less than expected (${MAX_PODS})"
fi

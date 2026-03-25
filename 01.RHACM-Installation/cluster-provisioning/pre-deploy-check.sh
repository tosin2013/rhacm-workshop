#!/usr/bin/env bash
set -euo pipefail

# Pre-deployment prerequisites check for ACM cluster provisioning on AWS.
# Installs AWS CLI, configures credentials from the ACM credential secret,
# checks Elastic IP quota, cleans up orphaned resources, and optionally
# requests a quota increase.
#
# Tested on: RHEL 9 (bash 5.x). macOS support included but not fully tested.

REGION="${AWS_DEFAULT_REGION:-us-east-2}"
CREDENTIAL_NS="${CREDENTIAL_NS:-aws-credentials}"
CREDENTIAL_NAME="${CREDENTIAL_NAME:-aws-credentials}"
REQUIRED_EIPS=6  # 3 per SNO cluster (one EIP per AZ for NAT gateways)

OS="$(uname -s)"

b64decode() {
  case "$OS" in
    Darwin) base64 -D ;;
    *)      base64 -d ;;
  esac
}

# --- Pre-flight checks ---
echo "=== Pre-flight checks ==="

MISSING=()
for cmd in oc curl bc; do
  if ! command -v "$cmd" &>/dev/null; then
    MISSING+=("$cmd")
  fi
done
if [[ "$OS" == "Linux" ]]; then
  command -v unzip &>/dev/null || MISSING+=("unzip")
fi

if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo "ERROR: Missing required tools: ${MISSING[*]}"
  echo ""
  echo "Install them and re-run. Example:"
  case "$OS" in
    Darwin) echo "  brew install ${MISSING[*]}" ;;
    *)      echo "  sudo dnf install -y ${MISSING[*]}" ;;
  esac
  exit 1
fi

if ! oc whoami &>/dev/null; then
  echo "ERROR: Not logged into an OpenShift cluster."
  echo "  Run 'oc login <API_URL>' first, then re-run this script."
  exit 1
fi

echo "  Tools OK: oc, curl, bc$([ "$OS" == "Linux" ] && echo ", unzip")"
echo "  Logged into: $(oc whoami --show-server)"
echo ""

echo "=== ACM Cluster Provisioning Pre-Deployment Check ==="
echo "Region: $REGION"
echo ""

# --- 1. AWS CLI ---
if ! command -v aws &>/dev/null && ! [ -x /usr/local/bin/aws ]; then
  echo "[1/5] AWS CLI not found. Installing..."
  case "$OS" in
    Linux)
      curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
      cd /tmp && unzip -qo awscliv2.zip && sudo ./aws/install && cd -
      sudo chmod -R o+rx /usr/local/aws-cli/ 2>/dev/null || true
      ;;
    Darwin)
      curl -s "https://awscli.amazonaws.com/AWSCLIV2.pkg" -o /tmp/AWSCLIV2.pkg
      sudo installer -pkg /tmp/AWSCLIV2.pkg -target /
      ;;
    *)
      echo "  ERROR: Unsupported OS ($OS). Install the AWS CLI manually:"
      echo "    https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
      exit 1
      ;;
  esac
  echo "  AWS CLI installed."
else
  echo "[1/5] AWS CLI found."
fi

AWS=$( command -v aws || echo /usr/local/bin/aws )

# --- 2. Configure AWS credentials from ACM secret ---
echo "[2/5] Loading AWS credentials from ACM credential ($CREDENTIAL_NS/$CREDENTIAL_NAME)..."
export AWS_ACCESS_KEY_ID=$(oc get secret "$CREDENTIAL_NAME" -n "$CREDENTIAL_NS" -o jsonpath='{.data.aws_access_key_id}' | b64decode)
export AWS_SECRET_ACCESS_KEY=$(oc get secret "$CREDENTIAL_NAME" -n "$CREDENTIAL_NS" -o jsonpath='{.data.aws_secret_access_key}' | b64decode)
export AWS_DEFAULT_REGION="$REGION"
echo "  Loaded. Region: $AWS_DEFAULT_REGION"

# --- 3. Check Elastic IP quota ---
echo "[3/5] Checking Elastic IP quota..."
QUOTA=$($AWS service-quotas get-service-quota --service-code ec2 --quota-code L-0263D0A3 --query 'Quota.Value' --output text)
CURRENT=$($AWS ec2 describe-addresses --query 'length(Addresses)' --output text)
echo "  Elastic IPs: $CURRENT in use / $QUOTA quota (need $REQUIRED_EIPS for two SNO clusters)"

if (( $(echo "$QUOTA < $REQUIRED_EIPS" | bc -l) )); then
  echo "  WARNING: Quota ($QUOTA) is less than required ($REQUIRED_EIPS)."
  echo "  Checking for pending quota increase requests..."
  PENDING=$($AWS service-quotas list-requested-service-quota-changes-by-status \
    --status PENDING --query "RequestedQuotas[?QuotaCode=='L-0263D0A3'].DesiredValue | [0]" --output text 2>/dev/null || echo "None")
  if [ "$PENDING" != "None" ] && [ "$PENDING" != "null" ]; then
    echo "  Pending quota increase request found (desired: $PENDING). Waiting for approval."
  else
    read -rp "  Request quota increase to 10? [y/N] " answer
    if [[ "$answer" =~ ^[Yy]$ ]]; then
      $AWS service-quotas request-service-quota-increase \
        --service-code ec2 --quota-code L-0263D0A3 --desired-value 10
      echo "  Quota increase requested. This may take a few minutes for auto-approval."
    fi
  fi
else
  echo "  Quota OK."
fi

# --- 4. Release orphaned Elastic IPs ---
echo "[4/5] Checking for orphaned (unassociated) Elastic IPs..."
ORPHANED=$($AWS ec2 describe-addresses \
  --query 'Addresses[?AssociationId==null].[AllocationId,PublicIp,Tags[?Key==`Name`].Value|[0]]' \
  --output text)

if [ -z "$ORPHANED" ]; then
  echo "  No orphaned Elastic IPs found."
else
  echo "  Found orphaned Elastic IPs:"
  echo "$ORPHANED" | while read -r ALLOC_ID IP NAME; do
    echo "    $ALLOC_ID  $IP  ($NAME)"
  done
  read -rp "  Release orphaned EIPs? [y/N] " answer
  if [[ "$answer" =~ ^[Yy]$ ]]; then
    echo "$ORPHANED" | while read -r ALLOC_ID IP NAME; do
      $AWS ec2 release-address --allocation-id "$ALLOC_ID"
      echo "    Released $ALLOC_ID ($IP)"
    done
  fi
fi

# --- 5. Check other relevant quotas ---
echo "[5/5] Checking EC2 instance quotas..."
VCPU_QUOTA=$($AWS service-quotas get-service-quota --service-code ec2 --quota-code L-1216C47A \
  --query 'Quota.Value' --output text 2>/dev/null || echo "unknown")
echo "  Running On-Demand Standard vCPU quota: $VCPU_QUOTA"
echo "  standard-cluster (m6i.2xlarge) needs 8 vCPUs"
echo "  gpu-cluster (g6.4xlarge) needs 16 vCPUs"

# Check g-type accelerated instance quota
G_VCPU_QUOTA=$($AWS service-quotas get-service-quota --service-code ec2 --quota-code L-DB2BBE81 \
  --query 'Quota.Value' --output text 2>/dev/null || echo "unknown")
echo "  Running On-Demand G and VT vCPU quota: $G_VCPU_QUOTA"

RUNNING=$($AWS ec2 describe-instances --filters "Name=instance-state-name,Values=running" \
  --query 'length(Reservations[].Instances[])' --output text)
echo "  Currently running instances: $RUNNING"

echo ""
echo "=== Pre-deployment check complete ==="
CURRENT_EIPS=$($AWS ec2 describe-addresses --query 'length(Addresses)' --output text)
CURRENT_QUOTA=$($AWS service-quotas get-service-quota --service-code ec2 --quota-code L-0263D0A3 --query 'Quota.Value' --output text)
FREE_EIPS=$(echo "$CURRENT_QUOTA - $CURRENT_EIPS" | bc)
echo "Summary: $CURRENT_EIPS/$CURRENT_QUOTA EIPs in use ($FREE_EIPS available)"
if (( $(echo "$FREE_EIPS >= $REQUIRED_EIPS - $CURRENT_EIPS" | bc -l) )); then
  echo "Status: READY to deploy both clusters."
else
  echo "Status: NOT READY — need quota increase or cleanup before deploying both clusters."
  echo "  You can deploy standard-cluster first, then gpu-cluster after quota is increased."
fi

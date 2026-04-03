#!/bin/bash
# infrastructure/teardown.sh — Tear down all AWS resources for the challenge lab.
# Run from your local machine. Requires aws CLI configured with appropriate credentials.
#
# What this removes:
#   - 3 EC2 instances (control-plane, worker-01, worker-02)
#   - Elastic IP (released, not just disassociated)
#   - NLB, target groups, and listeners (if provisioned)
#   - Security group
#   - Key pair (AWS-side only — local .pem is not deleted)
#
# What this does NOT remove:
#   - Your local ~/.ssh/challenge-lab.pem
#   - Your local ~/.kube/config
#   - The key pair file on disk

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${SCRIPT_DIR}/../config.env"
# shellcheck source=../config.env.example
[[ -f "$CONFIG" ]] && source "$CONFIG" || source "${CONFIG}.example"

echo "==> Looking up challenge-lab resources..."

# Find instances by project tag
INSTANCE_IDS=$(aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=challenge-lab" \
            "Name=instance-state-name,Values=running,stopped,pending" \
  --query 'Reservations[*].Instances[*].InstanceId' \
  --output text)

if [[ -z "$INSTANCE_IDS" ]]; then
  echo "    No running instances found with Project=challenge-lab"
else
  echo "    Instances: $INSTANCE_IDS"
fi

# Find Elastic IPs associated with our specific instances
EIP_ALLOC_IDS=""
if [[ -n "$INSTANCE_IDS" ]]; then
  for IID in $INSTANCE_IDS; do
    ALLOC=$(aws ec2 describe-addresses \
      --filters "Name=instance-id,Values=${IID}" \
      --query 'Addresses[*].AllocationId' \
      --output text 2>/dev/null || true)
    [[ -n "$ALLOC" && "$ALLOC" != "None" ]] && EIP_ALLOC_IDS="$EIP_ALLOC_IDS $ALLOC"
  done
  EIP_ALLOC_IDS=$(echo $EIP_ALLOC_IDS | xargs)
fi

# Find NLB
NLB_ARN=$(aws elbv2 describe-load-balancers \
  --query 'LoadBalancers[?LoadBalancerName==`challenge-lab-nlb`].LoadBalancerArn' \
  --output text 2>/dev/null || true)
[[ "$NLB_ARN" == "None" ]] && NLB_ARN=""

# Find target groups
TG_ARNS=$(aws elbv2 describe-target-groups \
  --query 'TargetGroups[?starts_with(TargetGroupName, `challenge-lab-`)].TargetGroupArn' \
  --output text 2>/dev/null || true)

# Find security group
SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=k8s-challenge-lab" \
  --query 'SecurityGroups[0].GroupId' \
  --output text 2>/dev/null || true)
[[ "$SG_ID" == "None" ]] && SG_ID=""

echo ""
echo "Resources to be deleted:"
echo "  Instances:     ${INSTANCE_IDS:-none}"
echo "  Elastic IPs:   ${EIP_ALLOC_IDS:-none}"
echo "  NLB:           ${NLB_ARN:-none}"
echo "  Target Groups: ${TG_ARNS:-none}"
echo "  Security Group: ${SG_ID:-none}"
echo "  Key Pair:      challenge-lab"
echo ""
read -p "Proceed with teardown? [y/N] " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# Terminate instances
if [[ -n "$INSTANCE_IDS" ]]; then
  echo "==> Terminating instances: $INSTANCE_IDS"
  aws ec2 terminate-instances --instance-ids $INSTANCE_IDS --output table
  echo "==> Waiting for instances to terminate (this takes ~60s)..."
  aws ec2 wait instance-terminated --instance-ids $INSTANCE_IDS
  echo "    Instances terminated."
fi

# Release Elastic IPs
if [[ -n "$EIP_ALLOC_IDS" ]]; then
  for ALLOC_ID in $EIP_ALLOC_IDS; do
    echo "==> Releasing Elastic IP: $ALLOC_ID"
    aws ec2 release-address --allocation-id "$ALLOC_ID"
  done
fi

# Delete NLB (must be deleted before target groups)
if [[ -n "$NLB_ARN" ]]; then
  echo "==> Deleting NLB: $NLB_ARN"
  aws elbv2 delete-load-balancer --load-balancer-arn "$NLB_ARN"
  echo "    Waiting for NLB to be deleted..."
  aws elbv2 wait load-balancers-deleted --load-balancer-arns "$NLB_ARN"
  echo "    NLB deleted."
fi

# Delete target groups
if [[ -n "$TG_ARNS" ]]; then
  for TG_ARN in $TG_ARNS; do
    echo "==> Deleting target group: $TG_ARN"
    aws elbv2 delete-target-group --target-group-arn "$TG_ARN"
  done
fi

# Delete security group (must wait for instances to terminate first)
if [[ -n "$SG_ID" ]]; then
  echo "==> Deleting security group: $SG_ID"
  aws ec2 delete-security-group --group-id "$SG_ID"
  echo "    Security group deleted."
fi

# Delete key pair (AWS-side only)
echo "==> Deleting key pair: challenge-lab"
aws ec2 delete-key-pair --key-name challenge-lab 2>/dev/null && \
  echo "    Key pair deleted from AWS." || \
  echo "    Key pair not found in AWS (already deleted)."

echo ""
echo "==> Teardown complete."
echo ""
echo "To redeploy from scratch:"
echo "  1. Follow infrastructure/aws-setup.md"
echo "  2. SSH into each node and: git clone ${REPO_URL}"
echo "  3. Follow README.md steps in order"

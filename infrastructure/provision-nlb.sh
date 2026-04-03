#!/bin/bash
# infrastructure/provision-nlb.sh — Run from local machine after ingress controller is installed.
# Provisions the NLB, target groups, and listeners for ports 80 and 443.
# Usage: HTTP_NP=<nodeport> HTTPS_NP=<nodeport> bash infrastructure/provision-nlb.sh

set -euo pipefail

: "${HTTP_NP:?Set HTTP_NP to the ingress controller NodePort for port 80}"
: "${HTTPS_NP:?Set HTTPS_NP to the ingress controller NodePort for port 443}"

VPC_ID=$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" \
  --query 'Vpcs[0].VpcId' --output text)
SUBNET_ID=$(aws ec2 describe-subnets --filters "Name=defaultForAz,Values=true" \
  --query 'Subnets[0].SubnetId' --output text)
W1_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=k8s-worker-01" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)
W2_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=k8s-worker-02" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)

echo "VPC: $VPC_ID  SUBNET: $SUBNET_ID  W1: $W1_ID  W2: $W2_ID"

TG_HTTP=$(aws elbv2 create-target-group \
  --name challenge-lab-http --protocol TCP --port "$HTTP_NP" \
  --vpc-id "$VPC_ID" --target-type instance --health-check-protocol TCP \
  --query 'TargetGroups[0].TargetGroupArn' --output text)

TG_HTTPS=$(aws elbv2 create-target-group \
  --name challenge-lab-https --protocol TCP --port "$HTTPS_NP" \
  --vpc-id "$VPC_ID" --target-type instance --health-check-protocol TCP \
  --query 'TargetGroups[0].TargetGroupArn' --output text)

aws elbv2 register-targets --target-group-arn "$TG_HTTP"  --targets Id="$W1_ID" Id="$W2_ID"
aws elbv2 register-targets --target-group-arn "$TG_HTTPS" --targets Id="$W1_ID" Id="$W2_ID"

NLB_ARN=$(aws elbv2 create-load-balancer \
  --name challenge-lab-nlb --type network --subnets "$SUBNET_ID" \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text)

NLB_DNS=$(aws elbv2 describe-load-balancers \
  --load-balancer-arns "$NLB_ARN" \
  --query 'LoadBalancers[0].DNSName' --output text)

aws elbv2 create-listener --load-balancer-arn "$NLB_ARN" \
  --protocol TCP --port 80 --default-actions Type=forward,TargetGroupArn="$TG_HTTP"

aws elbv2 create-listener --load-balancer-arn "$NLB_ARN" \
  --protocol TCP --port 443 --default-actions Type=forward,TargetGroupArn="$TG_HTTPS"

echo ""
echo "==> NLB provisioned."
echo "    DNS: $NLB_DNS"
echo ""
echo "Update your DNS CNAMEs to point to: $NLB_DNS"
echo "  nginx.swampthing.online → $NLB_DNS"
echo "  argo.swampthing.online  → $NLB_DNS"

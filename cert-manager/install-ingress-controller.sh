#!/bin/bash
# cert-manager/install-ingress-controller.sh — Run from local machine as admin
# Installs the nginx ingress controller and patches the LoadBalancer service
# with a worker node's public IP as externalIPs.
#
# On bare kubeadm clusters (no cloud LB controller), the LoadBalancer service
# stays <pending> indefinitely. We patch it with externalIPs so that the ingress
# controller is reachable from the internet, which is required for the Let's
# Encrypt HTTP01 challenge to complete.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG="${REPO_ROOT}/config.env"
# shellcheck source=../config.env.example
[[ -f "$CONFIG" ]] && source "$CONFIG" || source "${CONFIG}.example"

INGRESS_VERSION="controller-v1.9.4"

echo "==> Installing nginx ingress controller (${INGRESS_VERSION})"
kubectl apply -f "https://raw.githubusercontent.com/kubernetes/ingress-nginx/${INGRESS_VERSION}/deploy/static/provider/cloud/deploy.yaml"

echo "==> Waiting for ingress controller deployment to be ready (up to 120s)"
kubectl wait --for=condition=Available deployment/ingress-nginx-controller \
  -n ingress-nginx --timeout=120s

echo "==> Detecting a worker node public IP for externalIPs patch"
# kubeadm nodes only report InternalIP (private). Look up the public IP
# via the EC2 API using the worker's private IP as a filter.
WORKER_PRIVATE_IP=$(kubectl get nodes \
  --selector='!node-role.kubernetes.io/control-plane' \
  -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

WORKER_IP=$(aws ec2 describe-instances \
  --filters "Name=private-ip-address,Values=${WORKER_PRIVATE_IP}" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text)

if [[ -z "$WORKER_IP" || "$WORKER_IP" == "None" ]]; then
  echo "ERROR: Could not detect worker public IP for private IP ${WORKER_PRIVATE_IP}."
  echo "Ensure aws CLI is configured and the instance is running."
  echo "Manually patch with:"
  echo "  kubectl patch svc ingress-nginx-controller -n ingress-nginx \\"
  echo "    -p '{\"spec\": {\"externalIPs\": [\"<WORKER-PUBLIC-IP>\"]}}'"
  exit 1
fi

echo "==> Patching ingress service with externalIPs: ${WORKER_IP}"
kubectl patch svc ingress-nginx-controller -n ingress-nginx \
  -p "{\"spec\": {\"externalIPs\": [\"${WORKER_IP}\"]}}"

echo ""
echo "==> Ingress controller service:"
kubectl get svc ingress-nginx-controller -n ingress-nginx

echo ""
echo "==> Next step: create DNS CNAME records at your registrar pointing to the NLB:"
echo "    nginx.${DOMAIN} → <NLB DNS name>"
echo "    argo.${DOMAIN}  → <NLB DNS name>"
echo ""
echo "    Then verify propagation with: dig nginx.${DOMAIN} +short"
echo "    Once propagated, run: bash cert-manager/install-cert-manager.sh"

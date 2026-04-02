#!/bin/bash
# nginx/deploy-as-dev-user.sh — Run on control-plane AS dev-user
# Deploys the Nginx application using the restricted dev-user kubeconfig.

set -euo pipefail

KUBECONFIG_PATH="${1:-../rbac/dev-user-kubeconfig.yaml}"

if [[ ! -f "${KUBECONFIG_PATH}" ]]; then
  echo "ERROR: Kubeconfig not found at ${KUBECONFIG_PATH}"
  echo "Run rbac/00-create-user.sh first."
  exit 1
fi

export KUBECONFIG="${KUBECONFIG_PATH}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Deploying nginx as $(kubectl config current-context)"
kubectl apply -f "${SCRIPT_DIR}/configmap-html.yaml"
kubectl apply -f "${SCRIPT_DIR}/deployment.yaml"
kubectl apply -f "${SCRIPT_DIR}/service.yaml"
kubectl apply -f "${SCRIPT_DIR}/ingress.yaml"

echo ""
echo "==> Waiting for rollout"
kubectl rollout status deployment/nginx -n nginx-app --timeout=120s

echo ""
echo "==> Pod status:"
kubectl get pods -n nginx-app

echo ""
echo "==> Ingress:"
kubectl get ingress -n nginx-app

echo ""
echo "Monitor TLS cert issuance (run as admin):"
echo "  kubectl get certificate -n nginx-app --watch"

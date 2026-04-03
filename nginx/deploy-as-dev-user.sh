#!/bin/bash
# nginx/deploy-as-dev-user.sh — Run on control-plane AS dev-user
# Deploys the Nginx application using the restricted dev-user kubeconfig.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=../config.env
source "${REPO_ROOT}/config.env"

KUBECONFIG_PATH="${1:-${REPO_ROOT}/rbac/dev-user-kubeconfig.yaml}"

if [[ ! -f "${KUBECONFIG_PATH}" ]]; then
  echo "ERROR: Kubeconfig not found at ${KUBECONFIG_PATH}"
  echo "Run rbac/00-create-user.sh first."
  exit 1
fi

export KUBECONFIG="${KUBECONFIG_PATH}"

echo "==> Deploying nginx as $(kubectl config current-context)"
DOMAIN="${DOMAIN}" REPO_URL="${REPO_URL}" envsubst < "${SCRIPT_DIR}/configmap-html.yaml" | kubectl apply -f -
kubectl apply -f "${SCRIPT_DIR}/deployment.yaml"
kubectl apply -f "${SCRIPT_DIR}/service.yaml"
DOMAIN="${DOMAIN}" envsubst < "${SCRIPT_DIR}/ingress.yaml" | kubectl apply -f -

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

#!/bin/bash
# cert-manager/install-cert-manager.sh — Run from local machine as admin
# Installs cert-manager and applies the Let's Encrypt ClusterIssuer.
#
# Prerequisites:
#   - Ingress controller is installed and port 80 is reachable from the internet
#   - DNS CNAME nginx.<DOMAIN> → NLB is propagated
#   - config.env is filled in at repo root

set -euo pipefail

CERT_MANAGER_VERSION="v1.14.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG="${REPO_ROOT}/config.env"
# shellcheck source=../config.env.example
[[ -f "$CONFIG" ]] && source "$CONFIG" || source "${CONFIG}.example"

echo "==> Installing cert-manager ${CERT_MANAGER_VERSION}"
kubectl apply -f "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"

echo "==> Waiting for cert-manager deployments to be available (up to 120s)"
kubectl wait --for=condition=Available deployment --all \
  -n cert-manager --timeout=120s

echo "==> Waiting for cert-manager webhook to be fully ready (30s)"
sleep 30

echo "==> Applying Let's Encrypt ClusterIssuer (email: ${ACME_EMAIL})"
ACME_EMAIL="${ACME_EMAIL}" envsubst < "${SCRIPT_DIR}/cluster-issuer.yaml" | kubectl apply -f -

echo "==> Waiting for ClusterIssuer to be ready"
sleep 10
kubectl get clusterissuer letsencrypt-prod

echo ""
echo "==> Done. cert-manager is installed and the ClusterIssuer is configured."
echo "    Once nginx Ingress is applied, run:"
echo "    kubectl get certificate -n nginx-app --watch"

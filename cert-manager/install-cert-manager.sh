#!/bin/bash
# cert-manager/install-cert-manager.sh — Run on control-plane as admin
# Installs cert-manager and applies the Let's Encrypt ClusterIssuer.
#
# Prerequisites:
#   - Ingress controller is installed and port 80 is reachable from the internet
#   - DNS A record nginx.swampthing.online → LoadBalancer IP is propagated

set -euo pipefail

CERT_MANAGER_VERSION="v1.14.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Installing cert-manager ${CERT_MANAGER_VERSION}"
kubectl apply -f "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"

echo "==> Waiting for cert-manager deployments to be available (up to 120s)"
kubectl wait --for=condition=Available deployment --all \
  -n cert-manager --timeout=120s

echo "==> Waiting for cert-manager webhook to be fully ready (30s)"
sleep 30

echo "==> Applying Let's Encrypt ClusterIssuer"
kubectl apply -f "${SCRIPT_DIR}/cluster-issuer.yaml"

echo "==> Waiting for ClusterIssuer to be ready"
sleep 10
kubectl get clusterissuer letsencrypt-prod

echo ""
echo "==> Done. cert-manager is installed and the ClusterIssuer is configured."
echo "    Once nginx Ingress is applied, run:"
echo "    kubectl get certificate -n nginx-app --watch"

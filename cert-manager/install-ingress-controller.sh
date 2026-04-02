#!/bin/bash
# cert-manager/install-ingress-controller.sh — Run on control-plane as admin
# Installs the nginx ingress controller (cloud provider / LoadBalancer mode).
#
# On AWS, this will provision an ELB. The external IP takes ~60s to appear.

set -euo pipefail

INGRESS_VERSION="controller-v1.9.4"

echo "==> Installing nginx ingress controller (${INGRESS_VERSION})"
kubectl apply -f "https://raw.githubusercontent.com/kubernetes/ingress-nginx/${INGRESS_VERSION}/deploy/static/provider/cloud/deploy.yaml"

echo "==> Waiting for ingress controller deployment to be ready (up to 120s)"
kubectl wait --for=condition=Available deployment/ingress-nginx-controller \
  -n ingress-nginx --timeout=120s

echo ""
echo "==> Watching for LoadBalancer external IP (Ctrl+C when IP appears):"
echo "    Create a DNS A record: nginx.swampthing.online → <EXTERNAL-IP>"
echo ""
kubectl get svc ingress-nginx-controller -n ingress-nginx --watch

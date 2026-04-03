#!/bin/bash
# argocd/install-argocd.sh — Run from local machine as admin
# Installs ArgoCD and exposes the UI via NodePort.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=../config.env
source "${REPO_ROOT}/config.env"

echo "==> Creating argocd namespace and installing ArgoCD"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

echo "==> Waiting for argocd-server to be available (up to 120s)"
kubectl wait --for=condition=Available deployment/argocd-server \
  -n argocd --timeout=120s

echo "==> Exposing ArgoCD UI via NodePort (fallback access)"
kubectl patch svc argocd-server -n argocd \
  -p '{"spec": {"type": "NodePort"}}'

# Wait for NodePort to be assigned
sleep 3
ARGOCD_PORT=$(kubectl get svc argocd-server -n argocd \
  -o jsonpath='{.spec.ports[?(@.port==443)].nodePort}')

CONTROL_PLANE_IP=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=k8s-control-plane" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text 2>/dev/null || echo "<ELASTIC-IP>")

echo ""
echo "==> Applying ArgoCD ingress (argo.${DOMAIN})"
kubectl apply -f "${SCRIPT_DIR}/argocd-ingress.yaml"

echo ""
echo "==> Applying nginx ArgoCD Application"
kubectl apply -f "${SCRIPT_DIR}/application.yaml"

echo ""
echo "==> ArgoCD access:"
echo "    Via ingress (after DNS): https://argo.${DOMAIN}"
echo "    Via NodePort (direct):   https://${CONTROL_PLANE_IP}:${ARGOCD_PORT}"
echo "    Username: admin"
echo -n "    Password: "
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d && echo

echo ""
echo "==> ArgoCD application status:"
kubectl get application nginx-app -n argocd

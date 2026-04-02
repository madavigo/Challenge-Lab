#!/bin/bash
# rbac/01-apply-rbac.sh — Run on control-plane as admin
# Applies namespace, Role, RoleBinding, and NetworkPolicy.
# Run this BEFORE 00-create-user.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Creating nginx-app namespace"
kubectl apply -f "${SCRIPT_DIR}/namespace.yaml"

echo "==> Applying Role and RoleBinding"
kubectl apply -f "${SCRIPT_DIR}/role.yaml"
kubectl apply -f "${SCRIPT_DIR}/rolebinding.yaml"

echo "==> Applying Calico NetworkPolicy"
kubectl apply -f "${SCRIPT_DIR}/networkpolicy.yaml"

echo ""
echo "==> RBAC summary:"
kubectl get role,rolebinding -n nginx-app -o wide
echo ""
echo "==> NetworkPolicy:"
kubectl get networkpolicy -n nginx-app

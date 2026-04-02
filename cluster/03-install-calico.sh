#!/bin/bash
# 03-install-calico.sh — Run on control-plane (as admin)
# Installs Calico CNI v3.27. Run AFTER all workers have joined.

set -euo pipefail

CALICO_VERSION="v3.27.0"

echo "==> Applying Calico manifest (${CALICO_VERSION})"
kubectl apply -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml"

echo "==> Waiting for calico-node DaemonSet to be ready (up to 120s)"
kubectl rollout status daemonset/calico-node -n kube-system --timeout=120s

echo "==> All nodes should now show Ready:"
kubectl get nodes

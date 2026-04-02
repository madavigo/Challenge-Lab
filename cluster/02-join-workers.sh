#!/bin/bash
# 02-join-workers.sh — Run on EACH worker node
# Replace the placeholder values with the actual token and hash from kubeadm init output.
#
# Usage: CONTROL_PLANE_IP=<ip> TOKEN=<token> CA_HASH=<hash> bash 02-join-workers.sh

set -euo pipefail

: "${CONTROL_PLANE_IP:?Set CONTROL_PLANE_IP to the control-plane public IP}"
: "${TOKEN:?Set TOKEN to the kubeadm join token from init output}"
: "${CA_HASH:?Set CA_HASH to the discovery-token-ca-cert-hash from init output}"

echo "==> Joining cluster at ${CONTROL_PLANE_IP}:6443"
sudo kubeadm join "${CONTROL_PLANE_IP}:6443" \
  --token "${TOKEN}" \
  --discovery-token-ca-cert-hash "sha256:${CA_HASH}"

echo "==> Worker joined. Verify on control-plane with: kubectl get nodes"

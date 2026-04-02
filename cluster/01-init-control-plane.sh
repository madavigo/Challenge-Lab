#!/bin/bash
# 01-init-control-plane.sh — Run on the control-plane node ONLY
# Initializes the kubeadm cluster and configures kubectl for the ubuntu user.

set -euo pipefail

# Fetch the public IP from EC2 instance metadata (IMDSv1)
CONTROL_PLANE_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)
echo "==> Control-plane public IP: ${CONTROL_PLANE_IP}"

echo "==> Running kubeadm init"
sudo kubeadm init \
  --pod-network-cidr=192.168.0.0/16 \
  --control-plane-endpoint="${CONTROL_PLANE_IP}:6443" \
  --apiserver-cert-extra-sans="${CONTROL_PLANE_IP}"

echo "==> Configuring kubectl for current user"
mkdir -p "$HOME/.kube"
sudo cp -i /etc/kubernetes/admin.conf "$HOME/.kube/config"
sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"

echo ""
echo "================================================================"
echo "IMPORTANT: Save the 'kubeadm join' command printed above."
echo "You will need it to join the worker nodes in 02-join-workers.sh"
echo "================================================================"
echo ""
echo "Verify control-plane is running (status will be NotReady until Calico is installed):"
kubectl get nodes

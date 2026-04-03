#!/bin/bash
# 01-init-control-plane.sh — Run on the control-plane node ONLY
# Initializes the kubeadm cluster and configures kubectl for the ubuntu user.
#
# AWS EC2 networking:
#   - kubeadm uses the PRIVATE IP as --control-plane-endpoint so the kubelet
#     can reach the API server locally (EC2 instances cannot hairpin NAT through
#     their own Elastic/public IP).
#   - The Elastic/public IP is added as an extra SAN so external kubectl
#     and worker join commands work from outside the VPC.
#   - A second kubeconfig (admin-external.conf) is written with the public IP
#     for use on your local machine.

set -euo pipefail

# Fetch IPs from EC2 instance metadata (IMDSv1)
PRIVATE_IP=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)
PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)

echo "==> Private IP: ${PRIVATE_IP}"
echo "==> Public IP (Elastic): ${PUBLIC_IP}"

echo "==> Running kubeadm init"
sudo kubeadm init \
  --pod-network-cidr=192.168.0.0/16 \
  --control-plane-endpoint="${PRIVATE_IP}:6443" \
  --apiserver-advertise-address="${PRIVATE_IP}" \
  --apiserver-cert-extra-sans="${PUBLIC_IP},${PRIVATE_IP}"

echo "==> Configuring kubectl for current user (uses private IP — works on this node)"
mkdir -p "$HOME/.kube"
sudo cp -i /etc/kubernetes/admin.conf "$HOME/.kube/config"
sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"

echo "==> Writing external kubeconfig (uses public Elastic IP — for your local machine)"
sudo cp /etc/kubernetes/admin.conf "$HOME/admin-external.conf"
sudo chown "$(id -u):$(id -g)" "$HOME/admin-external.conf"
sed -i "s|server: https://${PRIVATE_IP}:6443|server: https://${PUBLIC_IP}:6443|" \
  "$HOME/admin-external.conf"
echo "    Copy this to your laptop: scp ubuntu@${PUBLIC_IP}:~/admin-external.conf ~/.kube/config"

echo ""
echo "================================================================"
echo "IMPORTANT: Save the 'kubeadm join' command printed above."
echo "You will need it to join the worker nodes in 02-join-workers.sh"
echo "================================================================"
echo ""
echo "==> Verifying control-plane node (NotReady is expected until Calico is installed):"
kubectl get nodes

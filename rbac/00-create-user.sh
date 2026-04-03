#!/bin/bash
# rbac/00-create-user.sh — Run on control-plane as admin
# Creates dev-user via the Kubernetes CertificateSigningRequest workflow.
# Output: dev-user.key, dev-user.crt, dev-user-kubeconfig.yaml

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${SCRIPT_DIR}/../config.env"
# shellcheck source=../config.env.example
[[ -f "$CONFIG" ]] && source "$CONFIG" || source "${CONFIG}.example"

USERNAME="dev-user"
NAMESPACE="nginx-app"
CSR_NAME="${USERNAME}-csr"
# Derive a cluster name from the domain (e.g. swampthing.online → swampthing-demo)
CLUSTER_NAME="${DOMAIN%%.*}-demo"

echo "==> Generating private key for ${USERNAME}"
openssl genrsa -out "${USERNAME}.key" 4096

echo "==> Creating Certificate Signing Request"
# CN = username (matched by RoleBinding subject.name)
# O  = group (can be used for group-level bindings when managing many users)
openssl req -new \
  -key "${USERNAME}.key" \
  -out "${USERNAME}.csr" \
  -subj "/CN=${USERNAME}/O=nginx-deployers"

echo "==> Submitting CSR to the Kubernetes API"
# expirationSeconds: 86400 = 24-hour TTL
# Short-lived certs limit the exposure window if a kubeconfig is compromised.
# In production: automate rotation with a controller or external secrets manager.
cat <<EOF | kubectl apply -f -
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: ${CSR_NAME}
spec:
  request: $(base64 < "${USERNAME}.csr" | tr -d '\n')
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: 86400
  usages:
  - client auth
EOF

echo "==> Approving CSR (admin gate — this is deliberate)"
kubectl certificate approve "${CSR_NAME}"

echo "==> Retrieving signed certificate"
kubectl get csr "${CSR_NAME}" \
  -o jsonpath='{.status.certificate}' | base64 -d > "${USERNAME}.crt"

echo "==> Certificate details:"
openssl x509 -in "${USERNAME}.crt" -noout -subject -dates

echo "==> Building kubeconfig for ${USERNAME}"
# Use the public Elastic IP so this kubeconfig works from outside the VPC.
# The node's ~/.kube/config uses the private IP — we override it here.
PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)
CLUSTER_SERVER="https://${PUBLIC_IP}:6443"
CLUSTER_CA=$(kubectl config view --raw --minify \
  -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')

CONTEXT_NAME="${USERNAME}@${CLUSTER_NAME}"

cat <<EOF > "${USERNAME}-kubeconfig.yaml"
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority-data: ${CLUSTER_CA}
    server: ${CLUSTER_SERVER}
  name: ${CLUSTER_NAME}
contexts:
- context:
    cluster: ${CLUSTER_NAME}
    namespace: ${NAMESPACE}
    user: ${USERNAME}
  name: ${CONTEXT_NAME}
current-context: ${CONTEXT_NAME}
users:
- name: ${USERNAME}
  user:
    client-certificate-data: $(base64 < "${USERNAME}.crt" | tr -d '\n')
    client-key-data: $(base64 < "${USERNAME}.key" | tr -d '\n')
EOF

echo ""
echo "==> Verifying access (expect yes/no as shown):"
# auth can-i returns exit code 1 for "no" — use || true so set -e doesn't trip
echo -n "  create deployments in nginx-app [expect: yes]: "
kubectl --kubeconfig="${USERNAME}-kubeconfig.yaml" auth can-i create deployments -n nginx-app || true
echo -n "  create deployments in default   [expect: no]:  "
kubectl --kubeconfig="${USERNAME}-kubeconfig.yaml" auth can-i create deployments -n default || true
echo -n "  get secrets in nginx-app        [expect: no]:  "
kubectl --kubeconfig="${USERNAME}-kubeconfig.yaml" auth can-i get secrets -n nginx-app || true
echo -n "  get nodes                       [expect: no]:  "
kubectl --kubeconfig="${USERNAME}-kubeconfig.yaml" auth can-i get nodes || true

echo ""
echo "==> Done. Kubeconfig written to ${USERNAME}-kubeconfig.yaml"
echo "    WARNING: This file contains the private key. Do not commit it to git."

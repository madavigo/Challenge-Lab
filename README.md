# Kubernetes Challenge Lab — RBAC & Nginx Deployment

A production-realistic kubeadm Kubernetes cluster with certificate-based RBAC, GitOps-driven deployment, and TLS via cert-manager + Let's Encrypt.

**Live demo:** [https://nginx.swampthing.online](https://nginx.swampthing.online)

---

## Architecture

```
                    ┌──────────────────────────────────────┐
                    │              AWS VPC                 │
                    │                                      │
                    │   ┌──────────────────────────────┐   │
Internet ──────────►│   │       control-plane          │   │
(kubectl, HTTPS,    │   │       t3.medium (2vCPU/4GB)  │   │
 ArgoCD UI)         │   │       Ubuntu 22.04 LTS       │   │
                    │   └──────────────┬───────────────┘   │
                    │                  │  kubeadm join     │
                    │        ┌─────────┴──────────┐        │
                    │        │                    │        │
                    │  ┌─────┴──────┐    ┌────────┴────┐   │
                    │  │ worker-01  │    │  worker-02  │   │
                    │  │ t3.small   │    │  t3.small   │   │
                    │  └────────────┘    └─────────────┘   │
                    └──────────────────────────────────────┘
                                   │
                              DNS A record
                    nginx.swampthing.online → LoadBalancer IP
```

**Stack:** kubeadm 1.29 · Calico CNI · nginx ingress controller · cert-manager · Let's Encrypt · ArgoCD

---

## Prerequisites (local machine)

- AWS account with EC2 access
- `aws` CLI configured (`aws configure`)
- `kubectl` installed
- `openssl` installed
- SSH key pair for EC2 access

---

## Deployment Steps

### 1. AWS Infrastructure

See [`infrastructure/aws-setup.md`](infrastructure/aws-setup.md) for EC2 provisioning, security group rules, Elastic IP, and DNS setup.

### 2. Bootstrap all nodes

Run on **every node** (control-plane and both workers):

```bash
scp cluster/00-prereqs.sh ubuntu@<NODE-IP>:~
ssh ubuntu@<NODE-IP> bash 00-prereqs.sh
```

### 3. Initialize the control plane

Run on the **control-plane node only**:

```bash
scp cluster/01-init-control-plane.sh ubuntu@<CONTROL-PLANE-IP>:~
ssh ubuntu@<CONTROL-PLANE-IP> bash 01-init-control-plane.sh
```

Save the `kubeadm join` command from the output.

Copy the admin kubeconfig to your local machine:

```bash
scp ubuntu@<CONTROL-PLANE-IP>:~/.kube/config ~/.kube/config
# Edit the server address if needed to use the Elastic IP
```

### 4. Join worker nodes

On **each worker**, set the values from the kubeadm init output:

```bash
scp cluster/02-join-workers.sh ubuntu@<WORKER-IP>:~
ssh ubuntu@<WORKER-IP> \
  CONTROL_PLANE_IP=<ip> TOKEN=<token> CA_HASH=<hash> \
  bash 02-join-workers.sh
```

### 5. Install Calico CNI

From your local machine (using the admin kubeconfig):

```bash
bash cluster/03-install-calico.sh
```

Verify: `kubectl get nodes` — all three should show `Ready`.

### 6. Apply RBAC and create dev-user

```bash
bash rbac/01-apply-rbac.sh
bash rbac/00-create-user.sh
```

This creates `dev-user` via the Kubernetes CSR workflow and writes `rbac/dev-user-kubeconfig.yaml`.

> **Note:** `dev-user-kubeconfig.yaml` contains a private key. It is listed in `.gitignore` and must not be committed.

Verify access boundaries:

```bash
kubectl --kubeconfig=rbac/dev-user-kubeconfig.yaml auth can-i create deployments -n nginx-app  # yes
kubectl --kubeconfig=rbac/dev-user-kubeconfig.yaml auth can-i get secrets -n nginx-app         # no
kubectl --kubeconfig=rbac/dev-user-kubeconfig.yaml auth can-i get nodes                        # no
```

### 7. Install Ingress Controller and cert-manager

```bash
bash cert-manager/install-ingress-controller.sh
# Wait for LoadBalancer IP, create DNS A record (see infrastructure/aws-setup.md)

bash cert-manager/install-cert-manager.sh
```

### 8. Deploy Nginx as dev-user

```bash
bash nginx/deploy-as-dev-user.sh
```

Watch TLS cert issuance (as admin):

```bash
kubectl get certificate -n nginx-app --watch
```

Once `READY: True`, visit [https://nginx.swampthing.online](https://nginx.swampthing.online).

### 9. Install ArgoCD (GitOps bonus)

```bash
bash argocd/install-argocd.sh
```

The ArgoCD Application watches the `nginx/` directory of this repo. Any commit to those manifests automatically syncs to the cluster within ~3 minutes.

---

## Repository Structure

```
.
├── infrastructure/
│   └── aws-setup.md                ← EC2 provisioning, security groups, DNS
├── cluster/
│   ├── 00-prereqs.sh               ← Run on ALL nodes
│   ├── 01-init-control-plane.sh    ← Run on control-plane only
│   ├── 02-join-workers.sh          ← Run on each worker
│   └── 03-install-calico.sh        ← Run from local machine (admin kubeconfig)
├── rbac/
│   ├── 00-create-user.sh           ← CSR → cert → kubeconfig workflow
│   ├── 01-apply-rbac.sh            ← Namespace, Role, RoleBinding, NetworkPolicy
│   ├── namespace.yaml
│   ├── role.yaml
│   ├── rolebinding.yaml
│   └── networkpolicy.yaml
├── nginx/                          ← ArgoCD source of truth
│   ├── configmap-html.yaml
│   ├── deployment.yaml
│   ├── service.yaml
│   ├── ingress.yaml
│   └── deploy-as-dev-user.sh
├── cert-manager/
│   ├── cluster-issuer.yaml
│   ├── install-ingress-controller.sh
│   └── install-cert-manager.sh
├── argocd/
│   ├── application.yaml
│   └── install-argocd.sh
├── DESIGN.md                       ← Design decisions and tradeoffs
└── README.md
```

---

## Key Design Decisions

See [`DESIGN.md`](DESIGN.md) for full rationale. Summary:

- **kubeadm** — real production bootstrap, not a wrapper. Exposes the actual K8s primitives.
- **Calico** — adds NetworkPolicy enforcement; Flannel does not support it.
- **CSR-based user auth** — native K8s mechanism; no external IdP dependency.
- **cert-manager + Let's Encrypt** — automated lifecycle management, publicly trusted cert, no browser warnings in the demo.
- **ArgoCD** — visual GitOps loop that makes the "git as source of truth" story tangible in a 15-minute demo.

---

## Security Notes

- Port 6443 (API server) and port 22 (SSH) are restricted to a specific IP in the security group — the API server is not exposed to the internet.
- `dev-user` has a `Role` (not `ClusterRole`) scoped to `nginx-app` only. They cannot read secrets, list nodes, or access any other namespace.
- The Calico NetworkPolicy denies all ingress to nginx pods except from the ingress controller namespace.
- Certificates are issued with a 24-hour TTL (`expirationSeconds: 86400`). In production, rotation would be automated.
- `dev-user-kubeconfig.yaml` and `*.key`/`*.crt` files are excluded from git via `.gitignore`.

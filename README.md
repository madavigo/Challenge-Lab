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

- AWS account with EC2 access and billing enabled (t3.medium is not free-tier eligible)
- `aws` CLI configured (`aws configure`)
- `kubectl` installed
- `openssl` installed
- SSH key pair created: `aws ec2 create-key-pair --key-name challenge-lab --query 'KeyMaterial' --output text > ~/.ssh/challenge-lab.pem && chmod 400 ~/.ssh/challenge-lab.pem`

---

## Deployment Steps

### 1. AWS Infrastructure

Provision EC2 instances, security group, and Elastic IP by following [`infrastructure/aws-setup.md`](infrastructure/aws-setup.md).

At the end of that step you will have:
- 3 running instances: `k8s-control-plane` (t3.medium), `k8s-worker-01`, `k8s-worker-02` (t3.small)
- Elastic IP associated to control-plane
- Security group with all required rules

---

### 2. Bootstrap all nodes

SSH into **each node** and clone the repo, then run the prereqs script:

```bash
ssh -i ~/.ssh/challenge-lab.pem ubuntu@<NODE-IP>
```

Then on each node:
```bash
git clone https://github.com/madavigo/Challenge-Lab.git
cd Challenge-Lab
bash cluster/00-prereqs.sh
```

Do this for all three nodes (control-plane and both workers). Can be done in parallel.

---

### 3. Initialize the control plane

On the **control-plane node only**:

```bash
bash cluster/01-init-control-plane.sh
```

This will:
- Run `kubeadm init` using the private IP as endpoint (required for AWS EC2 — nodes cannot reach their own Elastic IP)
- Configure `~/.kube/config` on the node (uses private IP)
- Write `~/admin-external.conf` with the Elastic IP (for your local machine)
- Print the `kubeadm join` command — **save this output**

Copy the external kubeconfig to your local machine:

```bash
scp -i ~/.ssh/challenge-lab.pem ubuntu@<ELASTIC-IP>:~/admin-external.conf ~/.kube/config
```

Verify from your local machine:
```bash
kubectl get nodes
# control-plane shows NotReady — expected until Calico is installed
```

---

### 4. Join worker nodes

On **each worker node**, using the token and hash from the kubeadm init output:

```bash
cd Challenge-Lab
CONTROL_PLANE_IP=<private-ip> TOKEN=<token> CA_HASH=<hash> bash cluster/02-join-workers.sh
```

---

### 5. Install Calico CNI

From your **local machine**:

```bash
bash cluster/03-install-calico.sh
```

Verify all nodes are Ready:
```bash
kubectl get nodes
# All three should show Ready
```

---

### 6. Apply RBAC and create dev-user

On the **control-plane node**:

```bash
cd Challenge-Lab
bash rbac/01-apply-rbac.sh
bash rbac/00-create-user.sh
```

This creates:
- `nginx-app` namespace
- `nginx-deployer` Role and RoleBinding (scoped to `nginx-app` only)
- Calico NetworkPolicy (deny-all ingress except from ingress controller)
- `dev-user` certificate via the Kubernetes CSR workflow
- `dev-user-kubeconfig.yaml` (gitignored — contains private key)

Copy the kubeconfig to your local machine:
```bash
scp -i ~/.ssh/challenge-lab.pem ubuntu@<ELASTIC-IP>:~/Challenge-Lab/dev-user-kubeconfig.yaml rbac/dev-user-kubeconfig.yaml
```

Verify access boundaries from local machine:
```bash
kubectl --kubeconfig=rbac/dev-user-kubeconfig.yaml auth can-i create deployments -n nginx-app  # yes
kubectl --kubeconfig=rbac/dev-user-kubeconfig.yaml auth can-i create deployments -n default    # no
kubectl --kubeconfig=rbac/dev-user-kubeconfig.yaml auth can-i get secrets -n nginx-app         # no
kubectl --kubeconfig=rbac/dev-user-kubeconfig.yaml auth can-i get nodes                        # no
```

---

### 7. Install ingress controller and cert-manager

From your **local machine**:

```bash
bash cert-manager/install-ingress-controller.sh
```

Watch for the LoadBalancer external IP (takes ~60s):
```bash
kubectl get svc ingress-nginx-controller -n ingress-nginx --watch
```

Once you have the IP, create a DNS A record at your registrar:
```
nginx.swampthing.online → <LoadBalancer external IP>
```

Wait for DNS propagation (~5 min), then verify:
```bash
dig nginx.swampthing.online +short
```

Then install cert-manager:
```bash
bash cert-manager/install-cert-manager.sh
```

---

### 8. Deploy Nginx as dev-user

From your **local machine**:

```bash
bash nginx/deploy-as-dev-user.sh rbac/dev-user-kubeconfig.yaml
```

Watch TLS certificate issuance (as admin):
```bash
kubectl get certificate -n nginx-app --watch
# READY transitions False → True within ~60s once DNS has propagated
```

Test:
```bash
curl -I https://nginx.swampthing.online
# Expect HTTP/2 200 with a valid Let's Encrypt cert
```

---

### 9. Install ArgoCD (GitOps)

From your **local machine**:

```bash
bash argocd/install-argocd.sh
```

This installs ArgoCD and creates an Application that watches the `nginx/` directory of this repo. Any commit to those manifests automatically syncs to the cluster within ~3 minutes.

To demo the GitOps loop: edit `nginx/configmap-html.yaml`, commit and push — watch ArgoCD detect drift and sync.

---

## Repository Structure

```
.
├── infrastructure/
│   └── aws-setup.md                ← EC2 provisioning, security groups, DNS
├── cluster/
│   ├── 00-prereqs.sh               ← Run on ALL nodes after cloning repo
│   ├── 01-init-control-plane.sh    ← Run on control-plane only
│   ├── 02-join-workers.sh          ← Run on each worker
│   └── 03-install-calico.sh        ← Run from local machine
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

- Port 22 (SSH) is restricted to your IP only. Port 6443 allows your IP (external kubectl) and the node security group (worker → control-plane communication).
- `dev-user` has a `Role` (not `ClusterRole`) scoped to `nginx-app` only. They cannot read secrets, list nodes, or access any other namespace.
- The Calico NetworkPolicy denies all ingress to nginx pods except from the ingress controller namespace.
- Certificates are issued with a 24-hour TTL (`expirationSeconds: 86400`). In production, rotation would be automated.
- `dev-user-kubeconfig.yaml` and `*.key`/`*.crt` files are excluded from git via `.gitignore`.

# Kubernetes Challenge Lab — RBAC & Nginx Deployment

A production-realistic kubeadm Kubernetes cluster with certificate-based RBAC, GitOps-driven deployment, and TLS via cert-manager + Let's Encrypt.

**Live demo:** [https://nginx.swampthing.online](https://nginx.swampthing.online)

---

## Architecture

```
                         AWS NLB (challenge-lab-nlb)
                          ports 80 + 443 → NodePorts
                                   │
                    ┌──────────────────────────────────────┐
                    │              AWS VPC                 │
                    │                                      │
                    │   ┌──────────────────────────────┐   │
Internet ──────────►│   │       control-plane          │   │
(kubectl)           │   │       t3.small (2vCPU/2GB)   │   │
                    │   │       Ubuntu 22.04 LTS       │   │
                    │   └──────────────┬───────────────┘   │
                    │                  │  kubeadm join     │
                    │        ┌─────────┴──────────┐        │
                    │        │                    │        │
                    │  ┌─────┴──────┐    ┌────────┴────┐   │
                    │  │ worker-01  │    │  worker-02  │   │
                    │  │ t3.small   │    │  t3.small   │   │
                    │  └────────────┘    └─────────────┘   │
                    └──────────────────────────────────────┘

DNS CNAMEs → NLB:
  nginx.swampthing.online → challenge-lab-nlb-*.elb.us-east-1.amazonaws.com
  argo.swampthing.online  → challenge-lab-nlb-*.elb.us-east-1.amazonaws.com
```

**Stack:** kubeadm 1.29 · Calico CNI · nginx ingress controller · cert-manager · Let's Encrypt · ArgoCD

---

## Prerequisites (local machine)

- AWS account with EC2 access and billing enabled
- `aws` CLI configured (`aws configure`)
- `kubectl` installed
- `openssl` installed
- SSH key pair created: `aws ec2 create-key-pair --key-name challenge-lab --query 'KeyMaterial' --output text > ~/.ssh/challenge-lab.pem && chmod 400 ~/.ssh/challenge-lab.pem`

All scripts source `config.env` automatically, falling back to `config.env.example` if it doesn't exist. The example file has the correct values for this repo, so a fresh `git clone` works without any extra setup. To override (e.g. for your own fork), copy and edit:

```bash
cp config.env.example config.env
# Edit DOMAIN, ACME_EMAIL, REPO_URL
```

---

## Deployment Steps

### 1. AWS Infrastructure

Follow [`infrastructure/aws-setup.md`](infrastructure/aws-setup.md) completely before moving to step 2. It covers all AWS provisioning in order:

- Security group and all inbound rules
- 3 EC2 instances (control-plane, worker-01, worker-02 — all t3.small)
- Elastic IP associated to control-plane
- Network Load Balancer — optional but recommended (see [`infrastructure/aws-setup.md`](infrastructure/aws-setup.md#network-load-balancer)); provisioned after step 7, then return here
- DNS CNAME records pointing to the NLB

At the end of the full aws-setup.md flow you will have all infrastructure in place and DNS propagated.

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
# Note: the file is written to ~/Challenge-Lab/ (the script's working directory)
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

This script auto-detects a worker node's public IP via AWS CLI and patches the ingress service with `externalIPs`. On bare kubeadm there is no cloud LB controller, so the LoadBalancer service would otherwise stay `<pending>` indefinitely.

**Load balancer — recommended:** Return to [`infrastructure/aws-setup.md`](infrastructure/aws-setup.md#network-load-balancer) and follow the **Network Load Balancer** and **DNS** sections. An NLB is the right choice for kubeadm on AWS — it provides stable DNS, routes across both workers, and is required for Let's Encrypt HTTP-01 to succeed. It costs ~$0.20/day and is cleaned up by `infrastructure/teardown.sh`.

> Alternatives exist — `externalIPs` (patch the ingress service with a worker's public IP directly) or raw NodePort access — but both are single-node and not suitable for a reproducible demo. The NLB is the production-appropriate path on AWS without EKS.

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

This installs ArgoCD, patches the service to NodePort, applies the ArgoCD ingress for `argo.swampthing.online`, and creates an Application that watches the `nginx/` directory of this repo.

> **Expected warning:** During install you may see `The CustomResourceDefinition "applicationsets.argoproj.io" is invalid: metadata.annotations: Too long: must have at most 262144 bytes`. This is a known ArgoCD CRD size issue and is non-fatal — the script handles it with `|| true` and all components install correctly.

The script prints the ArgoCD UI URL and initial admin password. You can also access it directly via NodePort:
```bash
ARGOCD_PORT=$(kubectl get svc argocd-server -n argocd -o jsonpath='{.spec.ports[?(@.port==443)].nodePort}')
echo "https://<ELASTIC-IP>:${ARGOCD_PORT}"
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d && echo
```

ArgoCD UI: `https://argo.swampthing.online` (username: `admin`)

To demo the GitOps loop: edit `nginx/configmap-html.yaml`, commit and push — watch ArgoCD detect drift and sync within ~3 minutes.

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
│   ├── argocd-ingress.yaml
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

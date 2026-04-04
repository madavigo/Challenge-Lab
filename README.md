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
- `kubectl` and `openssl` installed

All scripts source `config.env` automatically, falling back to `config.env.example` if it doesn't exist. The example file has the correct values for this repo so a fresh `git clone` works without any extra setup. To override (e.g. for your own fork), copy and edit:

```bash
cp config.env.example config.env
# Edit DOMAIN, ACME_EMAIL, REPO_URL
```

---

## Deployment Steps

### 1. Create SSH Key Pair

```bash
aws ec2 create-key-pair \
  --key-name challenge-lab \
  --query 'KeyMaterial' \
  --output text > ~/.ssh/challenge-lab.pem && \
chmod 400 ~/.ssh/challenge-lab.pem
```

---

### 2. Gather AWS Info

```bash
# Latest Ubuntu 22.04 LTS AMI
aws ec2 describe-images \
  --owners 099720109477 \
  --filters "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" \
            "Name=state,Values=available" \
  --query 'sort_by(Images, &CreationDate)[-1].{AMI:ImageId,Name:Name,Date:CreationDate}' \
  --output table

# Default VPC and subnet
aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" \
  --query 'Vpcs[0].{VpcId:VpcId,CIDR:CidrBlock}' --output table

aws ec2 describe-subnets --filters "Name=defaultForAz,Values=true" \
  --query 'Subnets[0].{SubnetId:SubnetId,AZ:AvailabilityZone}' --output table
```

Save `AMI`, `VpcId`, and `SubnetId` — you'll use them in the next steps.

---

### 3. Create Security Group

```bash
SG_ID=$(aws ec2 create-security-group \
  --group-name k8s-challenge-lab \
  --description "Kubernetes challenge lab - control-plane and workers" \
  --vpc-id <VPC_ID> \
  --query 'GroupId' --output text)
echo "Security Group ID: $SG_ID"
```

Apply all inbound rules one at a time:

```bash
MY_IP=$(curl -s https://checkip.amazonaws.com)

aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 22 --cidr ${MY_IP}/32
aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 6443 --cidr ${MY_IP}/32
aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 6443 --source-group $SG_ID
aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 2379-2380 --source-group $SG_ID
aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 10250-10259 --source-group $SG_ID
aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 10256 --source-group $SG_ID
aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 179 --source-group $SG_ID
aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol udp --port 4789 --source-group $SG_ID
aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol 4 --port -1 --source-group $SG_ID
aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 30000-32767 --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 80 --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress --group-id $SG_ID --protocol tcp --port 443 --cidr 0.0.0.0/0
```

| Port/Range | Protocol | Source | Purpose |
|---|---|---|---|
| 22 | TCP | Your IP | SSH |
| 6443 | TCP | Your IP | Kubernetes API (external kubectl) |
| 6443 | TCP | Node SG | Kubernetes API (worker → control-plane) |
| 2379–2380 | TCP | Node SG | etcd peer communication |
| 10250–10259 | TCP | Node SG | kubelet, scheduler, controller manager |
| 10256 | TCP | Node SG | kube-proxy health check |
| 179 | TCP | Node SG | Calico BGP |
| 4789 | UDP | Node SG | Calico VXLAN |
| 4 (IPIP) | IP | Node SG | Calico IPIP — required for pod internet on AWS |
| 30000–32767 | TCP | 0.0.0.0/0 | NodePort range |
| 80 | TCP | 0.0.0.0/0 | HTTP (Let's Encrypt HTTP-01 challenge) |
| 443 | TCP | 0.0.0.0/0 | HTTPS |

> **Note:** "Node SG" means the security group itself as source — allows all instances in the group to communicate freely on those ports.

---

### 4. Launch EC2 Instances

```bash
AMI=<ami-id>
SG_ID=<sg-id>
SUBNET=<subnet-id>

CP_ID=$(aws ec2 run-instances \
  --image-id $AMI --instance-type t3.small --key-name challenge-lab \
  --security-group-ids $SG_ID --subnet-id $SUBNET --associate-public-ip-address \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=k8s-control-plane},{Key=Project,Value=challenge-lab}]' \
  --query 'Instances[0].InstanceId' --output text)
echo "Control-plane: $CP_ID"

W1_ID=$(aws ec2 run-instances \
  --image-id $AMI --instance-type t3.small --key-name challenge-lab \
  --security-group-ids $SG_ID --subnet-id $SUBNET --associate-public-ip-address \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=k8s-worker-01},{Key=Project,Value=challenge-lab}]' \
  --query 'Instances[0].InstanceId' --output text)
echo "Worker-01: $W1_ID"

W2_ID=$(aws ec2 run-instances \
  --image-id $AMI --instance-type t3.small --key-name challenge-lab \
  --security-group-ids $SG_ID --subnet-id $SUBNET --associate-public-ip-address \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=k8s-worker-02},{Key=Project,Value=challenge-lab}]' \
  --query 'Instances[0].InstanceId' --output text)
echo "Worker-02: $W2_ID"
```

Disable source/dest check on all nodes — required for Calico pod networking on AWS:

```bash
for ID in $CP_ID $W1_ID $W2_ID; do
  aws ec2 modify-instance-attribute --instance-id $ID --no-source-dest-check
done
echo "Source/dest check disabled."
```

---

### 5. Allocate Elastic IP

Assign an Elastic IP to the control-plane. This keeps the kubeconfig valid across reboots and ensures the API server certificate SANs remain valid.

```bash
aws ec2 allocate-address --domain vpc
# Note the AllocationId

aws ec2 associate-address \
  --instance-id $CP_ID \
  --allocation-id <AllocationId>
```

---

### 6. Bootstrap all nodes

Get all instance IPs:

```bash
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=k8s-control-plane,k8s-worker-01,k8s-worker-02" \
  --query 'Reservations[*].Instances[*].{Name:Tags[?Key==`Name`].Value|[0],InstanceId:InstanceId,PrivateIP:PrivateIpAddress,PublicIP:PublicIpAddress,State:State.Name}' \
  --output table
```

SSH into each node and run (can be done in parallel):

```bash
git clone https://github.com/madavigo/Challenge-Lab.git
cd Challenge-Lab
bash cluster/00-prereqs.sh
```

Installs: containerd, kubeadm/kubelet/kubectl (v1.29), kernel modules, sysctl, disables swap.

---

### 7. Initialize the control plane

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

Verify:
```bash
kubectl get nodes
# control-plane shows NotReady — expected until Calico is installed
```

---

### 8. Join worker nodes

On **each worker node**, using the token and hash from the kubeadm init output:

```bash
cd Challenge-Lab
CONTROL_PLANE_IP=<private-ip> TOKEN=<token> CA_HASH=<hash> bash cluster/02-join-workers.sh
```

> `CA_HASH` accepts the full `sha256:<hex>` from kubeadm output or just the hex — the script strips the prefix if present.

---

### 9. Install Calico CNI

From your **local machine**:

```bash
bash cluster/03-install-calico.sh
```

Verify all nodes are Ready:
```bash
kubectl get nodes
```

---

### 10. Apply RBAC and create dev-user

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
- `dev-user-kubeconfig.yaml`

Copy the kubeconfig to your local machine:
```bash
scp -i ~/.ssh/challenge-lab.pem ubuntu@<ELASTIC-IP>:~/Challenge-Lab/dev-user-kubeconfig.yaml rbac/dev-user-kubeconfig.yaml
```

Verify access boundaries:
```bash
kubectl --kubeconfig=rbac/dev-user-kubeconfig.yaml auth can-i create deployments -n nginx-app  # yes
kubectl --kubeconfig=rbac/dev-user-kubeconfig.yaml auth can-i create deployments -n default    # no
kubectl --kubeconfig=rbac/dev-user-kubeconfig.yaml auth can-i get secrets -n nginx-app         # no
kubectl --kubeconfig=rbac/dev-user-kubeconfig.yaml auth can-i get nodes                        # no
```

---

### 11. Install ingress controller

From your **local machine**:

```bash
bash cert-manager/install-ingress-controller.sh
```

---

### 12. Provision NLB

Get the ingress controller NodePorts:

```bash
HTTP_NP=$(kubectl get svc ingress-nginx-controller -n ingress-nginx \
  -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}')
HTTPS_NP=$(kubectl get svc ingress-nginx-controller -n ingress-nginx \
  -o jsonpath='{.spec.ports[?(@.port==443)].nodePort}')
echo "HTTP: $HTTP_NP  HTTPS: $HTTPS_NP"
```

Provision the NLB:

```bash
HTTP_NP=<http-nodeport> HTTPS_NP=<https-nodeport> bash infrastructure/provision-nlb.sh
```

The script looks up VPC, subnet, and worker IDs automatically, creates target groups, registers both workers, creates the NLB, and attaches listeners on ports 80 and 443. It prints the NLB DNS name at the end.

> **Why NLB?** On bare kubeadm there is no cloud LB controller — a LoadBalancer service stays `<pending>` indefinitely. The NLB routes external traffic to NodePorts on both workers and provides a stable DNS name for Let's Encrypt HTTP-01 challenges. Alternatives (externalIPs, raw NodePort) are single-node and not suitable for a reproducible demo.

---

### 13. Configure DNS

Add two CNAME records at your registrar pointing to the NLB DNS name:

- `nginx.<domain>` → `<NLB DNS name>`
- `argo.<domain>` → `<NLB DNS name>`

TTL: 300 seconds. Use CNAME (not A record) — NLB IPs change.

Verify propagation:
```bash
dig nginx.swampthing.online +short
dig argo.swampthing.online +short
```

---

### 14. Install cert-manager

From your **local machine**:

```bash
bash cert-manager/install-cert-manager.sh
```

Installs cert-manager v1.14.0 + Let's Encrypt ClusterIssuer. Reads `ACME_EMAIL` from `config.env`.

---

### 15. Deploy Nginx as dev-user

From your **local machine**:

```bash
bash nginx/deploy-as-dev-user.sh rbac/dev-user-kubeconfig.yaml
```

Watch TLS certificate issuance:
```bash
kubectl get certificate -n nginx-app --watch
# READY transitions False → True within ~60s once DNS has propagated
```

Test:
```bash
curl -I https://nginx.swampthing.online
```

---

### 16. Install ArgoCD (GitOps)

From your **local machine**:

```bash
bash argocd/install-argocd.sh
```

> **Expected warning:** During install you may see `The CustomResourceDefinition "applicationsets.argoproj.io" is invalid: metadata.annotations: Too long: must have at most 262144 bytes`. This is a known ArgoCD CRD size issue and is non-fatal — the script handles it with `|| true` and all components install correctly.

Get the initial admin password:
```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d && echo
```

ArgoCD UI: `https://argo.swampthing.online` (username: `admin`)

To demo the GitOps loop: edit `nginx/configmap-html.yaml`, commit and push — ArgoCD detects drift and syncs within ~3 minutes.

---

## Teardown

```bash
bash infrastructure/teardown.sh
```

Removes all EC2 instances, Elastic IP, NLB, target groups, security group, and key pair.

---

## Repository Structure

```
.
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
├── infrastructure/
│   ├── provision-nlb.sh            ← NLB provisioning script
│   └── teardown.sh                 ← Full teardown
├── config.env.example
├── DESIGN.md
├── QUICKSTART.md
└── README.md
```

---

## Key Design Decisions

See [`DESIGN.md`](DESIGN.md) for full rationale. Summary:

- **kubeadm** — real production bootstrap, not a wrapper. Exposes actual K8s primitives.
- **Calico** — adds NetworkPolicy enforcement; Flannel does not support it.
- **CSR-based user auth** — native K8s mechanism; no external IdP dependency.
- **cert-manager + Let's Encrypt** — automated lifecycle management, publicly trusted cert, no browser warnings.
- **ArgoCD** — visual GitOps loop that makes the "git as source of truth" story tangible in a 15-minute demo.
- **AWS NLB** — stable DNS, routes across both workers, required for Let's Encrypt HTTP-01 on bare kubeadm.

---

## Security Notes

- Port 22 and 6443 are restricted to WAN IP only for external access. Workers reach the API server via the node security group rule.
- `dev-user` has a `Role` (not `ClusterRole`) scoped to `nginx-app` only. Cannot read secrets, list nodes, or access other namespaces.
- Calico NetworkPolicy denies all ingress to nginx pods except from the ingress controller namespace.
- Certificates issued with 24-hour TTL (`expirationSeconds: 86400`). In production, rotation would be automated.
- `dev-user-kubeconfig.yaml` and `*.key`/`*.crt` files are excluded from git via `.gitignore`.

# Quickstart — Challenge Lab

Condensed deployment reference. Full details in [README.md](README.md) and [infrastructure/aws-setup.md](infrastructure/aws-setup.md).

---

## Phase 0 — Local Prerequisites

- AWS CLI configured (`aws configure`)
- `kubectl` and `openssl` installed
- SSH key pair created:

```bash
aws ec2 create-key-pair \
  --key-name challenge-lab \
  --query 'KeyMaterial' \
  --output text > ~/.ssh/challenge-lab.pem && chmod 400 ~/.ssh/challenge-lab.pem
```

- Clone the repo locally:

```bash
git clone https://github.com/madavigo/Challenge-Lab.git
cd Challenge-Lab
```

---

## Phase 1 — AWS Infrastructure

Full commands in [infrastructure/aws-setup.md](infrastructure/aws-setup.md).

```bash
# Get AMI, VPC, subnet
aws ec2 describe-images --owners 099720109477 \
  --filters "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" \
            "Name=state,Values=available" \
  --query 'sort_by(Images, &CreationDate)[-1].{AMI:ImageId,Name:Name}' --output table

aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" \
  --query 'Vpcs[0].{VpcId:VpcId,CIDR:CidrBlock}' --output table

aws ec2 describe-subnets --filters "Name=defaultForAz,Values=true" \
  --query 'Subnets[0].{SubnetId:SubnetId,AZ:AvailabilityZone}' --output table
```

```bash
# Create security group
SG_ID=$(aws ec2 create-security-group \
  --group-name k8s-challenge-lab \
  --description "Kubernetes challenge lab - control-plane and workers" \
  --vpc-id <VPC_ID> \
  --query 'GroupId' --output text)
```

Apply all inbound rules (SSH, K8s API, etcd, kubelet, Calico BGP/VXLAN/IPIP, NodePorts, HTTP, HTTPS) — see [infrastructure/aws-setup.md](infrastructure/aws-setup.md#setting-security-group-rules).

```bash
# Launch 3x t3.small instances
AMI=<ami-id>
SG_ID=<sg-id>
SUBNET=<subnet-id>

CP_ID=$(aws ec2 run-instances --image-id $AMI --instance-type t3.small --key-name challenge-lab \
  --security-group-ids $SG_ID --subnet-id $SUBNET --associate-public-ip-address \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=k8s-control-plane},{Key=Project,Value=challenge-lab}]' \
  --query 'Instances[0].InstanceId' --output text)

W1_ID=$(aws ec2 run-instances --image-id $AMI --instance-type t3.small --key-name challenge-lab \
  --security-group-ids $SG_ID --subnet-id $SUBNET --associate-public-ip-address \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=k8s-worker-01},{Key=Project,Value=challenge-lab}]' \
  --query 'Instances[0].InstanceId' --output text)

W2_ID=$(aws ec2 run-instances --image-id $AMI --instance-type t3.small --key-name challenge-lab \
  --security-group-ids $SG_ID --subnet-id $SUBNET --associate-public-ip-address \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=k8s-worker-02},{Key=Project,Value=challenge-lab}]' \
  --query 'Instances[0].InstanceId' --output text)

# Disable source/dest check — required for Calico pod networking on AWS
for ID in $CP_ID $W1_ID $W2_ID; do
  aws ec2 modify-instance-attribute --instance-id $ID --no-source-dest-check
done
```

```bash
# Allocate and associate Elastic IP to control-plane
ALLOC=$(aws ec2 allocate-address --domain vpc --query 'AllocationId' --output text)
aws ec2 associate-address --instance-id $CP_ID --allocation-id $ALLOC
```

---

## Phase 2 — Bootstrap All 3 Nodes (parallel)

SSH into each node and run:

```bash
git clone https://github.com/madavigo/Challenge-Lab.git
cd Challenge-Lab
bash cluster/00-prereqs.sh
```

Installs: containerd, kubeadm/kubelet/kubectl (v1.29), kernel modules, sysctl, disables swap.

---

## Phase 3 — Initialize Control Plane (control-plane only)

```bash
bash cluster/01-init-control-plane.sh
```

- Runs `kubeadm init`, writes internal and external kubeconfigs
- **Save the `kubeadm join` output**

```bash
# Copy external kubeconfig to local machine
scp -i ~/.ssh/challenge-lab.pem ubuntu@<ELASTIC-IP>:~/admin-external.conf ~/.kube/config
```

---

## Phase 4 — Join Workers (each worker node)

```bash
CONTROL_PLANE_IP=<private-ip> TOKEN=<token> CA_HASH=<hash> bash cluster/02-join-workers.sh
```

> `CA_HASH` accepts the full `sha256:<hex>` from kubeadm output or the hex value alone — the script handles both.

---

## Phase 5 — Install Calico CNI (from local machine)

```bash
bash cluster/03-install-calico.sh
```

Applies Calico v3.27.0. Waits for all nodes to show `Ready`.

---

## Phase 6 — RBAC + Dev User (on control-plane node)

```bash
bash rbac/01-apply-rbac.sh    # nginx-app namespace, Role, RoleBinding, NetworkPolicy
bash rbac/00-create-user.sh   # dev-user cert/key, CSR, kubeconfig
```

```bash
# Copy kubeconfig to local machine
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

## Phase 7 — Ingress Controller + NLB + DNS (from local machine)

```bash
bash cert-manager/install-ingress-controller.sh
```

Get NodePorts:
```bash
HTTP_NP=$(kubectl get svc ingress-nginx-controller -n ingress-nginx \
  -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}')
HTTPS_NP=$(kubectl get svc ingress-nginx-controller -n ingress-nginx \
  -o jsonpath='{.spec.ports[?(@.port==443)].nodePort}')
echo "HTTP: $HTTP_NP  HTTPS: $HTTPS_NP"
```

Provision NLB:
```bash
HTTP_NP=<http-nodeport> HTTPS_NP=<https-nodeport> bash infrastructure/provision-nlb.sh
```

Add DNS CNAMEs at your registrar pointing to the NLB DNS name:
- `nginx.<domain>` → NLB DNS
- `argo.<domain>` → NLB DNS

Verify propagation:
```bash
dig nginx.<domain> +short
dig argo.<domain> +short
```

---

## Phase 8 — Cert-Manager (from local machine)

```bash
bash cert-manager/install-cert-manager.sh
```

Installs cert-manager v1.14.0 + Let's Encrypt ClusterIssuer. Reads `ACME_EMAIL` from `config.env` (falls back to `config.env.example`).

---

## Phase 9 — Deploy Nginx as Dev-User (from local machine)

```bash
bash nginx/deploy-as-dev-user.sh rbac/dev-user-kubeconfig.yaml
```

Watch TLS certificate issuance:
```bash
kubectl get certificate -n nginx-app --watch
# READY: False → True within ~60s
```

---

## Phase 10 — Install ArgoCD (from local machine)

```bash
bash argocd/install-argocd.sh
```

> **Expected warning:** `metadata.annotations: Too long: must have at most 262144 bytes` — non-fatal CRD size issue, safe to ignore.

ArgoCD UI: `https://argo.<domain>` (username: `admin`)

Get initial password:
```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d && echo
```

To demo the GitOps loop: edit `nginx/configmap-html.yaml`, commit and push — ArgoCD detects drift and syncs within ~3 minutes.

---

## Dependency Order

| Step | Depends On |
|------|-----------|
| Node bootstrap | EC2 instances exist |
| Control-plane init | All nodes bootstrapped |
| Worker join | Control-plane initialized |
| Calico | All workers joined |
| RBAC | Calico ready (NetworkPolicy needs CNI) |
| Ingress controller | RBAC done |
| NLB + DNS | Ingress controller deployed |
| Cert-manager | Ingress controller exists (HTTP-01 challenge) |
| Nginx deploy | DNS propagated + cert-manager ready |
| ArgoCD | Ingress + TLS working |

**Total time from scratch: ~45 minutes**

---

## Teardown

```bash
bash infrastructure/teardown.sh
```

Removes all EC2 instances, Elastic IP, NLB, target groups, security group, and key pair.

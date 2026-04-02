# AWS Infrastructure Setup

## EC2 Instances

Launch 3 instances from the AWS Console or CLI.

| Node | Name Tag | Type | AMI |
|------|----------|------|-----|
| Control Plane | `k8s-control-plane` | t3.medium | Ubuntu 22.04 LTS |
| Worker 1 | `k8s-worker-01` | t3.small | Ubuntu 22.04 LTS |
| Worker 2 | `k8s-worker-02` | t3.small | Ubuntu 22.04 LTS |

**AMI:** Search "ubuntu-jammy-22.04-amd64-server" in Community AMIs (us-east-1: `ami-0fc5d935ebf8bc3bc`).

All three instances must be in the **same VPC, same subnet, same Security Group**.

## Elastic IP

Assign an Elastic IP to the control-plane. This keeps the kubeconfig valid across reboots and ensures the API server certificate SANs remain valid.

```bash
# Allocate
aws ec2 allocate-address --domain vpc

# Associate (replace with your instance ID and allocation ID)
aws ec2 associate-address \
  --instance-id i-XXXXXXXXXXXXXXXXX \
  --allocation-id eipalloc-XXXXXXXXXXXXXXXXX
```

## Security Group Rules

Create one Security Group shared by all three nodes.

### Inbound Rules

| Port/Range | Protocol | Source | Purpose |
|---|---|---|---|
| 22 | TCP | Your IP only | SSH |
| 6443 | TCP | Your IP only | Kubernetes API server |
| 2379–2380 | TCP | Node SG (self) | etcd peer communication |
| 10250–10259 | TCP | Node SG (self) | kubelet, scheduler, controller manager |
| 10256 | TCP | Node SG (self) | kube-proxy health check |
| 179 | TCP | Node SG (self) | Calico BGP |
| 4789 | UDP | Node SG (self) | Calico VXLAN |
| 30000–32767 | TCP | 0.0.0.0/0 | NodePort range |
| 80 | TCP | 0.0.0.0/0 | HTTP (Let's Encrypt HTTP01 challenge) |
| 443 | TCP | 0.0.0.0/0 | HTTPS |

> **Security note:** Ports 22 and 6443 are restricted to your IP only. The API server must never be open to 0.0.0.0/0.

"Self" source means the Security Group ID itself — allows all instances in the group to communicate freely on those ports.

### Outbound Rules

Allow all outbound (default AWS behavior). Nodes need internet access to pull packages and container images.

## DNS

Once the ingress controller is installed and you have the LoadBalancer external IP:

1. Log into your domain registrar (swampthing.online)
2. Add an A record: `nginx` → `<LoadBalancer external IP>`
3. TTL: 300 seconds (5 minutes)

Allow 5–10 minutes for propagation before running the cert-manager step.

Verify propagation:
```bash
dig nginx.swampthing.online +short
# Should return the LoadBalancer IP
```

## Key Pair

Create a key pair in the AWS Console and download the `.pem` file. Store it securely — you need it to SSH into all three nodes.

```bash
chmod 400 ~/.ssh/k8s-challenge.pem

# SSH to control-plane
ssh -i ~/.ssh/k8s-challenge.pem ubuntu@<ELASTIC-IP>

# SSH to workers
ssh -i ~/.ssh/k8s-challenge.pem ubuntu@<WORKER-PUBLIC-IP>
```

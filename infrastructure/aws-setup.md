# AWS Infrastructure Setup

## Setting up EC2 Instances

We will launch 3 instances in AWS via the cli tool after gathering some information and setting up security group rules.
(AWS will not allow t3.medium on the free tier, billing must be enabled even to use free credits)

| Node | Name Tag | Type | AMI |
|------|----------|------|-----|
| Control Plane | `k8s-control-plane` | t3.small | Ubuntu 22.04 LTS |
| Worker 1 | `k8s-worker-01` | t3.small | Ubuntu 22.04 LTS |
| Worker 2 | `k8s-worker-02` | t3.small | Ubuntu 22.04 LTS |

**AMI:** Search "ubuntu-jammy-22.04-amd64-server" in Community AMIs (us-east-1: `ami-00de3875b03809ec5`).

All three instances must be in the **same VPC, same subnet, same Security Group**.

```bash
# First we locate the image to be used
aws ec2 describe-images \
  --owners 099720109477 \
  --filters "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" \
            "Name=state,Values=available" \
  --query 'sort_by(Images, &CreationDate)[-1].{AMI:ImageId,Name:Name,Date:CreationDate}' \
  --output table

# Describe VPC, Subnet and Key Pairs
aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" \
  --query 'Vpcs[0].{VpcId:VpcId,CIDR:CidrBlock}' --output table && \
aws ec2 describe-subnets --filters "Name=defaultForAz,Values=true" \
  --query 'Subnets[0].{SubnetId:SubnetId,AZ:AvailabilityZone}' --output table && \
aws ec2 describe-key-pairs --query 'KeyPairs[*].KeyName' --output table
```

## Key Pair

Create a key pair in the AWS Console and download the `.pem` file. Store it securely — you need it to SSH into all three nodes.

# Create key pair if one doesn't already exist
```bash
aws ec2 create-key-pair \
  --key-name challenge-lab \
  --query 'KeyMaterial' \
  --output text > ~/.ssh/challenge-lab.pem && \
chmod 400 ~/.ssh/challenge-lab.pem && \
echo "Key saved and permissions set:" && \
ls -la ~/.ssh/challenge-lab.pem
```

```bash
# SSH to control-plane
ssh -i ~/.ssh/challenge-lab.pem ubuntu@<ELASTIC-IP>

# SSH to workers
ssh -i ~/.ssh/challenge-lab.pem ubuntu@<WORKER-PUBLIC-IP>
```

### About Inbound Rules

| Port/Range | Protocol | Source | Purpose |
|---|---|---|---|
| 22 | TCP | Your IP only | SSH |
| 6443 | TCP | Your IP only | Kubernetes API server (external kubectl) |
| 6443 | TCP | Node SG (self) | Kubernetes API server (worker → control-plane) |
| 2379–2380 | TCP | Node SG (self) | etcd peer communication |
| 10250–10259 | TCP | Node SG (self) | kubelet, scheduler, controller manager |
| 10256 | TCP | Node SG (self) | kube-proxy health check |
| 179 | TCP | Node SG (self) | Calico BGP |
| 4789 | UDP | Node SG (self) | Calico VXLAN |
| 4 (IPIP) | IP | Node SG (self) | Calico IPIP encapsulation — required for pod internet access on AWS |
| 30000–32767 | TCP | 0.0.0.0/0 | NodePort range |
| 80 | TCP | 0.0.0.0/0 | HTTP (Let's Encrypt HTTP01 challenge) |
| 443 | TCP | 0.0.0.0/0 | HTTPS |

> **Security note:** Port 22 is restricted to your IP only. Port 6443 allows your IP (for kubectl) and the node security group (so workers can join and communicate with the API server). The API server must never be open to 0.0.0.0/0.

"Self" source means the Security Group ID itself — allows all instances in the group to communicate freely on those ports.

### About Outbound Rules

Allow all outbound (default AWS behavior). Nodes need internet access to pull packages and container images.

## Setting Security Group Rules

Create one Security Group shared by all three nodes.

```bash
# Create a SG using the VPC ID you gathered in the earlier steps
SG_ID=$(aws ec2 create-security-group \
  --group-name k8s-challenge-lab \
  --description "Kubernetes challenge lab - control-plane and workers" \
  --vpc-id vpc-################ \
  --query 'GroupId' --output text)
echo "Security Group ID: $SG_ID"

# Then apply all SG Ingress rules
SG_ID=sg-#############
MY_IP=<Your WAN IP) # 

# SSH - your IP only
aws ec2 authorize-security-group-ingress --group-id $SG_ID \
  --protocol tcp --port 22 --cidr ${MY_IP}/32

# K8s API server - your IP only (external kubectl)
aws ec2 authorize-security-group-ingress --group-id $SG_ID \
  --protocol tcp --port 6443 --cidr ${MY_IP}/32

# K8s API server - node-to-node (workers must reach control-plane to join and communicate)
aws ec2 authorize-security-group-ingress --group-id $SG_ID \
  --protocol tcp --port 6443 --source-group $SG_ID

# etcd peer communication - self (node-to-node)
aws ec2 authorize-security-group-ingress --group-id $SG_ID \
  --protocol tcp --port 2379-2380 --source-group $SG_ID

# kubelet, scheduler, controller manager - self
aws ec2 authorize-security-group-ingress --group-id $SG_ID \
  --protocol tcp --port 10250-10259 --source-group $SG_ID

# kube-proxy health check - self
aws ec2 authorize-security-group-ingress --group-id $SG_ID \
  --protocol tcp --port 10256 --source-group $SG_ID

# Calico BGP - self
aws ec2 authorize-security-group-ingress --group-id $SG_ID \
  --protocol tcp --port 179 --source-group $SG_ID

# Calico VXLAN - self
aws ec2 authorize-security-group-ingress --group-id $SG_ID \
  --protocol udp --port 4789 --source-group $SG_ID

# Calico IPIP - self (IP protocol 4, required for pod internet access on AWS)
aws ec2 authorize-security-group-ingress --group-id $SG_ID \
  --protocol 4 --port -1 --source-group $SG_ID

# NodePort range - public
aws ec2 authorize-security-group-ingress --group-id $SG_ID \
  --protocol tcp --port 30000-32767 --cidr 0.0.0.0/0

# HTTP - public (Let's Encrypt HTTP01 challenge)
aws ec2 authorize-security-group-ingress --group-id $SG_ID \
  --protocol tcp --port 80 --cidr 0.0.0.0/0

# HTTPS - public
aws ec2 authorize-security-group-ingress --group-id $SG_ID \
  --protocol tcp --port 443 --cidr 0.0.0.0/0

echo "All security group rules applied."
```

### Spin up ec2 instances now that you have the SG in place
Replace AMI, SG_ID and SUBNET with your own values.
```bash
AMI=ami-00de3875b03809ec5
SG_ID=sg-################
SUBNET=subnet-################

# Control plane - t3.small
CP_ID=$(aws ec2 run-instances \
  --image-id $AMI \
  --instance-type t3.small \
  --key-name challenge-lab \
  --security-group-ids $SG_ID \
  --subnet-id $SUBNET \
  --associate-public-ip-address \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=k8s-control-plane},{Key=Project,Value=challenge-lab}]' \
  --query 'Instances[0].InstanceId' --output text)
echo "Control-plane: $CP_ID"

# Worker 1 - t3.small
W1_ID=$(aws ec2 run-instances \
  --image-id $AMI \
  --instance-type t3.small \
  --key-name challenge-lab \
  --security-group-ids $SG_ID \
  --subnet-id $SUBNET \
  --associate-public-ip-address \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=k8s-worker-01},{Key=Project,Value=challenge-lab}]' \
  --query 'Instances[0].InstanceId' --output text)
echo "Worker-01: $W1_ID"

# Worker 2 - t3.small
W2_ID=$(aws ec2 run-instances \
  --image-id $AMI \
  --instance-type t3.small \
  --key-name challenge-lab \
  --security-group-ids $SG_ID \
  --subnet-id $SUBNET \
  --associate-public-ip-address \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=k8s-worker-02},{Key=Project,Value=challenge-lab}]' \
  --query 'Instances[0].InstanceId' --output text)
echo "Worker-02: $W2_ID"

# Disable source/dest check on all nodes — required for Calico pod networking on AWS.
# Without this, AWS drops pod traffic at the hypervisor because the source IP
# (192.168.x.x) doesn't match the instance's own IP.
for ID in $CP_ID $W1_ID $W2_ID; do
  aws ec2 modify-instance-attribute --instance-id $ID --no-source-dest-check
done
echo "Source/dest check disabled on all instances."
```

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

## DNS

ONLY AFTER the NLB is provisioned (see README step 7):

1. Log into your domain registrar (swampthing.online)
2. Add two CNAME records pointing to the NLB DNS name:
   - `nginx` → `<NLB DNS name>`
   - `argo`  → `<NLB DNS name>`
3. TTL: 300 seconds (5 minutes)

> Use CNAME (not A record) — the NLB DNS name resolves to IPs that can change.

Allow 5–10 minutes for propagation before running the cert-manager step.

Verify propagation:
```bash
dig nginx.swampthing.online +short
dig argo.swampthing.online +short
# Both should return the NLB DNS name and its IP
```


# Design Document — Challenge-Lab

## Overview

This document covers the key design decisions, tradeoffs, and security considerations for a Kubernetes Installation and Application Deployment challenge.

**Goal:** Deploy a kubeadm Kubernetes cluster with certificate-based RBAC, a TLS-secured Nginx application deployed by a restricted user, and a 15-minute demonstrable result.

---

## Architecture Summary

| Component | Choice | Alternative Considered |
|---|---|---|
| Infrastructure | AWS EC2 | Local VMs, GCP |
| OS | Ubuntu 22.04 LTS | Debian, Amazon Linux |
| Cluster bootstrap | kubeadm | EKS, k3s, MiniKube (not compliant) |
| CNI | Calico | Flannel, Weave |
| User authentication | K8s CSR / client certificates | OIDC, service accounts |
| TLS | cert-manager + Let's Encrypt | Self-signed, manual certs |
| GitOps | ArgoCD | Flux, plain Helm |
| Ingress | nginx ingress controller | Traefik, HAProxy |

---

## Decision Rationale

### AWS EC2

The companies client base is likely to be predominantly cloud-native enterprises running on AWS. Deploying on EC2 means the infrastructure pattern (VPC, security groups, IAM) is immediately familiar to those customers. The AWS free trial covers this workload for the 5-day challenge window at roughly $10–12 total.

### Ubuntu 22.04 LTS

LTS releases are what production systems run. LTS guarantees 5 years of security patches, which is a meaningful statement in a security-focused context. The Ubuntu/Debian packaging ecosystem also has first-class support from the Kubernetes project for kubeadm installation.

### kubeadm (not MiniKube, Kind, or EKS)

The challenge explicitly requires kubeadm. More importantly, kubeadm is how real clusters are bootstrapped when organizations manage their own Kubernetes. Working through it demonstrates genuine understanding of:
- What the API server certificate is and where it lives
- How etcd is configured and secured
- How the kubelet joins a node and what the bootstrap token flow does
- Where the cluster CA lives and why it matters for user authentication

### Calico CNI (over Flannel)

Flannel is the simplest CNI option but has a critical limitation: it does not support Kubernetes `NetworkPolicy`. Calico provides equivalent pod networking and adds native NetworkPolicy enforcement.

This matters for two reasons:

1. **Defense in depth:** Zero-trust access control operates at the identity layer via RBAC. Calico extends that to the network layer. The NetworkPolicy in `rbac/networkpolicy.yaml` on this repo,  ensures that even a compromised pod in another namespace cannot reach nginx pods directly — the only allowed ingress path is through the ingress controller.

2. **Customer relevance:** Mature production clusters run Calico or Cilium. Flannel is a learning tool. Calico reflects what we actually encounter in enterprise environments.

### Certificate-Based User Authentication via CSR

Kubernetes has no native user database. Users are authenticated by presenting a client certificate signed by the cluster CA, where:
- The `CN` (Common Name) field becomes the username
- The `O` (Organization) field becomes the group

The Kubernetes CertificateSigningRequest API provides a native workflow:
1. User generates a private key and CSR locally
2. CSR is submitted to the K8s API as a `CertificateSigningRequest` object
3. An admin explicitly approves it (the human gate)
4. The signed certificate is retrieved and embedded in a kubeconfig

**Why this approach for the demo:** It is the native mechanism, requires no external dependencies, and directly supports the challenge requirement. The workflow also makes the security model concrete and explainable.

### cert-manager + Let's Encrypt (over self-signed certs)

cert-manager is a CNCF graduated project and the de facto standard for certificate lifecycle management in Kubernetes. It automates issuance, renewal, and rotation — one of the most common operational pain points in running TLS at scale.

Let's Encrypt with the HTTP01 challenge provides a publicly trusted certificate at no cost. The practical benefit for the demo: no browser warnings to explain away, no "add this to your trust store" friction. A green padlock in the browser during a 15-minute live demo communicates production-readiness immediately.

### ArgoCD (over Flux or plain Helm)

ArgoCD has a significant advantage for a live demo: a visual UI. When the ArgoCD dashboard shows a green "Synced / Healthy" application, and you make a commit to GitHub and watch it automatically reconcile — that moment communicates GitOps more clearly than any explanation.

ArgoCD also surfaces drift detection visually. If a cluster resource diverges from git (manual change, rollback, etc.), ArgoCD marks it `OutOfSync` and can auto-heal. This reinforces the security story: git is the authoritative source of truth, and any deviation is immediately visible.

**Why not Flux:** Equally capable but operates headlessly — harder to demonstrate in 15 minutes.
**Why not plain Helm:** Templating and packaging tool, not continuous reconciliation. Not full GitOps.

---

## Security Model

### Principle of Least Privilege

`dev-user` is granted only what is required to deploy and monitor the nginx application:

| Resource | Verbs granted | Verbs denied |
|---|---|---|
| Deployments | get, list, watch, create, update, patch | delete |
| Services, ConfigMaps | get, list, watch, create, update, patch | delete |
| Ingresses | get, list, watch, create, update, patch | delete |
| Pods, Pod logs | get, list, watch | exec, delete |
| Secrets | *none* | all |
| Nodes | *none* | all |
| Namespaces | *none* | all |
| ClusterRoles | *none* | all |

The binding uses a `RoleBinding` (not `ClusterRoleBinding`), scoping access strictly to the `nginx-app` namespace.

### Network Layer (Calico NetworkPolicy)

The NetworkPolicy found in `rbac/networkpolicy.yaml` implements a deny-by-default posture for the `nginx-app` namespace:
- All ingress to nginx pods is denied by default
- The only explicitly allowed ingress is from pods in the `ingress-nginx` namespace on port 80
- Egress is unrestricted (nginx needs to serve responses)

### Credential Hygiene

- `dev-user-kubeconfig.yaml` and `*.key`/`*.crt` files are excluded from git via `.gitignore`
- The kubeconfig embeds both the client certificate and private key — it is the credential
- Certificates are issued with a 24-hour TTL (`expirationSeconds: 86400`) to limit exposure window
- Port 6443 (API server) is restricted to a specific IP in the AWS Security Group

---

## Tradeoffs and Limitations

### What CSR-Based Auth Does Well

- No external identity provider dependency — works air-gapped
- Native to Kubernetes — no additional components required
- Integrates cleanly with RBAC
- Short-lived certs reduce the exposure window when combined with `expirationSeconds`

### Where It Breaks Down at Scale

| Problem | Impact |
|---|---|
| **No revocation** | If a kubeconfig is stolen, the cert is valid until expiry. Revoking requires rotating the cluster CA, which affects all certificates. |
| **No audit trail** | You can see that a cert was approved, but not what commands the user ran, what data they accessed, or when they connected. |
| **No MFA** | The kubeconfig file is the credential. No second factor is possible. |
| **No SSO** | Doesn't integrate with Okta, Google Workspace, or any enterprise IdP without additional tooling. |
| **Operational burden at scale** | With 10 developers, this is manageable. With 100, cert issuance, rotation, and revocation all require admin intervention. |
| **Kubeconfig as a secret** | If committed to git, shared over Slack, or left on a shared machine, the blast radius is the full scope of the user's RBAC permissions. |

### Production Solutions to These Problems

These limitations are well-understood in the industry. Production-grade Kubernetes access management solutions address them by replacing static, long-lived kubeconfigs with short-lived, identity-aware certificates tied to SSO, full session recording, and centralized audit logging. This lab demonstrates the native Kubernetes foundation that those solutions build on.

---

## Reproducing This Environment

1. Follow [`infrastructure/aws-setup.md`](infrastructure/aws-setup.md) to provision EC2 instances
2. Run scripts in order per [`README.md`](README.md)
3. All scripts are idempotent — re-running them is safe
4. Total provisioning time from scratch: approximately 45 minutes
5. Tested on Ubuntu 22.04 LTS with kubeadm 1.29

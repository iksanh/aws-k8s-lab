# Cluster Setup Runbook

## Why do all nodes need the same base install?
Every node (control plane and worker) needs:
- **containerd** — container runtime
- **kubelet** — agent that communicates with the API Server
- **kubeadm** — tool to bootstrap or join a cluster

`master.sh.tpl` and `worker.sh.tpl` both include this base install
before doing their role-specific work.

## Why does cluster init use local IP first, not NLB?
During init, the API Server is not yet listening on port 6443, so the
NLB health check fails and cannot forward traffic. This creates a
deadlock: NLB needs the API Server up, the API Server needs a valid
endpoint to init against.

The fix: init with the local IP, then rewrite the kubeconfig endpoint
to the NLB DNS once the API Server is running and NLB targets are
healthy.

---

## Prerequisites
- Terraform applied
- `set-env.sh` sourced successfully
- `generate-inventory.sh` executed successfully
- All nodes reachable via `ansible all -m ping`

> Note: IPs are dynamic and change on every `terraform apply`.
> Always reload environment variables via `set-env.sh` after apply.

---

## Execution Order

### Step 1 — Load environment variables
> Run on: **Local Machine**

```bash
source scripts/set-env.sh
```

Expected output:
```
Fetching Terraform outputs...
Environment variables loaded:
  BASTION_IP = <bastion-public-ip>
  NLB_DNS    = k8s-lab-cp-nlb-xxx.elb.us-east-1.amazonaws.com
  ALB_DNS    = k8s-lab-alb-xxx.us-east-1.elb.amazonaws.com
  CP1_IP     = 10.0.10.x
  WORKER1_IP = 10.0.20.x
  WORKER2_IP = 10.0.21.x
```

### Step 2 — Generate Ansible inventory
> Run on: **Local Machine**

```bash
bash scripts/generate-inventory.sh
cat ansible/inventory/hosts.ini
```

### Step 3 — Verify SSH connectivity to all nodes
> Run on: **Local Machine**

```bash
ansible all -i ansible/inventory/hosts.ini -m ping
```

Expected output:
```
bastion-host | SUCCESS
cp-1         | SUCCESS
worker-1     | SUCCESS
worker-2     | SUCCESS
```

### Step 4 — Generate join command and run on all workers
> Run on: **Local Machine**

Fetch a fresh join token from CP and execute it on all workers in one shot:

```bash
ansible workers -i ansible/inventory/hosts.ini -m shell \
  -a "sudo $(ansible cp-1 -i ansible/inventory/hosts.ini -m shell \
    -a 'kubeadm token create --print-join-command' \
    | grep -E '^kubeadm join')" \
  --timeout=120
```

### Step 5 — Verify the cluster is ready
> Run on: **Local Machine**

```bash
ansible cp-1 -i ansible/inventory/hosts.ini -m shell \
  -a "kubectl get nodes -o wide"
```

Expected: all nodes in `Ready` state. (If `NotReady`, wait ~30s for
Calico CNI to finish initializing on the new workers, then re-check.)

## Practice
### Install Helm
```bash
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-4 && chmod 700 get_helm.sh && ./get_helm.sh
```

## Install NGINX Ingress Controller

### 1.1 Install via Helm

```bash
# Add repo
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

# create ns ingress-nginx 
kubectl create ns ingress-nginx

# Install with NodePort fixed
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  --set controller.service.type=NodePort \
  --set controller.service.nodePorts.http=30080 \
  --set controller.service.nodePorts.https=32443
```

# ArgoCD Install Runbook

## Prerequisites

- Kubernetes cluster running
- `kubectl` configured and connected to cluster
- DNS record for `argocd.iksanhariji.my.id` pointing to cluster ingress IP

---

## Install ArgoCD on Cluster

```bash
# 1. Create namespace
kubectl create namespace argocd

# 2. Install ArgoCD — non-HA (suitable for lab/learning)
kubectl apply -n argocd --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.0.0/manifests/install.yaml

# 3. Wait until ArgoCD server ready
kubectl rollout status deployment argocd-server -n argocd

# 4. Apply Application CRD — auto-sync all manifests in apps/argo-cd/
kubectl apply -f https://raw.githubusercontent.com/iksanh/aws-k8s-manifests/main/apps/argo-cd/argocd-self.yaml

# 5. Restart ArgoCD server to pick up configmap insecure mode
kubectl rollout restart deployment argocd-server -n argocd
kubectl rollout status deployment argocd-server -n argocd
```

---

## Verify

```bash
# Check Application sync status
kubectl get application argocd-self -n argocd

# Check ingress created
kubectl get ingress -n argocd

# Check configmap insecure mode
kubectl get configmap argocd-cmd-params-cm -n argocd -o jsonpath='{.data}'
```

Expected output:

| Resource | Status |
|----------|--------|
| application/argocd-self | Synced / Healthy |
| ingress/argocd-server | ADDRESS filled |
| configmap insecure | `{"server.insecure":"true"}` |

---

## Access

After all steps complete, ArgoCD UI accessible at:

```
http://argocd.iksanhariji.my.id
```

Get initial admin password:

```bash
kubectl get secret argocd-initial-admin-secret -n argocd \
  -o jsonpath='{.data.password}' | base64 -d && echo
```

Login with username `admin` and the password above.

---

## Notes

- Step 4 uses [app-of-apps pattern](https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/) — Argo CD manages its own manifests via Git
- After bootstrap, **all changes via git commit + push** — no manual `kubectl apply` needed
- Manifest source: `https://github.com/iksanh/aws-k8s-manifests/tree/main/apps/argo-cd`




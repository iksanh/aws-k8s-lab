# ArgoCD Runbook

## What is ArgoCD?
ArgoCD is a declarative, GitOps-based continuous delivery tool for Kubernetes.
It continuously monitors Git repositories and automatically syncs the desired
state defined in Git to the actual state running in the cluster.

## What is GitOps?
GitOps is a methodology that uses Git as the single source of truth for
managing infrastructure and application deployments. Every change must go
through Git — via Pull Request, review, and approval — before being applied
to the cluster. The cluster state always reflects what is defined in Git.

## Why do we need ArgoCD?
When deploying manually from terminal via kubectl or Helm, we face these problems:

1. **No audit trail** — we do not know who deployed, when, or what changed
2. **Inconsistent** — different team members deploy in different ways
3. **No single source of truth** — cluster state can differ from Git, no one knows which config is correct
4. **Human error** — wrong command in production can break the system
5. **No visibility** — team lead cannot see what is running in the cluster

ArgoCD solves all of these by:
- Full audit trail via Git history
- No need to SSH into servers to deploy
- Auto rollback if something goes wrong
- Visual dashboard to monitor all applications
- Self-healing — if someone deletes a resource manually, ArgoCD recreates it from Git

---

## Key Concepts

### Application
A unit of deployment in ArgoCD. One Application maps to one Git repository
folder and one namespace in the cluster.

### Sync
The process of making the cluster state match the Git state.
- **Manual sync** — triggered by a human (recommended for production)
- **Auto sync** — ArgoCD automatically applies changes when Git is updated (recommended for dev/staging)

### Health
The status of the application in the cluster:
- **Healthy** — all resources are running correctly
- **Degraded** — something is wrong
- **Progressing** — deployment is in progress

### OutOfSync
When the cluster state does not match the Git state.
ArgoCD detects this and either waits for manual sync or auto-syncs depending on configuration.

---

## Installation

### Install ArgoCD on cluster
```bash
# Create argocd namespace
kubectl create namespace argocd

# Install ArgoCD — non-HA (suitable for lab/learning)
kubectl apply -n argocd --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.4.0-rc4/manifests/install.yaml

# Wait for all pods to be running
kubectl get pods -n argocd -w
```

Expected output:
```
NAME                                                READY   STATUS
argocd-application-controller-0                     1/1     Running
argocd-applicationset-controller-xxx                1/1     Running
argocd-dex-server-xxx                               1/1     Running
argocd-notifications-controller-xxx                 1/1     Running
argocd-redis-xxx                                    1/1     Running
argocd-repo-server-xxx                              1/1     Running
argocd-server-xxx                                   1/1     Running
```

### Change Service Type to NodePort

By default ArgoCD server uses ClusterIP — only accessible inside the cluster.
Patch it to NodePort to expose it externally:

```bash
kubectl patch svc argocd-server -n argocd \
  -p '{"spec": {"type": "NodePort"}}'

kubectl get svc argocd-server -n argocd
```

Output:
```
NAME            TYPE       CLUSTER-IP    PORT(S)
argocd-server   NodePort   10.99.22.42   80:30554/TCP,443:30965/TCP
```

### Disable HTTPS Redirect (Insecure Mode)

ArgoCD by default redirects HTTP to HTTPS. This causes ALB health checks to fail.
Run ArgoCD in insecure mode to disable the redirect:

```bash
kubectl patch deployment argocd-server -n argocd \
  --type='json' \
  -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--insecure"}]'
```

### Expose via ALB

Full step-by-step guide on how to expose ArgoCD via AWS ALB:

> Reference: https://medium.com/@iksanhariji/how-aws-alb-routes-traffic-to-kubernetes-applications-185588f08a06

### Get Initial Admin Password

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 --decode
```

Login at:
```
URL      : http://<ALB_DNS>:8080
Username : admin
Password : <output from command above>
```

### Install ArgoCD CLI
```bash
curl -sSL -o argocd https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
chmod +x argocd
sudo mv argocd /usr/local/bin/

argocd version
```

### Login via CLI
```bash
argocd login localhost:<nodeport> \
  --username admin \
  --password <password> \
  --insecure
```

---

## Practice

### Step 1 — Create namespace
```bash
kubectl create namespace dev
```

### Step 2 — Connect GitHub repo to ArgoCD
```bash
argocd repo add https://github.com/iksanh/aws-k8s-manifests.git \
  --username <username> \
  --password <github-personal-access-token>
```

### Step 3 — Create ArgoCD Application
```bash
argocd app create nginx-dev \
  --repo https://github.com/iksanh/aws-k8s-manifests.git \
  --path apps/nginx \
  --dest-server https://kubernetes.default.svc \
  --dest-namespace dev \
  --sync-policy automated \
  --auto-prune \
  --self-heal
```

Check application status:
```bash
argocd app get nginx-dev
kubectl get pods -n dev
```

Output:
```
NAME                    READY   STATUS    RESTARTS   AGE
nginx-cd5968d5b-clhx8   1/1     Running   0          17m
nginx-cd5968d5b-vzwbd   1/1     Running   0          17m
```

### Step 4 — Test GitOps auto-sync

Edit `apps/nginx/deployment.yaml` in the manifests repo — scale replicas from 1 to 2:

```yaml
spec:
  replicas: 2
```

Push to GitHub:
```bash
git add .
git commit -m "feat(nginx): scale replicas to 2"
git push
```

Watch pods on CP-1 — ArgoCD will auto-sync within seconds:
```bash
kubectl get pods -n dev -w
```

### Step 5 — Test self-healing (Pod level)

Delete pods manually — Deployment recreates them:
```bash
kubectl delete pod -n dev -l app=nginx
kubectl get pods -n dev -w
```

Output:
```
NAME                    READY   STATUS    RESTARTS   AGE
nginx-cd5968d5b-ksbt8   1/1     Running   0          22s
nginx-cd5968d5b-rt9gj   1/1     Running   0          22s
```

### Step 6 — Test self-healing (Deployment level)

Delete the entire Deployment — ArgoCD recreates it from Git:
```bash
kubectl delete deployment nginx -n dev
kubectl get pods -n dev -w
```

Output:
```
NAME                    READY   STATUS    RESTARTS   AGE
nginx-cd5968d5b-clhx8   1/1     Running   0          20s
nginx-cd5968d5b-vzwbd   1/1     Running   0          20s
```

Result: ArgoCD detected cluster state != Git state and recreated the Deployment automatically.

---

## Key Takeaway
- ArgoCD is essential for managing applications at scale in Kubernetes
- GitOps ensures every change is tracked, reviewed, and auditable
- Use **auto-sync** for dev/staging, **manual sync** for production
- Self-healing prevents cluster drift from the desired Git state
- No more SSH into servers — all changes go through Git
- Reduces human error by eliminating manual kubectl deployments
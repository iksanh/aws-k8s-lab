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
NAME                                                READY   STATUS    RESTARTS
argocd-application-controller-0                     1/1     Running   0
argocd-applicationset-controller-xxx                1/1     Running   0
argocd-dex-server-xxx                               1/1     Running   0
argocd-notifications-controller-xxx                 1/1     Running   0
argocd-redis-xxx                                    1/1     Running   0
argocd-repo-server-xxx                              1/1     Running   0
argocd-server-xxx                                   1/1     Running   0
```

## Change Service Type to NodePort

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

## Disable HTTPS Redirect (Insecure Mode)

ArgoCD by default redirects HTTP to HTTPS. This causes ALB health checks to fail.
Run ArgoCD in insecure mode to disable the redirect:

```bash
kubectl patch deployment argocd-server -n argocd \
  --type='json' \
  -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--insecure"}]'
```

## Expose via ALB

Full step-by-step guide on how to expose ArgoCD via AWS ALB:

> Reference: https://medium.com/@iksanhariji/how-aws-alb-routes-traffic-to-kubernetes-applications-185588f08a06

## Get Initial Admin Password

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

---

## Key Takeaway
- ArgoCD is essential for managing applications at scale in Kubernetes
- GitOps ensures every change is tracked, reviewed, and auditable
- Auto-sync for dev/staging, manual sync for production
- Self-healing prevents cluster drift from the desired Git state
- Reduces human error by eliminating manual kubectl deployments
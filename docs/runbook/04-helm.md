# Helm Runbook

## What is Helm?
Helm is a package manager for Kubernetes applications.
It allows you to define, install, and manage applications
using reusable templates called Charts.

## Why do we need Helm?
Imagine deploying the same application to multiple environments
(dev, staging, production) — each with different configurations
like replica count, resource limits, and service types.

Without Helm:
- Create separate YAML files for each environment
- Duplicate manifests with minor differences
- Hard to manage and easy to make mistakes

With Helm:
- One Chart (template) for all environments
- Different values files per environment
- One command to deploy, upgrade, or rollback

## Key Concepts

### Chart
A collection of Kubernetes manifest templates for an application.
Think of it as a blueprint that can be reused across environments.

### Values
Configuration values injected into the Chart templates.
Each environment can have its own values file to override defaults.

### Release
A running instance of a Chart in the cluster.
Every install or upgrade creates a new revision tracked by Helm.

### Repository
A collection of Charts available for download.
Similar to apt repositories in Ubuntu or pip in Python.

---

## Practice

### Install public chart

```bash
# Add bitnami repository
helm repo add bitnami https://charts.bitnami.com/bitnami

# Update repository
helm repo update

# Install nginx via Helm
helm install my-nginx bitnami/nginx \
  --namespace dev \
  --create-namespace

# Check release status
helm list -n dev

# Check all resources created by Helm
helm status my-nginx -n dev
```

### Upgrade & Rollback

#### Upgrade — scale to 2 replicas
```bash
helm upgrade my-nginx bitnami/nginx \
  --namespace dev \
  --set replicaCount=2
```

#### Check release history
```bash
helm history my-nginx -n dev
```

Output:
```
REVISION  STATUS      DESCRIPTION
1         superseded  Install complete
2         deployed    Upgrade complete
```

#### Verify pods scaled up
```bash
kubectl get pods -n dev
```

Output:
```
NAME                        READY   STATUS    RESTARTS   AGE
my-nginx-55bdb96978-h8jnq   1/1     Running   0          24s
my-nginx-55bdb96978-spzwt   1/1     Running   0          6m4s
```

#### Rollback to revision 1
```bash
helm rollback my-nginx 1 -n dev
```

#### Verify rollback
```bash
helm history my-nginx -n dev
```

Output:
```
REVISION  STATUS      DESCRIPTION
1         superseded  Install complete
2         superseded  Upgrade complete
3         deployed    Rollback to 1
```

```bash
kubectl get pods -n dev
```

Output:
```
NAME                        READY   STATUS    RESTARTS   AGE
my-nginx-55bdb96978-spzwt   1/1     Running   0          7m35s
```

Result: Pod count back to 1 replica after rollback.

### Custom values per environment

#### Create values-dev.yaml
```bash
cat > values-dev.yaml << 'EOF'
replicaCount: 1

service:
  type: NodePort
  nodePorts:
    http: 30080

resources:
  limits:
    cpu: 100m
    memory: 128Mi
  requests:
    cpu: 50m
    memory: 64Mi
EOF
```

#### Create values-prod.yaml
```bash
cat > values-prod.yaml << 'EOF'
replicaCount: 3

service:
  type: ClusterIP
  port: 80

resources:
  limits:
    cpu: 500m
    memory: 512Mi
  requests:
    cpu: 250m
    memory: 256Mi
EOF
```

#### Deploy with custom values
```bash
helm upgrade my-nginx bitnami/nginx \
  --namespace dev \
  --values values-dev.yaml
```

#### Verify service type changed to NodePort
```bash
kubectl get svc -n dev
```

Output:
```
NAME       TYPE       CLUSTER-IP      EXTERNAL-IP   PORT(S)
my-nginx   NodePort   10.103.37.192   <none>        80:30080/TCP
```

#### Preview rendered output per environment
```bash
# Dev environment
helm template my-app ./my-app --values values-dev.yaml | grep -E "replicas|type|cpu"

# Production environment
helm template my-app ./my-app --values values-prod.yaml | grep -E "replicas|type|cpu"
```

Output comparison:
```
Environment   replicas   type        cpu limit
──────────────────────────────────────────────
dev           1          NodePort    100m
prod          3          ClusterIP   500m
```

---

## Key Takeaway
- Helm is powerful especially for multi-environment deployments
- One Chart + multiple values files = consistent deployments across environments
- Every install and upgrade is tracked as a revision — easy to rollback
- Use `helm template` to preview rendered YAML before deploying
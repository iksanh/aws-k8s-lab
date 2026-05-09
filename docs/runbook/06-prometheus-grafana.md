# Prometheus + Grafana Runbook

A reusable guide to install Prometheus and Grafana on a self-managed
Kubernetes cluster with persistent storage on AWS.

## Table of Contents
1. Concepts
2. Prerequisites
3. Setup Persistent Storage
4. Install Prometheus + Grafana
5. Expose via ALB
6. Practice — Custom Dashboard
7. Test Persistence
8. Troubleshooting
9. Production Considerations
10. Key Takeaway

---

## 1. Concepts

### What is Prometheus?
Prometheus is a monitoring engine that scrapes metrics from various
sources (nodes, pods, services) and stores them in a time-series
database. Metrics can be queried using PromQL.

### What is Grafana?
Grafana is a visualization tool that pulls data from Prometheus to
build readable dashboards. It also supports alerting.

### Why do we need monitoring?
- Detect issues before users do
- Understand performance trends
- Plan capacity
- Respond to incidents quickly
- Provide visibility for the whole team

What we monitor:
- **Application** — pod status, CPU/memory per pod, request rate, error rate, latency
- **Hardware** — CPU, memory, disk, network per node
- **Cluster** — etcd health, API server response time, scheduler performance

### Key Concepts

**Time Series Database (TSDB)** — database optimized for time-stamped
data. Every metric has a timestamp.

**PromQL** — query language to retrieve and aggregate metrics.

**Exporters** — agents that expose metrics in Prometheus format:
- `node-exporter` → hardware metrics
- `kube-state-metrics` → Kubernetes resource state

### Storage Concepts

Why not store data in pods? Pods are ephemeral. By default, data goes
to `emptyDir` which is lost when:
- Pod restarts
- Pod is deleted
- Helm uninstalls
- Node crashes

Solution — use PVC + PV + StorageClass:

```
Pod
  └── /prometheus (mount path)
        └── PersistentVolume (PV)
              └── EBS Volume in AWS (persistent)

Pod restart → EBS volume stays → data survives
```

Components:
- **PVC** — "I need 20GB of storage"
- **StorageClass** — defines storage type (gp3, io2, etc.)
- **CSI Driver** — provisions actual cloud storage
- **PV** — represents the actual provisioned storage

---

## 2. Prerequisites

Before starting, ensure:
- Kubernetes cluster running (3 nodes minimum)
- `kubectl` configured and working
- `helm` installed
- Terraform infrastructure already includes:
  - ALB Security Group rules for ports 8081 and 8082
  - ALB Target Groups for Grafana and Prometheus
  - ALB Listeners on port 8081 (Grafana) and 8082 (Prometheus)
  - IAM Role with `AmazonEBSCSIDriverPolicy` attached to EC2 nodes

Verify cluster:
```bash
kubectl get nodes
```

Verify IAM Role attached to nodes:
```bash
aws ec2 describe-instances \
  --instance-ids <CP-INSTANCE-ID> \
  --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn'
```

If empty, IAM Role is missing — go back to Terraform.

---

## 3. Setup Persistent Storage

### 3.1 Install AWS EBS CSI Driver

```bash
helm repo add aws-ebs-csi-driver \
  https://kubernetes-sigs.github.io/aws-ebs-csi-driver
helm repo update

helm install aws-ebs-csi-driver \
  aws-ebs-csi-driver/aws-ebs-csi-driver \
  --namespace kube-system
```

### 3.2 Verify EBS CSI pods running

```bash
kubectl get pods -n kube-system | grep ebs-csi
```

All controller pods (5/5) and node pods (3/3) must be Running.

If controller shows Error → check IAM Role:
```bash
kubectl logs -n kube-system <pod-name> -c csi-provisioner | tail -20
```

Common error: `no EC2 IMDS role found` → IAM Role not attached.

### 3.3 Create Default StorageClass

```bash
cat << 'EOF' | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: ebs.csi.aws.com
volumeBindingMode: WaitForFirstConsumer
parameters:
  type: gp3
  encrypted: "true"
EOF
```

Verify:
```bash
kubectl get storageclass
```

Expected: `gp3 (default)` with provisioner `ebs.csi.aws.com`.

### 3.4 Test with Dummy PVC

```bash
# Create PVC
cat << 'EOF' | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-pvc
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
EOF

# Status will be Pending — this is normal with WaitForFirstConsumer
kubectl get pvc

# Create pod that consumes PVC
cat << 'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: test-pod
spec:
  containers:
  - name: test
    image: nginx
    volumeMounts:
    - mountPath: /data
      name: storage
  volumes:
  - name: storage
    persistentVolumeClaim:
      claimName: test-pvc
EOF

# PVC should now be Bound
kubectl get pvc
kubectl get pv
```

Verify EBS volume in AWS:
```bash
aws ec2 describe-volumes \
  --filters "Name=tag:kubernetes.io/created-for/pvc/name,Values=test-pvc" \
  --query 'Volumes[*].{ID:VolumeId,Size:Size,Type:VolumeType,State:State}'
```

Cleanup:
```bash
kubectl delete pod test-pod
kubectl delete pvc test-pvc
```

EBS volume will be auto-deleted because reclaim policy is `Delete`.

---

## 4. Install Prometheus + Grafana

### 4.1 Create Namespace

```bash
kubectl create namespace monitoring
```

### 4.2 Add Helm Repo

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
```

### 4.3 Install with Persistence Enabled

```bash
helm install kube-prometheus-stack \
  prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --set grafana.service.type=NodePort \
  --set grafana.service.nodePort=32753 \
  --set grafana.persistence.enabled=true \
  --set grafana.persistence.size=10Gi \
  --set grafana.persistence.storageClassName=gp3 \
  --set prometheus.service.type=NodePort \
  --set prometheus.service.nodePort=30090 \
  --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.storageClassName=gp3 \
  --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.accessModes[0]=ReadWriteOnce \
  --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage=20Gi
```

Important flags explanation:
- `service.nodePort=32753` → fixed NodePort, prevents random changes on reinstall
- `persistence.enabled=true` → enable persistent storage for Grafana
- `storageSpec.volumeClaimTemplate` → enable persistent storage for Prometheus

### 4.4 Wait for Pods Running

```bash
kubectl get pods -n monitoring -w
```

Expected (when ready):
```
alertmanager-kube-prometheus-stack-alertmanager-0    2/2     Running
kube-prometheus-stack-grafana-xxx                    3/3     Running
kube-prometheus-stack-kube-state-metrics-xxx         1/1     Running
kube-prometheus-stack-operator-xxx                   1/1     Running
kube-prometheus-stack-prometheus-node-exporter-xxx   1/1     Running (one per node)
prometheus-kube-prometheus-stack-prometheus-0        2/2     Running
```

### 4.5 Verify PVCs Created

```bash
kubectl get pvc -n monitoring
```

Expected:
```
NAME                                         STATUS   CAPACITY   STORAGECLASS
kube-prometheus-stack-grafana                Bound    10Gi       gp3
prometheus-kube-prometheus-stack-...-0       Bound    20Gi       gp3
```

If still Pending → check StorageClass and EBS CSI Driver.

### 4.6 Get Grafana Login Credentials

```bash
kubectl get secret kube-prometheus-stack-grafana \
  -n monitoring \
  -o jsonpath="{.data.admin-password}" | base64 --decode
```

Default username: `admin`
Default password: random-generated (or `prom-operator` on some versions)

---

## 5. Expose via ALB

ALB and Target Groups should already be in Terraform. Verify they exist:

```bash
# Check Target Groups
aws elbv2 describe-target-groups \
  --names k8s-lab-tg-grafana k8s-lab-tg-prometheus \
  --query 'TargetGroups[*].{Name:TargetGroupName,Port:Port}'

# Check Listeners
aws elbv2 describe-listeners \
  --load-balancer-arn $(aws elbv2 describe-load-balancers \
    --names k8s-lab-alb \
    --query 'LoadBalancers[0].LoadBalancerArn' \
    --output text) \
  --query 'Listeners[*].{Port:Port,DefaultAction:DefaultActions[0].TargetGroupArn}'
```

Port mapping:
```
ALB port 8081 → Grafana    NodePort 32753
ALB port 8082 → Prometheus NodePort 30090
```

Wait 1-2 minutes for Target Groups to become healthy:

```bash
aws elbv2 describe-target-health \
  --target-group-arn $(aws elbv2 describe-target-groups \
    --names k8s-lab-tg-grafana \
    --query 'TargetGroups[0].TargetGroupArn' \
    --output text) \
  --query 'TargetHealthDescriptions[*].{Target:Target.Id,State:TargetHealth.State}'
```

Access:
- Grafana → `http://<ALB_DNS>:8081`
- Prometheus → `http://<ALB_DNS>:8082`

---

## 6. Practice — Custom Dashboard for Nginx

Pre-requisite: Have an nginx deployment running in `dev` namespace
(can be deployed via ArgoCD).

### 6.1 Verify Metrics Available

Open Prometheus UI → http://<ALB_DNS>:8082

Run query:
```promql
container_cpu_usage_seconds_total{namespace="dev"}
```

If results appear → Prometheus is scraping nginx metrics correctly.

### 6.2 Create Dashboard in Grafana

1. Open Grafana → http://<ALB_DNS>:8081
2. Login with admin credentials
3. Sidebar → Dashboards → New → New dashboard
4. Click "+ Add visualization"
5. Select data source: `Prometheus`

### 6.3 Panel 1 — CPU Usage

Query (Code mode):
```promql
sum(rate(container_cpu_usage_seconds_total{namespace="dev",pod=~"nginx.*"}[5m])) by (pod)
```

Panel title: `Nginx CPU Usage`
Visualization: Time series

### 6.4 Panel 2 — Memory Usage

Query:
```promql
sum(container_memory_working_set_bytes{namespace="dev",pod=~"nginx.*",container!=""}) by (pod) / 1024 / 1024
```

Panel title: `Nginx Memory Usage (MB)`
Visualization: Time series

### 6.5 Save Dashboard

1. Click "Save dashboard" (top right)
2. Name: `Nginx Monitoring`
3. Save

### 6.6 Backup Dashboard to Git

Best practice — commit dashboard JSON to your GitOps repo:

1. Open dashboard → click "Share" icon (top right)
2. Tab "Export"
3. Toggle "Export for sharing externally" → ON
4. Save to file
5. Commit JSON to your manifests repo

This way, even if the cluster is destroyed, dashboards can be restored
via GitOps or imported back into Grafana.

---

## 7. Test Persistence

Verify that data survives pod restart:

```bash
# Note current dashboard exists in Grafana UI

# Delete Grafana pod
kubectl delete pod -n monitoring -l app.kubernetes.io/name=grafana

# Wait for new pod
kubectl get pods -n monitoring -w
```

Refresh Grafana UI — dashboard must still exist.

If dashboard persists → persistence works ✅
If dashboard disappears → persistence is not configured correctly

---

## 8. Troubleshooting

### Issue: PVC stuck Pending

Symptom:
```
NAME       STATUS    STORAGECLASS
test-pvc   Pending   gp3
```

Possible causes:
1. No pod consuming PVC (with `WaitForFirstConsumer` mode) → normal
2. EBS CSI Driver not running → `kubectl get pods -n kube-system | grep ebs-csi`
3. IAM Role missing on EC2 → check Terraform
4. StorageClass doesn't exist → `kubectl get storageclass`

### Issue: EBS CSI Controller in Error State

Symptom:
```
ebs-csi-controller-xxx   1/5   Error
```

Cause: IAM credentials missing.

Check logs:
```bash
kubectl logs -n kube-system <pod-name> -c csi-provisioner | tail -20
```

Common error: `no EC2 IMDS role found`

Fix:
1. Verify IAM Role attached to EC2 instance (via Terraform)
2. Restart EBS CSI Driver:
```bash
kubectl rollout restart deployment ebs-csi-controller -n kube-system
```

### Issue: Grafana Dashboard Lost After Pod Restart

Cause: Persistence not enabled.

Verify:
```bash
kubectl get pvc -n monitoring | grep grafana
```

If no PVC for Grafana → reinstall with `persistence.enabled=true`.

### Issue: Target Group Unhealthy

Symptom: ALB returns 502 or connection timeout.

Possible causes:
1. NodePort changed after Helm reinstall
   → Use `--set service.nodePort=` to fix it
2. Worker security group blocking traffic
   → Check NodePort range (30000-32767) is allowed from ALB SG
3. App not yet ready
   → Wait 1-2 minutes after install

### Issue: ALB Target Group Health Check Path Wrong

Default `/` may return 302/404 for some apps.

Use specific health endpoints:
- Grafana: `/api/health`
- Prometheus: `/-/healthy`

Update health check matcher:
- `200` for specific endpoints
- `200-404` for catch-all

---

## 9. Production Considerations

### Security

**Prometheus has no built-in authentication**. In production:
- Don't expose Prometheus to the internet
- Use OAuth proxy (e.g. `oauth2-proxy`) in front of Prometheus
- Or keep Prometheus internal-only, expose only Grafana

**Grafana default password should be changed immediately**.

### Resource Limits

Default Helm chart doesn't set resource limits. For production:

```yaml
prometheus:
  prometheusSpec:
    resources:
      requests:
        cpu: 500m
        memory: 2Gi
      limits:
        cpu: 2000m
        memory: 8Gi

grafana:
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 1Gi
```

### Retention Policy

Default Prometheus retention: 15 days. Adjust based on disk size:

```yaml
prometheus:
  prometheusSpec:
    retention: 30d
    retentionSize: 18GB
```

Rule: keep `retentionSize` 80% of PVC size.

### Long-term Storage

For metrics older than 30 days, use Thanos or Cortex to offload to S3:
- Prometheus → local PVC for hot data (last 2 weeks)
- Thanos sidecar → uploads chunks to S3 every 2 hours
- Long-term queries → served from S3

### Backup Strategy

**EBS Snapshot via AWS Backup** for Grafana PVC:

```hcl
resource "aws_backup_plan" "grafana" {
  name = "grafana-backup"
  rule {
    rule_name         = "daily-backup"
    target_vault_name = aws_backup_vault.main.name
    schedule          = "cron(0 5 ? * * *)"
    lifecycle {
      delete_after = 30
    }
  }
}
```

**For dashboards**: backup as JSON to Git (GitOps approach is preferred
over EBS snapshot).

### Reclaim Policy Warning

Default StorageClass uses `Delete` reclaim policy:
- PVC deleted → PV deleted → EBS volume deleted → data gone forever

For critical data, use `Retain`:

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3-retain
provisioner: ebs.csi.aws.com
reclaimPolicy: Retain   # PV stays even if PVC is deleted
```

### HTTPS

For production, terminate SSL at ALB:
1. Request ACM certificate
2. ALB Listener on port 443 with certificate
3. Forward to Target Group

### Alerting

Setup Alertmanager rules to send notifications:
- Slack
- PagerDuty
- Email
- Webhook

Example alert:
```yaml
groups:
- name: pod_alerts
  rules:
  - alert: PodCrashLooping
    expr: rate(kube_pod_container_status_restarts_total[5m]) > 0
    for: 5m
    annotations:
      summary: "Pod {{ $labels.pod }} is crash looping"
```

---

## 10. Key Takeaway

- **Never store stateful data in pods** — pods are ephemeral
- Use **PVC + PV + StorageClass** to persist data outside pods
- AWS EBS CSI Driver auto-provisions EBS volumes for PVCs
- Default Helm charts often use `emptyDir` — always check and override
- IAM Role on EC2 (or IRSA in production) is required for cloud storage
- Set fixed NodePort (`--set service.nodePort=...`) to prevent
  random port changes on Helm reinstall
- Backup dashboards as JSON to Git — GitOps is the source of truth
- Persistent storage is one of the most overlooked aspects when
  deploying Kubernetes — yet it's critical for production
- Always test persistence by deleting pods and verifying data survives
- For production, add: resource limits, retention policy, alerting,
  HTTPS, authentication, and long-term storage strategy
# Resource Limits & HPA Runbook

A reusable guide to understand resource management and horizontal
pod autoscaling in Kubernetes.

## Table of Contents
1. Why Resource Limits Matter
2. Requests vs Limits
3. CPU vs Memory Behavior
4. QoS Class
5. What is HPA?
6. metrics-server
7. Prerequisites
8. Practice — Resource Limits
9. Practice — HPA
10. Troubleshooting
11. Production Considerations
12. Key Takeaway

---

## 1. Why Resource Limits Matter

Without resource limits, a pod can consume all the memory on a node.
When the node runs out of memory, Kubernetes panics and starts
OOM Killing pods. Which pod gets killed depends on QoS class — it
could be the greedy pod, or it could be other innocent pods on the
same node.

This is called the **noisy neighbor problem** — one greedy pod
disrupts all its neighbors.

```
Pod with memory leak (no limit)
  → memory keeps growing
  → consumes ALL node memory
  → node runs out of memory
  → Kubernetes OOM Kill kicks in
  → other pods on the same node can crash too
```

Resource limits protect the node and other pods from a single
misbehaving pod.

---

## 2. Requests vs Limits

### Requests
- The minimum guaranteed for the pod
- Used by the scheduler to pick a node
- Guarantee: the pod will definitely get this amount

### Limits
- The maximum the pod is allowed to use
- The pod cannot exceed this boundary
- CPU over limit → throttled (slowed down)
- Memory over limit → OOM Killed (pod destroyed)

```yaml
resources:
  requests:
    cpu: 100m        # guaranteed 0.1 CPU core
    memory: 128Mi    # guaranteed 128 MB
  limits:
    cpu: 500m        # maximum 0.5 CPU core
    memory: 256Mi    # maximum 256 MB, exceed = OOM Kill
```

Analogy:
```
requests = a table you reserved at a restaurant
           → you are guaranteed a seat

limits   = the time limit on how long you can stay
           → exceed it → you get kicked out (OOM Kill)
```

> Note on units: CPU `100m` means 100 millicores = 0.1 core.
> Memory `128Mi` means 128 mebibytes.

---

## 3. CPU vs Memory Behavior

CPU and memory are treated differently when a pod exceeds its limit.

### CPU — Compressible Resource
CPU can be time-sliced. If a pod asks for more CPU than available,
Kubernetes makes it "wait its turn." The pod becomes slow, but
stays alive.

```
Like a queue:
  more people in line → you wait longer
  but you don't "die" — you're just slower
```

### Memory — Incompressible Resource
Memory cannot be shared or sliced. Once a pod uses 256MB, that
256MB is genuinely occupied. It cannot be reclaimed or made to
"wait." The only way to free it is to kill the process.

```
Like a chair:
  an occupied chair is occupied
  no "half-sitting"
  to free it → the person must stand (be killed)
```

### Comparison

```
                CPU              Memory
─────────────────────────────────────────────
Type            Compressible     Incompressible
Over limit      Throttle         OOM Kill
Pod status      Alive, slow      Dead
Recovery        Automatic        Pod restart
```

---

## 4. QoS Class

Resource limits determine a pod's **QoS (Quality of Service)
Class**. This decides the kill order when a node runs out of
resources.

### The 3 QoS Classes

```
1. Guaranteed  (safest)
   requests == limits (exactly equal)
   → killed LAST during node pressure

2. Burstable   (middle)
   requests < limits (has requests, different from limits)
   → killed AFTER BestEffort

3. BestEffort  (most vulnerable)
   no requests/limits at all
   → killed FIRST during node pressure
```

Analogy — passengers during an emergency:
```
Node out of memory = plane must drop weight

Guaranteed  = first-class passenger (fully booked)
              → saved last

Burstable   = economy passenger (partially booked)
              → saved after the free riders

BestEffort  = stowaway (no booking)
              → "dropped" first
```

### Practical Implications

```
Critical pods (database, payment service):
  → set requests == limits
  → QoS: Guaranteed
  → safest from OOM Kill

Normal pods (web app):
  → set requests < limits
  → QoS: Burstable
  → allowed to "burst" when needed

Unimportant pods (avoid in production):
  → set nothing
  → QoS: BestEffort
  → first victim during node pressure
```

### How to Make a Pod Guaranteed

```yaml
resources:
  requests:
    cpu: 200m
    memory: 256Mi
  limits:
    cpu: 200m        # SAME as requests
    memory: 256Mi    # SAME as requests
```

`requests == limits` → automatically becomes **Guaranteed**.

---

## 5. What is HPA?

HPA (Horizontal Pod Autoscaler) automatically adjusts the number
of pod replicas based on observed metrics (typically CPU or
memory usage).

```
Low load   → fewer pods (save resources)
High load  → more pods (handle traffic)
```

Horizontal scaling = add/remove pods (not resize existing pods).
Vertical scaling = resize a pod's resources (that's VPA, different).

HPA needs:
- A deployment with resource **requests** defined (to calculate
  percentage)
- **metrics-server** installed (to read actual usage)

---

## 6. metrics-server

metrics-server collects resource usage (CPU/memory) from kubelets
and exposes it via the Metrics API. HPA reads from this API to
make scaling decisions.

```
metrics-server → scrapes kubelet → exposes Metrics API
                                         ↓
                                   HPA reads usage
                                         ↓
                              decides scale up/down
```

Without metrics-server:
- `kubectl top` does not work
- HPA shows `<unknown>` for targets and cannot scale

---

## 7. Prerequisites

- Kubernetes cluster running
- `kubectl` configured
- metrics-server (installed in this runbook)

---

## 8. Practice — Resource Limits

### 8.1 Pod Without Resource Limit

```bash
kubectl create namespace resource-test
kubectl run nginx-no-limit --image=nginx -n resource-test

# Check resources
kubectl describe pod nginx-no-limit -n resource-test | grep -A 5 "Limits\|Requests"
```

Result: empty output → the pod has NO requests/limits at all.
This is dangerous in production.

### 8.2 Pod With Resource Limit

```bash
cat << 'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: nginx-with-limit
  namespace: resource-test
spec:
  containers:
  - name: nginx
    image: nginx
    resources:
      requests:
        cpu: 100m
        memory: 128Mi
      limits:
        cpu: 200m
        memory: 256Mi
EOF
```

Check:
```bash
kubectl describe pod nginx-with-limit -n resource-test | grep -A 8 "Limits\|Requests"
```

Output:
```
Limits:
  cpu:     200m
  memory:  256Mi
Requests:
  cpu:     100m
  memory:  128Mi
```

### 8.3 Test OOM Kill

Deploy a pod that deliberately exceeds its memory limit:

```bash
cat << 'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: memory-hog
  namespace: resource-test
spec:
  containers:
  - name: stress
    image: polinux/stress
    resources:
      requests:
        memory: 50Mi
      limits:
        memory: 100Mi
    command: ["stress"]
    args: ["--vm", "1", "--vm-bytes", "200M", "--vm-hang", "1"]
EOF
```

Explanation:
```
limit memory:     100Mi
stress allocates: 200M   ← deliberately over the limit!
```

Check status:
```bash
kubectl get pod memory-hog -n resource-test
```

Result:
```
NAME         READY   STATUS             RESTARTS
memory-hog   0/1     CrashLoopBackOff   1
```

Confirm the cause:
```bash
kubectl describe pod memory-hog -n resource-test | grep -A 3 "Last State"
```

Output:
```
Last State:     Terminated
  Reason:       OOMKilled
  Exit Code:    137
```

Exit code 137 = 128 + 9 (SIGKILL). The kernel OOM Killer killed
the pod because it exceeded the memory limit. This protects the
node — the greedy pod dies, the node and other pods survive.

### 8.4 Check QoS Class

```bash
kubectl describe pod nginx-with-limit -n resource-test | grep "QoS Class"
kubectl describe pod nginx-no-limit -n resource-test | grep "QoS Class"
```

Results:
```
nginx-with-limit → QoS Class: Burstable    (requests < limits)
nginx-no-limit   → QoS Class: BestEffort   (no requests/limits)
```

---

## 9. Practice — HPA

### 9.1 Install metrics-server

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
```

Check:
```bash
kubectl get deployment metrics-server -n kube-system
kubectl get pods -n kube-system | grep metrics-server
```

### 9.2 Fix metrics-server TLS Error (Self-Managed Cluster)

On kubeadm/self-managed clusters, metrics-server often stays
`0/1` not ready. Check logs:

```bash
kubectl logs -n kube-system -l k8s-app=metrics-server --tail=15
```

Common error:
```
x509: cannot validate certificate for <IP> because it doesn't
contain any IP SANs
```

Cause: metrics-server connects to kubelet via HTTPS, but the
kubelet certificate has no IP SAN.

Fix for lab — add `--kubelet-insecure-tls`:
```bash
kubectl patch deployment metrics-server -n kube-system --type='json' \
  -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--kubelet-insecure-tls"}]'
```

> Note: `--kubelet-insecure-tls` is fine for lab. In production,
> the kubelet should serve a certificate with proper IP SANs.

Verify it works:
```bash
kubectl top nodes
```

### 9.3 Deploy Application for HPA

The deployment MUST have resource requests defined — HPA needs
them to calculate the usage percentage.

```bash
cat << 'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: php-apache
  namespace: resource-test
spec:
  replicas: 1
  selector:
    matchLabels:
      app: php-apache
  template:
    metadata:
      labels:
        app: php-apache
    spec:
      containers:
      - name: php-apache
        image: registry.k8s.io/hpa-example
        ports:
        - containerPort: 80
        resources:
          requests:
            cpu: 100m
          limits:
            cpu: 200m
---
apiVersion: v1
kind: Service
metadata:
  name: php-apache
  namespace: resource-test
spec:
  selector:
    app: php-apache
  ports:
  - port: 80
EOF
```

### 9.4 Create HPA

```bash
kubectl autoscale deployment php-apache -n resource-test \
  --cpu-percent=50 \
  --min=1 \
  --max=10
```

Explanation:
```
--cpu-percent=50  → if CPU usage > 50% of requests → scale up
--min=1           → minimum 1 pod
--max=10          → maximum 10 pods
```

Check status:
```bash
kubectl get hpa -n resource-test
```

Wait until `TARGETS` shows a number (not `<unknown>`):
```
NAME         REFERENCE               TARGETS   MINPODS   MAXPODS   REPLICAS
php-apache   Deployment/php-apache   1%/50%    1         10        1
```

### 9.5 Test Auto-Scaling

In a **second terminal**, generate continuous load:
```bash
kubectl run load-generator -n resource-test --rm -it --image=busybox -- \
  /bin/sh -c "while true; do wget -q -O- http://php-apache; done"
```

In the **first terminal**, watch the HPA:
```bash
kubectl get hpa -n resource-test -w
```

Observed scaling:
```
CPU 1%    → REPLICAS 1   (idle)
CPU 115%  → REPLICAS 1   (HPA detects, starts calculating)
CPU 201%  → REPLICAS 3   (scale up!)
CPU 38%   → REPLICAS 7   (load spread across pods, CPU per pod drops)
```

### 9.6 Test Scale Down

Stop the load generator (`Ctrl+C` in terminal 2), then watch:
```bash
kubectl get hpa -n resource-test -w
```

Pods will terminate gradually until back to 1 replica.

> Important: scale down is SLOWER than scale up — this is by
> design (see Key Takeaway).

### 9.7 Cleanup

```bash
kubectl delete namespace resource-test
```

---

## 10. Troubleshooting

### HPA shows TARGETS as `<unknown>`

Cause: metrics-server not working, or deployment has no resource
requests.
Fix:
```bash
# Check metrics-server
kubectl top nodes
# If this fails, fix metrics-server (see 9.2)

# Check deployment has requests
kubectl describe deployment <name> -n <namespace> | grep -A 3 Requests
```

### metrics-server stuck 0/1

Cause: TLS verification error to kubelet (common on kubeadm).
Fix: add `--kubelet-insecure-tls` (see 9.2).

### Pod OOMKilled repeatedly (CrashLoopBackOff)

Cause: memory limit too low for the application.
Fix: increase memory limit, or fix the application's memory usage.
```bash
kubectl describe pod <name> -n <namespace> | grep -A 3 "Last State"
```

### HPA not scaling up despite high load

Possible causes:
1. metrics-server lag — wait 1-2 minutes
2. Already at max replicas
3. CPU not actually above target (check `kubectl top pods`)

### HPA not scaling down

Cause: stabilization window (default 5 minutes). This is normal —
wait longer.

---

## 11. Production Considerations

### Always Set Resource Requests and Limits

Never run BestEffort pods in production. At minimum, set requests
and limits for every container.

### Use Guaranteed QoS for Critical Workloads

Databases, payment services, and other critical pods should have
`requests == limits` to get Guaranteed QoS.

### Set Realistic Limits

- Too low → unnecessary OOM Kills and throttling
- Too high → wasted resources, poor bin-packing
- Use monitoring (Prometheus) to find actual usage, then set
  limits with some headroom

### LimitRange and ResourceQuota

- **LimitRange** — set default requests/limits per namespace, so
  pods without explicit limits still get sensible defaults
- **ResourceQuota** — cap total resource usage per namespace

### HPA Best Practices

- Set sensible min/max replicas (min should handle baseline load)
- Consider scaling on custom metrics (requests per second, queue
  length) not just CPU
- Combine HPA (pod scaling) with Cluster Autoscaler (node scaling)
- Test scaling behavior under realistic load before production

### metrics-server in Production

Fix the kubelet TLS properly — do not use `--kubelet-insecure-tls`
in production. The kubelet should serve a certificate with valid
IP SANs.

---

## 12. Key Takeaway

- Resource limits prevent the **noisy neighbor problem**
- **requests** = guaranteed minimum; **limits** = hard maximum
- **CPU is compressible** (throttled), **memory is incompressible**
  (OOM Killed)
- QoS Class determines kill order: Guaranteed > Burstable >
  BestEffort
- `requests == limits` → Guaranteed QoS (use for critical pods)
- HPA needs resource **requests** + **metrics-server** to work
- Exit code 137 = OOM Killed

On scale up vs scale down:
```
Scale UP — fast (seconds):
  high load = emergency, must respond quickly

Scale DOWN — slow (minutes):
  stabilization window (default 5 minutes)
  prevents "flapping" — repeated up-down-up-down
  if load returns, pods are still there (no need to recreate)

Philosophy: better to be "briefly wasteful" than to
            "flap" and hurt stability
```

Why this matters for your career:
- Resource management is a core production skill
- "How does autoscaling work?" is a common interview question
- Misconfigured limits cause real production incidents
- This skill transfers to any Kubernetes platform (EKS, GKE, AKS)

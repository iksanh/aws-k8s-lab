# Pod Security Standards Runbook

A reusable guide to enforce security standards on pods using
Kubernetes Pod Security Admission.

## Table of Contents
1. Default Behavior
2. What are Pod Security Standards?
3. The 3 Levels
4. The 3 Modes
5. How It Works
6. Prerequisites
7. Practice
8. Real-World Strategy
9. Troubleshooting
10. Production Considerations
11. Key Takeaway

---

## 1. Default Behavior

By default, Kubernetes is **permissive** — just like networking.
A pod is allowed to:
- Run as root (UID 0)
- Use privileged mode (full kernel access on the node)
- Mount host filesystem (hostPath)
- Use host network and host PID namespace
- Use dangerous Linux capabilities

There is NO security barrier by default.

```
Attack scenario:
  Pod runs as root + privileged
       ↓
  Hacker compromises the application
       ↓
  Because root + privileged:
    → access node's filesystem
    → read all secrets on the node
    → install rootkit on the node
    → "escape" container to host
       ↓
  Compromise 1 pod = compromise the WHOLE NODE
```

This is called **container escape** — the worst nightmare in
container security.

---

## 2. What are Pod Security Standards?

Pod Security Standards (PSS) is a Kubernetes-native mechanism to
enforce security policies on pods. It is built into the API server
since Kubernetes 1.25, replacing the older PodSecurityPolicy.

PSS is applied per **namespace** using labels. The API server
checks every pod creation request against the standard.

---

## 3. The 3 Levels

```
1. Privileged (most permissive)
   → no restrictions
   → anything goes
   → for: system pods (CNI, CSI driver, monitoring agents)

2. Baseline (middle)
   → blocks the most dangerous things
   → no privileged, no hostNetwork, no hostPID
   → still allows running as root
   → for: general applications

3. Restricted (strictest)
   → full hardening
   → no root user
   → no privilege escalation
   → must drop ALL capabilities
   → must set seccomp profile
   → for: production-sensitive applications
```

### What "Restricted" Requires

Looking at the error message Kubernetes returns when a pod
violates restricted, the requirements are:
- `securityContext.privileged: false` (or omit)
- `securityContext.allowPrivilegeEscalation: false`
- `securityContext.capabilities.drop: ["ALL"]`
- `runAsNonRoot: true`
- `seccompProfile.type: "RuntimeDefault"` (or `"Localhost"`)

---

## 4. The 3 Modes

```
Mode      Effect
─────────────────────────────────────────────────────
enforce   reject pods that violate the standard
warn      allow pod but print warning to user
audit     allow pod but log violation in audit log
```

Modes can be combined. Common pattern:
```yaml
pod-security.kubernetes.io/enforce: baseline
pod-security.kubernetes.io/warn: restricted
pod-security.kubernetes.io/audit: restricted
```
This enforces baseline, but warns and audits anything below
restricted — giving you visibility before upgrading enforcement.

---

## 5. How It Works

```
1. Add label to namespace:
   pod-security.kubernetes.io/enforce: restricted
       ↓
2. Pod creation request arrives at API server
       ↓
3. Pod Security Admission Controller checks:
   "Does this pod meet 'restricted' standard?"
       ↓
4. If yes  → pod created
   If no   → pod rejected with detailed error
```

The check happens at the **API server level**, BEFORE the pod
is scheduled or created. This is different from Network Policy:

```
Network Policy → blocks traffic AFTER pod runs
Pod Security   → blocks pod BEFORE it's created
```

---

## 6. Prerequisites

- Kubernetes cluster v1.25 or later
- `kubectl` configured
- Understanding of `securityContext` in pod spec

---

## 7. Practice

### 7.1 Create Test Namespace

```bash
kubectl create namespace pss-test
```

### 7.2 Verify Default is Permissive

Deploy a privileged pod (no PSS applied yet):

```bash
cat << 'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: privileged-pod
  namespace: pss-test
spec:
  containers:
  - name: nginx
    image: nginx
    securityContext:
      privileged: true
EOF
```

Check status:
```bash
kubectl get pod privileged-pod -n pss-test
```

Output:
```
NAME             READY   STATUS    RESTARTS
privileged-pod   1/1     Running   0
```

The privileged pod is running. No security barrier.

### 7.3 Apply Restricted Standard

```bash
kubectl label namespace pss-test \
  pod-security.kubernetes.io/enforce=restricted
```

Output includes warnings about existing pods that violate the
new standard:
```
Warning: existing pods in namespace "pss-test" violate the new
PodSecurity enforce level "restricted:latest"
Warning: privileged-pod: privileged, allowPrivilegeEscalation
!= false, unrestricted capabilities, runAsNonRoot != true,
seccompProfile
```

5 violations in one pod! But existing pods are NOT deleted —
they keep running. Only NEW pods will be blocked.

Verify label:
```bash
kubectl get namespace pss-test --show-labels
```

### 7.4 Test: Deploy Privileged Pod (Should Be Rejected)

```bash
# Delete old pod first
kubectl delete pod privileged-pod -n pss-test

# Try to create privileged pod again
cat << 'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: privileged-pod
  namespace: pss-test
spec:
  containers:
  - name: nginx
    image: nginx
    securityContext:
      privileged: true
EOF
```

Result:
```
Error from server (Forbidden): pods "privileged-pod" is
forbidden: violates PodSecurity "restricted:latest":
  privileged (container "nginx" must not set
    securityContext.privileged=true),
  allowPrivilegeEscalation != false (must set
    securityContext.allowPrivilegeEscalation=false),
  unrestricted capabilities (must set
    securityContext.capabilities.drop=["ALL"]),
  runAsNonRoot != true (pod or container "nginx" must set
    securityContext.runAsNonRoot=true),
  seccompProfile (must set securityContext.seccompProfile.type
    to "RuntimeDefault" or "Localhost")
```

The error is descriptive — it tells you EXACTLY what to fix.

### 7.5 Deploy a Compliant Pod

```bash
cat << 'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: nginx-secure
  namespace: pss-test
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 101
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: nginx
    image: nginxinc/nginx-unprivileged:latest
    ports:
    - containerPort: 8080
    securityContext:
      allowPrivilegeEscalation: false
      capabilities:
        drop: ["ALL"]
EOF
```

Explanation:
```
runAsNonRoot: true            → cannot run as root
runAsUser: 101                → use nginx user UID
seccompProfile RuntimeDefault → restrict syscalls
allowPrivilegeEscalation: false → cannot escalate via setuid
capabilities drop ALL         → drop all Linux capabilities
image: nginx-unprivileged     → nginx variant that runs as non-root
```

Verify:
```bash
kubectl get pod nginx-secure -n pss-test
```

Result:
```
NAME           READY   STATUS    RESTARTS
nginx-secure   1/1     Running   0
```

The compliant pod runs successfully.

### 7.6 Cleanup

```bash
kubectl delete namespace pss-test
```

---

## 8. Real-World Strategy

Different namespaces have different needs:

```
kube-system (system pods):
  enforce: privileged
  reason: CNI, CSI need full access

argocd, monitoring (operator pods):
  enforce: baseline
  reason: needs some elevated permissions but not privileged

production apps:
  enforce: restricted
  reason: strict security for sensitive workloads

dev/staging namespaces:
  enforce: baseline
  warn: restricted
  reason: permissive for experimentation, but warn devs
          about future restrictions
```

### Migration Approach for Existing Clusters

Don't enforce strict policies on day 1 — you'll break things.
Use this gradual approach:

```
Phase 1 (audit only — no breaking):
  pod-security.kubernetes.io/audit: restricted
  → see which pods violate
  → log to audit only, no impact

Phase 2 (warn):
  pod-security.kubernetes.io/warn: restricted
  → developers see warnings when deploying
  → time to fix manifests

Phase 3 (enforce):
  pod-security.kubernetes.io/enforce: restricted
  → strict, violations rejected
```

---

## 9. Troubleshooting

### Existing pod violates PSS but still runs

PSS only checks NEW pods. Existing pods continue running even if
they violate. To clean up:
```bash
# Find pods that don't comply (manual check)
kubectl get pods -n <namespace>

# Delete and let them be re-created from compliant spec
kubectl delete pod <name> -n <namespace>
```

### Pod stuck pending after PSS applied

Cause: a controller (Deployment, StatefulSet) is creating pods
that violate PSS. The pods are rejected.
Fix: update the controller's pod template to be compliant.
```bash
kubectl describe replicaset <name> -n <namespace>
# Look for "Events" section showing PSS rejection
```

### "must set runAsNonRoot=true" but my image needs root

Some images (e.g., legacy apps) need to run as root.
Options:
1. Find or build a non-root variant of the image
2. Use `baseline` level for that namespace instead of `restricted`
3. Add an exception namespace with `privileged` (not recommended
   for production)

### How to debug which pods are non-compliant

```bash
# Use audit mode to see violations
kubectl label namespace <name> \
  pod-security.kubernetes.io/audit=restricted

# Check API server audit logs (cluster-dependent)
```

---

## 10. Production Considerations

### Default Deny by Default

Apply at minimum `baseline` to every namespace. Use `restricted`
for production app namespaces.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: production
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/audit: restricted
```

### Use Pinned Standard Version

Pinning to a specific Kubernetes version protects against
unexpected changes when the cluster upgrades:
```yaml
pod-security.kubernetes.io/enforce: restricted
pod-security.kubernetes.io/enforce-version: v1.28
```

### Combine with Other Controls

PSS is one layer. Combine with:
- Network Policy (network isolation)
- RBAC (API access control)
- ResourceQuota (resource limits per namespace)
- ImagePolicy (allowed container images only)
- OPA Gatekeeper / Kyverno (advanced custom policies)

### Image Choice Matters

Many official images run as root by default. For `restricted`:
- Use distroless images when possible
- Use `nginx-unprivileged` instead of `nginx`
- Build custom images with non-root user

### GitOps for Namespace Labels

Store namespace manifests in Git, including PSS labels. This
ensures security policy is auditable and reviewable via PR.

### Beyond PSS — Kyverno or OPA Gatekeeper

PSS has fixed levels. For custom policies (e.g., "all pods must
have specific labels"), use:
- **Kyverno** — Kubernetes-native, simpler syntax
- **OPA Gatekeeper** — more powerful but complex (Rego language)

---

## 11. Key Takeaway

- Default Kubernetes is **permissive** — pods can do anything,
  including running privileged and as root
- Pod Security Standards enforce security at the API server level
- Three levels: **privileged**, **baseline**, **restricted**
- Three modes: **enforce**, **warn**, **audit**
- Apply via namespace labels — granular per-namespace control
- Existing pods are NOT affected when label is added; only NEW
  pods are checked
- The `restricted` level requires: no privileged, no privilege
  escalation, drop ALL capabilities, runAsNonRoot, seccompProfile
- For migration, use audit → warn → enforce progression
- Many official images need adaptation to be `restricted`-compliant
  (use unprivileged variants or distroless)
- Combine with Network Policy, RBAC, and ResourceQuota for
  defense in depth

Why this matters for your career:
- Container security is a hot topic in DevOps interviews
- "How do you secure pods in Kubernetes?" is asked often
- Compliance (SOC2, PCI-DSS) requires container hardening
- Real production incidents involve container escape — PSS prevents
  the most common vectors
- This skill transfers to all Kubernetes platforms (EKS, GKE, AKS)

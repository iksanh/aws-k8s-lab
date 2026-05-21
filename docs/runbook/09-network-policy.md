# Network Policy Runbook

A reusable guide to understand and implement Network Policy for
pod-to-pod traffic control in Kubernetes.

## Table of Contents
1. Default Network Behavior
2. What is Network Policy?
3. Why do we need it?
4. Ingress vs Egress
5. Key Concepts
6. Prerequisites
7. Practice — Ingress Policy
8. Practice — Egress Policy
9. Real-World Pattern (3-tier)
10. Troubleshooting
11. Production Considerations
12. Key Takeaway

---

## 1. Default Network Behavior

By default, Kubernetes networking is a **flat network**:
- Any pod can communicate with any other pod
- Namespace boundaries do not matter
- No restrictions at all

Example:
```
pod-frontend (namespace: web)
     ↓ can access
pod-database (namespace: data)   ← different namespace, still works!
```

This is dangerous. If a hacker compromises one pod, they can reach
every other pod in the cluster with zero barriers.

Analogy:
```
Default Kubernetes = apartment with no doors
  All rooms connected
  Anyone can enter any room
  Burglar breaks into 1 room → can access all rooms

Network Policy = install doors with locks
  Database room → only backend allowed
  Backend room → only frontend allowed
```

---

## 2. What is Network Policy?

Network Policy is a Kubernetes resource that controls network
traffic between pods — defining which pods can access which,
for both incoming (Ingress) and outgoing (Egress) traffic.

Important: Network Policy requires a CNI plugin that supports it
(Calico, Cilium, Weave). Flannel does NOT support Network Policy.

This lab uses Calico, which supports Network Policy.

---

## 3. Why do we need it?

We need Network Policy to restrict pod access — implementing the
principle of least privilege at the network level.

Without Network Policy:
- Compromised pod → can reach any pod
- Data exfiltration → no barrier
- Lateral movement → unrestricted
- Compliance failure → no network segmentation

With Network Policy:
- Each pod only talks to what it needs
- Blast radius of a breach is limited
- Network segmentation for compliance

---

## 4. Ingress vs Egress

```
Ingress → who can ACCESS the pod (incoming traffic)
          example: who can access pod-a

Egress  → what the pod can ACCESS (outgoing traffic)
          example: what pod-a is allowed to reach
```

---

## 5. Key Concepts

### podSelector
Selects which pods the policy applies to.
```yaml
podSelector: {}                    # ALL pods in the namespace
podSelector:
  matchLabels:
    role: database                 # only pods with label role=database
```

### namespaceSelector
Selects source/destination by namespace.
```yaml
namespaceSelector:
  matchLabels:
    kubernetes.io/metadata.name: team-a   # traffic from namespace team-a
```

### policyTypes
Declares which direction the policy controls.
```yaml
policyTypes:
  - Ingress        # control incoming traffic
  - Egress         # control outgoing traffic
```

### The "default deny" pattern
```yaml
podSelector: {}            # applies to all pods
policyTypes:
  - Ingress
# no ingress rules → DENY ALL incoming traffic
```

If a policyType is declared but no rules are given, everything
in that direction is denied.

### Additive behavior
Network Policies are additive. Multiple policies are combined with
OR logic — traffic is allowed if ANY policy allows it. Traffic is
denied only if NO policy allows it.

---

## 6. Prerequisites

- Kubernetes cluster with a CNI that supports Network Policy
  (this lab uses Calico)
- `kubectl` configured
- Two namespaces for testing

---

## 7. Practice — Ingress Policy

### 7.1 Setup Test Pods

```bash
# Pod in namespace team-a
kubectl create namespace team-a
kubectl run pod-a --image=nginx -n team-a

# Pod in namespace team-b
kubectl create namespace team-b
kubectl run pod-b --image=nginx -n team-b

# Get pod IPs
kubectl get pods -n team-a -o wide
kubectl get pods -n team-b -o wide
```

### 7.2 Verify Default Behavior (No Isolation)

```bash
# From pod-a, access pod-b by IP (use pod-b's actual IP)
kubectl exec -n team-a pod-a -- curl -s --max-time 5 <POD_B_IP>
```

Result: returns nginx HTML → cross-namespace traffic works by
default. No isolation exists.

### 7.3 Default Deny Ingress

Block ALL incoming traffic to namespace team-b:

```bash
cat << 'EOF' | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: team-b
spec:
  podSelector: {}
  policyTypes:
    - Ingress
EOF
```

Explanation:
```
podSelector: {}          → applies to ALL pods in team-b
policyTypes: Ingress     → controls incoming traffic
(no ingress rules)       → DENY ALL incoming traffic
```

Test again:
```bash
kubectl exec -n team-a pod-a -- curl -s --max-time 5 <POD_B_IP>
```

Result: `exit code 28` (timeout) → traffic is now blocked.

### 7.4 Allow Specific Traffic

Allow pod-b to be accessed ONLY from pods labeled `role=allowed`
in namespace team-a:

```bash
# Label pod-a
kubectl label pod pod-a -n team-a role=allowed

# Apply allow policy
cat << 'EOF' | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-from-labeled-pod
  namespace: team-b
spec:
  podSelector: {}
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: team-a
          podSelector:
            matchLabels:
              role: allowed
EOF
```

Test:
```bash
kubectl exec -n team-a pod-a -- curl -s --max-time 5 <POD_B_IP>
```

Result: returns nginx HTML → pod-a (labeled) can now access pod-b.

### 7.5 Negative Test (Pod Without Label Must Be Denied)

```bash
# Create pod without the label
kubectl run pod-c --image=nginx -n team-a
kubectl get pod pod-c -n team-a

# Test access to pod-b
kubectl exec -n team-a pod-c -- curl -s --max-time 5 <POD_B_IP>
```

Result: timeout → pod-c (no label) is denied.

Summary:
```
pod-a (label role=allowed)  → pod-b → ALLOWED
pod-c (no label)            → pod-b → DENIED
```

This proves Network Policy is granular — per-pod based on labels,
not all-or-nothing.

---

## 8. Practice — Egress Policy

### 8.1 Verify Default Egress (Unrestricted)

```bash
# pod-c can reach internet (test by IP to skip DNS)
kubectl exec -n team-a pod-c -- curl -s --max-time 5 -o /dev/null -w "%{http_code}" https://8.8.8.8

# pod-c can reach other pods
kubectl exec -n team-a pod-c -- curl -s --max-time 5 -o /dev/null -w "%{http_code}" <POD_A_IP>
```

Result: both work → default egress is unrestricted.

### 8.2 Restrict Egress

Scenario — pod-c may ONLY:
- Access DNS (port 53) — required for name resolution
- Access pod-a
- NOT access the internet
- NOT access other pods

```bash
cat << 'EOF' | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: egress-restricted
  namespace: team-a
spec:
  podSelector:
    matchLabels:
      run: pod-c
  policyTypes:
    - Egress
  egress:
    # Allow DNS (required)
    - to:
        - namespaceSelector: {}
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
    # Allow access to pod-a only
    - to:
        - podSelector:
            matchLabels:
              run: pod-a
EOF
```

### 8.3 Test Egress Restriction

```bash
# Should be DENIED (internet)
kubectl exec -n team-a pod-c -- curl -s --max-time 5 -o /dev/null -w "%{http_code}" https://8.8.8.8

# Should be ALLOWED (pod-a)
kubectl exec -n team-a pod-c -- curl -s --max-time 5 -o /dev/null -w "%{http_code}" <POD_A_IP>
```

Result:
```
pod-c → 8.8.8.8 (internet)  → timeout → DENIED
pod-c → pod-a               → 200 → ALLOWED
```

> Important: Always allow DNS (port 53) in egress policies.
> Without it, pods cannot resolve any service names and most
> applications will break.

---

## 9. Real-World Pattern (3-tier)

A typical 3-tier application with proper network segmentation:

```
frontend:
  Ingress  → from internet (via ingress controller)
  Egress   → only to backend

backend:
  Ingress  → only from frontend
  Egress   → only to database + DNS

database:
  Ingress  → only from backend
  Egress   → DNS only (or none)
```

Each tier is isolated. Compromising one tier does not
automatically grant access to other tiers.

### Recommended Approach

1. Start with `default-deny-ingress` and `default-deny-egress`
   in every namespace
2. Then add specific allow rules per tier
3. Always allow DNS in egress policies
4. Test each rule with positive and negative cases

---

## 10. Troubleshooting

### Network Policy has no effect

Cause: CNI plugin does not support Network Policy.
Fix: Verify CNI. Flannel does NOT support it; use Calico or Cilium.
```bash
kubectl get pods -n kube-system | grep -E "calico|cilium|weave"
```

### Pod cannot resolve DNS after applying egress policy

Cause: Egress policy blocks port 53.
Fix: Add DNS allow rule to egress (see Section 8.2).

### Traffic still allowed after default-deny

Cause: Another policy is allowing it (additive behavior).
Fix: List all policies in the namespace:
```bash
kubectl get networkpolicy -n <namespace>
kubectl describe networkpolicy <name> -n <namespace>
```

### namespaceSelector not matching

Cause: Namespace missing the expected label.
Fix: Kubernetes auto-adds `kubernetes.io/metadata.name` label.
Verify:
```bash
kubectl get namespace <name> --show-labels
```

### How to debug which policy applies to a pod

```bash
# List all policies in namespace
kubectl get networkpolicy -n <namespace>

# Check which pods a policy selects
kubectl describe networkpolicy <name> -n <namespace>
```

---

## 11. Production Considerations

### Start with default-deny everywhere

Apply `default-deny-ingress` and `default-deny-egress` to every
namespace as a baseline, then explicitly allow what's needed.

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: <namespace>
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
```

### Always allow DNS

Every egress policy should allow port 53 to kube-dns, or
applications break.

### Store policies in Git (GitOps)

Network Policies are critical security config — version control
them and deploy via ArgoCD.

### Label namespaces and pods consistently

Network Policy relies heavily on labels. Establish a labeling
convention early:
```
tier: frontend | backend | database
environment: dev | staging | prod
```

### Test with negative cases

Don't just verify "allowed traffic works" — also verify
"denied traffic is actually blocked."

### Monitor denied connections

Calico and Cilium can log denied connections. Use this to
detect misconfigurations and potential attacks.

### Network Policy is namespace-scoped

A policy in namespace A cannot directly reference pods in
namespace B without namespaceSelector. Plan namespace structure
accordingly.

---

## 12. Key Takeaway

- Default Kubernetes networking has **zero isolation** — every
  pod can reach every pod, across namespaces
- Network Policy implements least privilege at the network level
- **Ingress** controls incoming traffic; **Egress** controls
  outgoing traffic
- The `default-deny` pattern: declare policyType with no rules
- Policies are **additive** — combined with OR logic
- **Always allow DNS (port 53)** in egress policies
- Requires a CNI that supports it (Calico, Cilium — not Flannel)
- Test both positive (allowed works) and negative (denied blocked)
- Production approach: default-deny everywhere, then explicit allow
- Store policies in Git — they are critical security configuration

Why this matters for your career:
- Network segmentation is a core security requirement
- Compliance frameworks (PCI-DSS, SOC2) often require it
- Interview question: "How do you isolate workloads in Kubernetes?"
- This skill transfers to any Kubernetes platform
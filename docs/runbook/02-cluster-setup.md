# Cluster Setup Runbook

## Why is install-k8s.sh run on all nodes?
Because every node (control plane and workers) needs:
- **containerd** — container runtime to run containers
- **kubelet** — agent that communicates with the API Server
- **kubeadm** — tool to bootstrap or join a cluster

## Why does cluster init use local IP first, not NLB?
During the init process, the API Server is not ready yet so the NLB
cannot forward traffic — NLB requires port 6443 to be healthy before
it can route traffic, but port 6443 only starts listening after the
API Server is fully running. This creates a deadlock: NLB needs the
API Server to be up, and the API Server needs a valid endpoint to
initialize against.

The solution is to init using the local IP directly, bypassing the NLB.
Once the API Server is running and the NLB health check passes,
we then replace the endpoint with the NLB DNS.

---

## Prerequisites
- Terraform applied
- `set-env.sh` sourced successfully
- `generate-inventory.sh` executed successfully
- All nodes reachable via `ansible all -m ping`

> Note: IPs are dynamic and change every `terraform apply`.
> Always load environment variables first via `set-env.sh`.

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
```

Verify the inventory:
```bash
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

### Step 4 — Copy scripts to all nodes
> Run on: **Local Machine**

Copy install-k8s.sh to all nodes (CP + workers):
```bash
ansible k8s_cluster -i ansible/inventory/hosts.ini -m copy \
  -a "src=scripts/install-k8s.sh dest=~/install-k8s.sh mode=0755"
```

Copy init-cluster.sh to CP-1 only:
```bash
ansible cp-1 -i ansible/inventory/hosts.ini -m copy \
  -a "src=scripts/init-cluster.sh dest=~/init-cluster.sh mode=0755"
```

### Step 5 — Install Kubernetes on all nodes
> Run on: **Local Machine**

```bash
ansible k8s_cluster -i ansible/inventory/hosts.ini -m shell \
  -a "bash ~/install-k8s.sh" \
  --timeout=300
```

This will take approximately 5-10 minutes.

### Step 6 — Verify Kubernetes installation on all nodes
> Run on: **Local Machine**

Check versions:
```bash
ansible k8s_cluster -i ansible/inventory/hosts.ini -m shell \
  -a "kubeadm version && kubelet --version && kubectl version --client"
```

Check containerd is running:
```bash
ansible k8s_cluster -i ansible/inventory/hosts.ini -m shell \
  -a "sudo systemctl is-active containerd"
```

Expected output per node:
```
active
```

### Step 7 — Initialize cluster on CP-1 only
> Run on: **Local Machine**

```bash
ansible cp-1 -i ansible/inventory/hosts.ini -m shell \
  -a "bash ~/init-cluster.sh $NLB_DNS" \
  --timeout=300
```

### Step 8 — Generate join command
> Run on: **Local Machine**

```bash
ansible cp-1 -i ansible/inventory/hosts.ini -m shell \
  -a "kubeadm token create --print-join-command"
```

Copy the output — it will be used in the next step.

### Step 9 — Join worker nodes to the cluster
> Run on: **Local Machine**

Replace `<join-command>` with the output from Step 8:
```bash
ansible workers -i ansible/inventory/hosts.ini -m shell \
  -a "sudo <join-command>" \
  --timeout=120
```

Example:
```bash
ansible workers -i ansible/inventory/hosts.ini -m shell \
  -a "sudo kubeadm join <CP1_IP>:6443 --token <token> --discovery-token-ca-cert-hash sha256:<hash>" \
  --timeout=120
```

### Step 10 — Verify all nodes
> Run on: **Local Machine**

```bash
ansible cp-1 -i ansible/inventory/hosts.ini -m shell \
  -a "kubectl get nodes -o wide"
```

Expected output:
```
NAME               STATUS   ROLES           AGE   VERSION
k8s-lab-cp-1       Ready    control-plane   12m   v1.29.x
k8s-lab-worker-1   Ready    <none>          2m    v1.29.x
k8s-lab-worker-2   Ready    <none>          2m    v1.29.x
```

> Note: Node status may show `NotReady` for 1-2 minutes
> while Calico CNI is initializing. Wait and re-check.

---

## Troubleshooting

### ansible ping fails - Host key verification failed
```bash
# Add bastion to known_hosts first
ssh-keyscan -H $BASTION_IP >> ~/.ssh/known_hosts
```

### ansible ping fails - Connection closed by UNKNOWN port 65535
```bash
# Verify bastion:vars in hosts.ini has correct SSH args
cat ansible/inventory/hosts.ini

# Re-generate inventory
bash scripts/generate-inventory.sh
```

### join command file not found
```bash
# Generate join command manually from CP-1
ansible cp-1 -i ansible/inventory/hosts.ini -m shell \
  -a "kubeadm token create --print-join-command"
```

### Node stuck in NotReady
```bash
# Check Calico pods
ansible cp-1 -i ansible/inventory/hosts.ini -m shell \
  -a "kubectl get pods -n kube-system -l k8s-app=calico-node"

# Check kubelet logs on the affected node
ansible workers -i ansible/inventory/hosts.ini -m shell \
  -a "sudo journalctl -u kubelet --no-pager | tail -20"
```

### kubeadm init fails - reset and retry
```bash
ansible cp-1 -i ansible/inventory/hosts.ini -m shell \
  -a "sudo kubeadm reset -f && sudo rm -rf /etc/cni/net.d ~/.kube /etc/kubernetes"

ansible cp-1 -i ansible/inventory/hosts.ini -m shell \
  -a "bash ~/init-cluster.sh $NLB_DNS" \
  --timeout=300
```

### Join command expired (token valid for 24 hours)
```bash
# Generate a new join command from CP-1
ansible cp-1 -i ansible/inventory/hosts.ini -m shell \
  -a "kubeadm token create --print-join-command"
```
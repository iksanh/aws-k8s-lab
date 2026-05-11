#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# install-k8s.sh.tpl
# Base Kubernetes installation for Control Plane & Worker nodes
# Rendered by Terraform's templatefile() function
#
# Injected variables:
#   - k8s_version   : Kubernetes version (e.g. "1.29")
#   - node_hostname : Node hostname (e.g. "k8s-lab-cp-1")
# ═══════════════════════════════════════════════════════════════

set -e
set -o pipefail

# Redirect all output to log file for SSH debugging
exec > >(tee /var/log/k8s-install.log) 2>&1

# ─────────────────────────────────────────
# Variables (injected by Terraform)
# ─────────────────────────────────────────
K8S_VERSION="${k8s_version}"
NODE_HOSTNAME="${node_hostname}"

# ─────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

info()  { echo -e "$${GREEN}[INFO]$${NC} $1"; }
error() { echo -e "$${RED}[ERROR]$${NC} $1"; exit 1; }
step()  { echo -e "\n$${GREEN}━━━ $1 ━━━$${NC}"; }

info "Starting K8s base install on $${NODE_HOSTNAME} (K8s v$${K8S_VERSION})"

# ─────────────────────────────────────────
# STEP 0: Set hostname
# Useful for identifying nodes in `kubectl get nodes`
# ─────────────────────────────────────────
step "STEP 0: Set Hostname"
hostnamectl set-hostname "$${NODE_HOSTNAME}"
info "Hostname set to $${NODE_HOSTNAME}"

# ─────────────────────────────────────────
# STEP 1: Disable Swap
# Kubernetes does not support swap — the scheduler
# cannot calculate resources correctly with swap on
# ─────────────────────────────────────────
step "STEP 1: Disable Swap"
swapoff -a
sed -i '/swap/d' /etc/fstab
info "Swap disabled"

# ─────────────────────────────────────────
# STEP 2: Load Kernel Modules
#   overlay      → container filesystem driver
#   br_netfilter → bridge traffic inspected by iptables
#                  (required for kube-proxy)
# ─────────────────────────────────────────
step "STEP 2: Load Kernel Modules"
cat <<MODEOF | tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
MODEOF

modprobe overlay
modprobe br_netfilter
info "Modules loaded: overlay, br_netfilter"

# ─────────────────────────────────────────
# STEP 3: Configure Sysctl
#   bridge-nf-call-iptables → required for kube-proxy
#   ip_forward              → required for pod routing
# ─────────────────────────────────────────
step "STEP 3: Configure Sysctl"
cat <<SYSEOF | tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
SYSEOF

sysctl --system
info "Sysctl applied"

# ─────────────────────────────────────────
# STEP 4: Install containerd
# Container runtime used by Kubernetes, lighter than Docker
# ─────────────────────────────────────────
step "STEP 4: Install containerd"
apt-get update -y
apt-get install -y ca-certificates curl gnupg

install -m 0755 -d /etc/apt/keyrings

curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
  gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  tee /etc/apt/sources.list.d/docker.list

apt-get update -y
apt-get install -y containerd.io
info "containerd installed"

# ─────────────────────────────────────────
# STEP 5: Configure containerd
# SystemdCgroup = true → delegate cgroup management to systemd,
# preventing conflicts between two cgroup managers
# ─────────────────────────────────────────
step "STEP 5: Configure containerd"
rm -f /etc/containerd/config.toml
containerd config default | tee /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

systemctl restart containerd
systemctl enable containerd
info "containerd configured with SystemdCgroup=true"

# ─────────────────────────────────────────
# STEP 6: Install kubeadm, kubelet, kubectl
#   kubelet → agent running on every node
#   kubeadm → cluster bootstrap tool
#   kubectl → CLI to manage the cluster
# ─────────────────────────────────────────
step "STEP 6: Install kubeadm, kubelet, kubectl"
curl -fsSL https://pkgs.k8s.io/core:/stable:/v$${K8S_VERSION}/deb/Release.key | \
  gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v$${K8S_VERSION}/deb/ /" | \
  tee /etc/apt/sources.list.d/kubernetes.list

apt-get update -y
apt-get install -y kubelet kubeadm kubectl

# Hold versions to prevent accidental auto-upgrade
apt-mark hold kubelet kubeadm kubectl
systemctl enable kubelet
info "kubeadm, kubelet, kubectl installed and held"

# ─────────────────────────────────────────
# STEP 7: Verify installation
# ─────────────────────────────────────────
step "STEP 7: Verify Installation"
kubeadm version
kubelet --version
kubectl version --client



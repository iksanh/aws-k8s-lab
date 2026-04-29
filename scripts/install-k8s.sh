#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# install-k8s.sh
# Install Kubernetes dependencies on all nodes
# (Control Plane & Worker Nodes)
#
# Usage:
# chmod +x install-k8s.sh
# ./install-k8s.sh
# ═══════════════════════════════════════════════════════════════

set -e          # exit on error
set -o pipefail # exit on pipe error

# ─────────────────────────────────────────
# Variables
# ─────────────────────────────────────────
K8S_VERSION="1.29"

# ─────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
step()  { echo -e "\n${GREEN}━━━ $1 ━━━${NC}"; }

# ─────────────────────────────────────────
# STEP 1: Disable Swap
# Kubernetes does not support swap —
# the scheduler cannot calculate resources
# correctly when swap is active
# ─────────────────────────────────────────
step "STEP 1: Disable Swap"
info "Turning off swap..."
sudo swapoff -a
sudo sed -i '/swap/d' /etc/fstab
info "Swap status:"
free -h | grep Swap

# ─────────────────────────────────────────
# STEP 2: Load Kernel Modules
# overlay      → container filesystem driver
# br_netfilter → bridge traffic inspected
#                by iptables (required for kube-proxy)
# ─────────────────────────────────────────
step "STEP 2: Load Kernel Modules"
info "Writing modules config..."
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

info "Loading modules..."
sudo modprobe overlay
sudo modprobe br_netfilter

info "Verify modules:"
lsmod | grep -E "overlay|br_netfilter"

# ─────────────────────────────────────────
# STEP 3: Configure Sysctl
# net.bridge.bridge-nf-call-iptables → required for kube-proxy
# net.ipv4.ip_forward                → required for pod routing
# ─────────────────────────────────────────
step "STEP 3: Configure Sysctl"
info "Writing sysctl config..."
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

info "Applying sysctl..."
sudo sysctl --system | grep -E "ip_forward|bridge-nf"

# ─────────────────────────────────────────
# STEP 4: Install containerd
# Container runtime used by Kubernetes
# Lighter than Docker
# ─────────────────────────────────────────
step "STEP 4: Install containerd"
info "Updating package list..."
sudo apt-get update -y

info "Installing dependencies..."
sudo apt-get install -y ca-certificates curl gnupg

info "Creating keyrings directory..."
sudo install -m 0755 -d /etc/apt/keyrings

info "Downloading Docker GPG key..."
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
  sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

info "Adding Docker repository..."
echo "deb [arch=$(dpkg --print-architecture) \
  signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list

sudo apt-get update -y
sudo apt-get install -y containerd.io
info "containerd installed ✅"

# ─────────────────────────────────────────
# STEP 5: Configure containerd
# SystemdCgroup = true → delegate cgroup
# management to Systemd, prevents conflict
# between two cgroup managers
# ─────────────────────────────────────────
step "STEP 5: Configure containerd"
info "Removing old config..."
sudo rm -f /etc/containerd/config.toml

info "Generating default config..."
sudo containerd config default | sudo tee /etc/containerd/config.toml

info "Enabling SystemdCgroup..."
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' \
  /etc/containerd/config.toml

info "Verify SystemdCgroup:"
grep "SystemdCgroup" /etc/containerd/config.toml

info "Restarting containerd..."
sudo systemctl restart containerd
sudo systemctl enable containerd

info "containerd status:"
sudo systemctl is-active containerd

# ─────────────────────────────────────────
# STEP 6: Install kubeadm, kubelet, kubectl
# kubelet  → agent running on every node
# kubeadm  → cluster bootstrap tool
# kubectl  → CLI to manage the cluster
# ─────────────────────────────────────────
step "STEP 6: Install kubeadm, kubelet, kubectl"
info "Downloading Kubernetes GPG key..."
curl -fsSL https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key | \
  sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

info "Adding Kubernetes repository..."
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
  https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /" | \
  sudo tee /etc/apt/sources.list.d/kubernetes.list

sudo apt-get update -y

info "Installing kubelet, kubeadm, kubectl..."
sudo apt-get install -y kubelet kubeadm kubectl

info "Holding Kubernetes version to prevent auto-upgrade..."
sudo apt-mark hold kubelet kubeadm kubectl

info "Enabling kubelet..."
sudo systemctl enable kubelet

# ─────────────────────────────────────────
# STEP 7: Verify Installation
# ─────────────────────────────────────────
step "STEP 7: Verify Installation"
info "Checking versions:"
kubeadm version
kubelet --version
kubectl version --client

info "Checking containerd status:"
sudo systemctl is-active containerd

# ─────────────────────────────────────────
# DONE
# ─────────────────────────────────────────
echo -e "\n${GREEN}═══════════════════════════════════════════${NC}"
echo -e "${GREEN} ✅ Node is ready! Next steps:${NC}"
echo -e "${GREEN}═══════════════════════════════════════════${NC}"
echo ""
echo " For CONTROL PLANE:"
echo " ./init-cluster.sh <NLB_DNS>"
echo ""
echo " For WORKER NODES:"
echo " Run the join command from init-cluster.sh output"
echo ""
echo -e "${GREEN}═══════════════════════════════════════════${NC}"
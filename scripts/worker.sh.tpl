#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# worker.sh.tpl
# Bootstrap Kubernetes Worker Node
# Rendered by Terraform's templatefile() function
#
# This script runs the same base install as install-k8s.sh.tpl,
# then polls SSM Parameter Store for the join command pushed
# by the control plane, and joins the cluster.
#
# Injected variables:
#   - k8s_version    : Kubernetes version (e.g. "1.29")
#   - node_hostname  : Node hostname (e.g. "k8s-lab-worker-1")
#   - cluster_name   : Cluster name (SSM parameter prefix)
#   - aws_region     : AWS region for SSM
# ═══════════════════════════════════════════════════════════════

set -e
set -o pipefail

exec > >(tee /var/log/k8s-worker.log) 2>&1

# ─────────────────────────────────────────
# Variables (injected by Terraform)
# ─────────────────────────────────────────
K8S_VERSION="${k8s_version}"
NODE_HOSTNAME="${node_hostname}"
CLUSTER_NAME="${cluster_name}"
AWS_REGION="${aws_region}"

SSM_JOIN_WORKER="/$${CLUSTER_NAME}/join-command/worker"

# ─────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

info()  { echo -e "$${GREEN}[INFO]$${NC} $1"; }
error() { echo -e "$${RED}[ERROR]$${NC} $1"; exit 1; }
step()  { echo -e "\n$${GREEN}━━━ $1 ━━━$${NC}"; }

retry() {
  local max_attempts=$1
  local delay=$2
  shift 2
  local attempt=1

  until "$@"; do
    if [ $attempt -ge $max_attempts ]; then
      error "Command failed after $max_attempts attempts: $*"
    fi
    info "Attempt $attempt/$max_attempts failed, retrying in $${delay}s..."
    sleep $delay
    attempt=$((attempt + 1))
  done
}

info "Starting K8s Worker bootstrap on $${NODE_HOSTNAME}"

# ════════════════════════════════════════════════════════════════
# PHASE 1: Base K8s install (identical to master.sh.tpl PHASE 1)
# ════════════════════════════════════════════════════════════════

step "Wait for Network"
retry 30 5 curl -fsS --max-time 5 https://download.docker.com -o /dev/null

step "Set Hostname"
hostnamectl set-hostname "$${NODE_HOSTNAME}"

step "Disable Swap"
swapoff -a
sed -i '/swap/d' /etc/fstab

step "Load Kernel Modules"
cat <<MODEOF | tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
MODEOF
modprobe overlay
modprobe br_netfilter

step "Configure Sysctl"
cat <<SYSEOF | tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
SYSEOF
sysctl --system

step "Install containerd"
retry 5 10 apt-get update -y
retry 3 5  apt-get install -y ca-certificates curl gnupg unzip jq

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
  gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  tee /etc/apt/sources.list.d/docker.list

retry 5 10 apt-get update -y
retry 3 5  apt-get install -y containerd.io

step "Configure containerd"
rm -f /etc/containerd/config.toml
containerd config default | tee /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl restart containerd
systemctl enable containerd

step "Install kubeadm, kubelet, kubectl"
curl -fsSL https://pkgs.k8s.io/core:/stable:/v$${K8S_VERSION}/deb/Release.key | \
  gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v$${K8S_VERSION}/deb/ /" | \
  tee /etc/apt/sources.list.d/kubernetes.list

retry 5 10 apt-get update -y
retry 3 5  apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl
systemctl enable kubelet

step "Install AWS CLI v2"
cd /tmp
retry 3 10 curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip -q awscliv2.zip
./aws/install
rm -rf aws awscliv2.zip
cd -
aws --version

# ════════════════════════════════════════════════════════════════
# PHASE 2: Join cluster
#
#!/bin/bash
# ============================================================
# Bootstrap script: Kubernetes Worker Node
# OS: Ubuntu 22.04 LTS
# Runtime: containerd
# ============================================================

set -euo pipefail
LOG="/var/log/k8s-worker-init.log"
exec > >(tee -a "$LOG") 2>&1

echo "======================================================"
echo " [$(date)] Mulai bootstrap Worker Node"
echo "======================================================"

# ─────────────────────────────────────────
# 1. System prerequisites
# ─────────────────────────────────────────
echo "[STEP 1] Konfigurasi system prerequisites..."

swapoff -a
sed -i '/\bswap\b/d' /etc/fstab

cat <<EOF | tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

cat <<EOF | tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system

echo "[STEP 1] SELESAI"

# ─────────────────────────────────────────
# 2. Install containerd
# ─────────────────────────────────────────
echo "[STEP 2] Install containerd..."

apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg lsb-release

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" \
  | tee /etc/apt/sources.list.d/docker.list

apt-get update -qq
apt-get install -y -qq containerd.io

mkdir -p /etc/containerd
containerd config default | tee /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

systemctl restart containerd
systemctl enable containerd

echo "[STEP 2] containerd berjalan: $(systemctl is-active containerd)"

# ─────────────────────────────────────────
# 3. Install kubeadm, kubelet, kubectl
# ─────────────────────────────────────────
echo "[STEP 3] Install kubeadm, kubelet, kubectl v${k8s_version}..."

curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${k8s_version}/deb/Release.key" \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
  https://pkgs.k8s.io/core:/stable:/v${k8s_version}/deb/ /" \
  | tee /etc/apt/sources.list.d/kubernetes.list

apt-get update -qq
apt-get install -y -qq kubelet kubeadm kubectl

apt-mark hold kubelet kubeadm kubectl

systemctl enable kubelet

echo "[STEP 3] Versi terinstall:"
kubeadm version

# ─────────────────────────────────────────
# Setup alias untuk ubuntu user
# ─────────────────────────────────────────
cat <<'BASHRC' >> /home/ubuntu/.bashrc

# Kubernetes tools (kubectl tersedia setelah join cluster)
alias k=kubectl
alias kgp='kubectl get pods -A'
BASHRC

echo "======================================================"
echo " [$(date)] Worker Node bootstrap SELESAI!"
echo ""
echo " Node ini siap di-join ke cluster."
echo " Jalankan join command dari master:"
echo "   sudo kubeadm join <master-ip>:6443 --token ... --discovery-token-ca-cert-hash ..."
echo ""
echo " Cek log bootstrap: tail -f /var/log/k8s-worker-init.log"
echo "======================================================"

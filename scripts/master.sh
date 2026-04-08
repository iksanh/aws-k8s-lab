#!/bin/bash
# ============================================================
# Bootstrap script: Kubernetes Master Node
# OS: Ubuntu 22.04 LTS
# Runtime: containerd
# ============================================================

set -euo pipefail
LOG="/var/log/k8s-master-init.log"
exec > >(tee -a "$LOG") 2>&1

echo "======================================================"
echo " [$(date)] Mulai bootstrap Master Node"
echo "======================================================"

# ─────────────────────────────────────────
# 1. System prerequisites
# ─────────────────────────────────────────
echo "[STEP 1] Konfigurasi system prerequisites..."

# Disable swap — wajib untuk Kubernetes
swapoff -a
sed -i '/\bswap\b/d' /etc/fstab

# Load kernel modules yang dibutuhkan containerd
cat <<EOF | tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

# Konfigurasi sysctl untuk networking Kubernetes
cat <<EOF | tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system

echo "[STEP 1] SELESAI"

# ─────────────────────────────────────────
# 2. Install containerd (container runtime)
# ─────────────────────────────────────────
echo "[STEP 2] Install containerd..."

apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg lsb-release

# Docker repo (containerd diambil dari sini)
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

# Generate config containerd default, lalu aktifkan SystemdCgroup
mkdir -p /etc/containerd
containerd config default | tee /etc/containerd/config.toml
# Penting: Kubernetes butuh SystemdCgroup = true
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

# Pin version supaya tidak terupdate otomatis
apt-mark hold kubelet kubeadm kubectl

systemctl enable kubelet

echo "[STEP 3] Versi terinstall:"
kubeadm version
kubectl version --client

# ─────────────────────────────────────────
# 4. Initialize cluster dengan kubeadm
# ─────────────────────────────────────────
echo "[STEP 4] Inisialisasi Kubernetes cluster..."

MASTER_IP=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)

kubeadm init \
  --apiserver-advertise-address="$MASTER_IP" \
  --apiserver-cert-extra-sans="$MASTER_IP" \
  --pod-network-cidr="${pod_cidr}" \
  --node-name="${cluster_name}-master" \
  --skip-phases=addon/kube-proxy \
  2>&1 | tee /tmp/kubeadm-init.log

echo "[STEP 4] kubeadm init SELESAI"

# ─────────────────────────────────────────
# 5. Setup kubectl untuk user ubuntu
# ─────────────────────────────────────────
echo "[STEP 5] Konfigurasi kubectl untuk user ubuntu..."

mkdir -p /home/ubuntu/.kube
cp -i /etc/kubernetes/admin.conf /home/ubuntu/.kube/config
chown ubuntu:ubuntu /home/ubuntu/.kube/config

# Juga untuk root (opsional)
export KUBECONFIG=/etc/kubernetes/admin.conf

echo "[STEP 5] kubectl siap dipakai"

# ─────────────────────────────────────────
# 6. Install Flannel CNI (Pod networking)
# ─────────────────────────────────────────
echo "[STEP 6] Install Flannel CNI..."

# Jalankan sebagai ubuntu user supaya pakai kubeconfig yang benar
sudo -u ubuntu kubectl apply -f \
  https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml

echo "[STEP 6] Flannel CNI terinstall"

# ─────────────────────────────────────────
# 7. Simpan join command untuk worker nodes
# ─────────────────────────────────────────
echo "[STEP 7] Generate join command untuk worker nodes..."

kubeadm token create --print-join-command > /tmp/join-command.sh
chmod +x /tmp/join-command.sh

echo "======================================="
echo " JOIN COMMAND (jalankan di tiap worker):"
echo "======================================="
cat /tmp/join-command.sh
echo "======================================="

# ─────────────────────────────────────────
# 8. Tambahkan bash completion & alias
# ─────────────────────────────────────────
echo "[STEP 8] Setup kubectl completion & alias..."

cat <<'BASHRC' >> /home/ubuntu/.bashrc

# Kubernetes tools
source <(kubectl completion bash)
alias k=kubectl
complete -F __start_kubectl k
alias kgn='kubectl get nodes -o wide'
alias kgp='kubectl get pods -A'
alias kgs='kubectl get svc -A'
BASHRC

echo "======================================================"
echo " [$(date)] Master Node bootstrap SELESAI!"
echo ""
echo " Cek status nodes: kubectl get nodes"
echo " Join command ada di: cat /tmp/join-command.sh"
echo "======================================================"

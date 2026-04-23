#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# install-k8s.sh
# Install Kubernetes dependencies di semua node
# (Control Plane & Worker Nodes)
#
# Cara pakai:
# chmod +x install-k8s.sh
# ./install-k8s.sh
# ═══════════════════════════════════════════════════════════════

set -e          # stop kalau ada error
set -o pipefail # stop kalau ada error di pipe

# ─────────────────────────────────────────
# Variabel
# ─────────────────────────────────────────
K8S_VERSION="1.29"

# ─────────────────────────────────────────
# Helper
# ─────────────────────────────────────────
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
step()  { echo -e "\n${GREEN}━━━ $1 ━━━${NC}"; }

# ─────────────────────────────────────────
# Validasi: jangan jalankan sebagai root
# ─────────────────────────────────────────
if [ "$EUID" -eq 0 ]; then
  error "Jangan jalankan sebagai root. Pakai: ./install-k8s.sh"
fi

# ─────────────────────────────────────────
# STEP 1: Disable Swap
# K8s tidak support swap — scheduler tidak
# bisa kalkulasi resource dengan benar
# kalau swap aktif
# ─────────────────────────────────────────
step "STEP 1: Disable Swap"
info "Mematikan swap..."
sudo swapoff -a
sudo sed -i '/swap/d' /etc/fstab
info "Verifikasi swap:"
free -h | grep Swap

# ─────────────────────────────────────────
# STEP 2: Load Kernel Modules
# overlay     → filesystem driver container
# br_netfilter → traffic bridge diperiksa
#               iptables (wajib kube-proxy)
# ─────────────────────────────────────────
step "STEP 2: Load Kernel Modules"
info "Menulis konfigurasi modules..."
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

info "Loading modules..."
sudo modprobe overlay
sudo modprobe br_netfilter

info "Verifikasi modules:"
lsmod | grep -E "overlay|br_netfilter"

# ─────────────────────────────────────────
# STEP 3: Konfigurasi Sysctl
# net.bridge.bridge-nf-call-iptables  → wajib kube-proxy
# net.ipv4.ip_forward                 → wajib pod routing
# ─────────────────────────────────────────
step "STEP 3: Konfigurasi Sysctl"
info "Menulis konfigurasi sysctl..."
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

info "Apply sysctl..."
sudo sysctl --system | grep -E "ip_forward|bridge-nf"

# ─────────────────────────────────────────
# STEP 4: Install containerd
# Container runtime yang dipakai K8s
# Lebih ringan dari Docker
# ─────────────────────────────────────────
step "STEP 4: Install containerd"
info "Update package list..."
sudo apt-get update -y

info "Install dependencies..."
sudo apt-get install -y ca-certificates curl gnupg

info "Buat direktori keyrings..."
sudo install -m 0755 -d /etc/apt/keyrings

info "Download GPG key Docker..."
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
  sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

info "Tambah repository Docker..."
echo "deb [arch=$(dpkg --print-architecture) \
  signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list

sudo apt-get update -y
sudo apt-get install -y containerd.io
info "containerd terinstall ✅"

# ─────────────────────────────────────────
# STEP 5: Konfigurasi containerd
# SystemdCgroup = true → serahkan cgroup
# ke Systemd, mencegah konflik 2 manager
# ─────────────────────────────────────────
step "STEP 5: Konfigurasi containerd"
info "Hapus config lama..."
sudo rm -f /etc/containerd/config.toml

info "Generate config baru..."
sudo containerd config default | sudo tee /etc/containerd/config.toml

info "Enable SystemdCgroup..."
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' \
  /etc/containerd/config.toml

info "Verifikasi SystemdCgroup:"
grep "SystemdCgroup" /etc/containerd/config.toml

info "Restart containerd..."
sudo systemctl restart containerd
sudo systemctl enable containerd

info "Status containerd:"
sudo systemctl is-active containerd

# ─────────────────────────────────────────
# STEP 6: Install kubeadm, kubelet, kubectl
# kubelet  → agent di setiap node
# kubeadm  → tool bootstrap cluster
# kubectl  → CLI manage cluster
# ─────────────────────────────────────────
step "STEP 6: Install kubeadm, kubelet, kubectl"
info "Download GPG key Kubernetes..."
curl -fsSL https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key | \
  sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

info "Tambah repository Kubernetes..."
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
  https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /" | \
  sudo tee /etc/apt/sources.list.d/kubernetes.list

sudo apt-get update -y

info "Install kubelet, kubeadm, kubectl..."
sudo apt-get install -y kubelet kubeadm kubectl

info "Hold versi K8s agar tidak ter-upgrade otomatis..."
sudo apt-mark hold kubelet kubeadm kubectl

info "Enable kubelet..."
sudo systemctl enable kubelet

# ─────────────────────────────────────────
# STEP 7: Verifikasi
# ─────────────────────────────────────────
step "STEP 7: Verifikasi Instalasi"
info "Verifikasi versi:"
kubeadm version
kubelet --version
kubectl version --client

info "Verifikasi containerd:"
sudo systemctl is-active containerd

# ─────────────────────────────────────────
# SELESAI
# ─────────────────────────────────────────
echo -e "\n${GREEN}═══════════════════════════════════════════${NC}"
echo -e "${GREEN} ✅ Node siap! Langkah selanjutnya:${NC}"
echo -e "${GREEN}═══════════════════════════════════════════${NC}"
echo ""
echo " Untuk CONTROL PLANE:"
echo " ./init-cluster.sh"
echo ""
echo " Untuk WORKER NODE:"
echo " Jalankan join command dari output init-cluster.sh"
echo ""
echo -e "${GREEN}═══════════════════════════════════════════${NC}"
#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# init-cluster.sh
# Init Kubernetes Cluster di Control Plane
#
# Cara pakai:
# chmod +x init-cluster.sh
# ./init-cluster.sh
#
# PENTING: Jalankan HANYA di Control Plane node!
# ═══════════════════════════════════════════════════════════════

set -e
set -o pipefail

# ─────────────────────────────────────────
# Variabel — sesuaikan dengan output terraform
# ─────────────────────────────────────────
POD_CIDR="192.168.0.0/16"
NLB_DNS="k8s-lab-cp-nlb-dab37c7cd4138b9b.elb.us-east-1.amazonaws.com"

# ─────────────────────────────────────────
# Helper
# ─────────────────────────────────────────
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()    { echo -e "${GREEN}[INFO]${NC} $1"; }
warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
step()    { echo -e "\n${GREEN}━━━ $1 ━━━${NC}"; }

# ─────────────────────────────────────────
# Validasi: hanya di Control Plane
# ─────────────────────────────────────────
if [ "$EUID" -eq 0 ]; then
  error "Jangan jalankan sebagai root. Pakai: ./init-cluster.sh"
fi

# Ambil IP lokal node ini
LOCAL_IP=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)
info "IP lokal node ini: $LOCAL_IP"

# ─────────────────────────────────────────
# STEP 1: Cek apakah cluster sudah di-init
# ─────────────────────────────────────────
step "STEP 1: Cek status cluster"
if [ -f /etc/kubernetes/admin.conf ]; then
  warning "Cluster sudah di-init sebelumnya!"
  warning "Kalau mau init ulang, jalankan dulu:"
  warning "sudo kubeadm reset -f"
  warning "sudo rm -rf /etc/cni/net.d \$HOME/.kube /etc/kubernetes"
  exit 0
fi
info "Cluster belum di-init, lanjut..."

# ─────────────────────────────────────────
# STEP 2: Init cluster
# Pakai IP lokal dulu sebagai endpoint
# bukan NLB — karena saat init, API Server
# belum ready sehingga NLB belum bisa
# forward traffic (chicken & egg problem)
# ─────────────────────────────────────────
step "STEP 2: Init cluster dengan kubeadm"
info "Menjalankan kubeadm init..."
info "Control plane endpoint: $LOCAL_IP:6443"
info "Pod CIDR: $POD_CIDR"

sudo kubeadm init \
  --control-plane-endpoint="$LOCAL_IP:6443" \
  --pod-network-cidr="$POD_CIDR" \
  --upload-certs \
  --v=5

# ─────────────────────────────────────────
# STEP 3: Setup kubectl untuk user ubuntu
# admin.conf berisi credentials untuk
# akses cluster sebagai admin
# ─────────────────────────────────────────
step "STEP 3: Setup kubectl"
info "Buat direktori .kube..."
mkdir -p $HOME/.kube

info "Copy admin.conf..."
sudo cp /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

info "Verifikasi kubectl:"
kubectl get nodes

# ─────────────────────────────────────────
# STEP 4: Install Calico CNI
# Container Network Interface — tanpa ini
# pod tidak bisa konek satu sama lain
# Node status akan NotReady tanpa CNI
# ─────────────────────────────────────────
step "STEP 4: Install Calico CNI"
info "Apply Calico manifest..."
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/calico.yaml

info "Tunggu Calico pods running (maks 2 menit)..."
kubectl wait --for=condition=ready pod \
  -l k8s-app=calico-node \
  -n kube-system \
  --timeout=120s

# ─────────────────────────────────────────
# STEP 5: Update kubeconfig pakai NLB
# Setelah cluster running, ganti endpoint
# dari IP lokal ke NLB DNS
# Worker akan join via NLB
# ─────────────────────────────────────────
step "STEP 5: Update endpoint ke NLB"
info "Ganti endpoint ke NLB DNS..."
sudo sed -i "s|$LOCAL_IP:6443|$NLB_DNS:6443|g" \
  /etc/kubernetes/admin.conf

sudo sed -i "s|$LOCAL_IP:6443|$NLB_DNS:6443|g" \
  $HOME/.kube/config

info "Verifikasi endpoint baru:"
grep "server:" $HOME/.kube/config

# ─────────────────────────────────────────
# STEP 6: Generate join command untuk Worker
# Token valid 24 jam
# ─────────────────────────────────────────
step "STEP 6: Generate join command"
info "Generate join command..."
JOIN_COMMAND=$(kubeadm token create --print-join-command)

info "Simpan join command ke file..."
echo "$JOIN_COMMAND" > /tmp/join-command.sh
chmod +x /tmp/join-command.sh

# ─────────────────────────────────────────
# SELESAI
# ─────────────────────────────────────────
echo -e "\n${GREEN}═══════════════════════════════════════════${NC}"
echo -e "${GREEN} ✅ Cluster siap!${NC}"
echo -e "${GREEN}═══════════════════════════════════════════${NC}"
echo ""
echo " Join command untuk Worker Node:"
echo " ─────────────────────────────────────────"
echo " $JOIN_COMMAND"
echo " ─────────────────────────────────────────"
echo ""
echo " Simpan join command di atas!"
echo " Jalankan di setiap Worker Node dengan prefix: sudo"
echo ""
echo " Verifikasi cluster:"
echo " kubectl get nodes -o wide"
echo ""
echo -e "${GREEN}═══════════════════════════════════════════${NC}"
#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# init-cluster.sh
# Initialize Kubernetes Cluster on Control Plane node
#
# Usage:
# chmod +x init-cluster.sh
# ./init-cluster.sh <NLB_DNS>
#
# Example:
# ./init-cluster.sh k8s-lab-cp-nlb-xxx.elb.us-east-1.amazonaws.com
#
# IMPORTANT: Run ONLY on the Control Plane node!
# ═══════════════════════════════════════════════════════════════

set -e
set -o pipefail

# ─────────────────────────────────────────
# Variables
# ─────────────────────────────────────────
POD_CIDR="192.168.0.0/16"

# NLB DNS is passed as argument — avoids hardcoding
# and works across multiple terraform apply cycles
NLB_DNS="${1:?Error: NLB DNS is required. Usage: ./init-cluster.sh <NLB_DNS>}"

# ─────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()    { echo -e "${GREEN}[INFO]${NC} $1"; }
warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
step()    { echo -e "\n${GREEN}━━━ $1 ━━━${NC}"; }

# Fetch local IP from AWS instance metadata
LOCAL_IP=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)
info "Local IP of this node: $LOCAL_IP"
info "NLB DNS: $NLB_DNS"

# ─────────────────────────────────────────
# STEP 1: Check if cluster is already initialized
# ─────────────────────────────────────────
step "STEP 1: Check cluster status"
if [ -f /etc/kubernetes/admin.conf ]; then
  warning "Cluster was already initialized!"
  warning "To re-initialize, run:"
  warning "sudo kubeadm reset -f"
  warning "sudo rm -rf /etc/cni/net.d \$HOME/.kube /etc/kubernetes"
  exit 0
fi
info "Cluster not initialized yet, proceeding..."

# ─────────────────────────────────────────
# STEP 2: Initialize cluster
# Use local IP as endpoint first — not NLB
# because during init, the API Server is not
# ready yet so NLB cannot forward traffic
# (chicken & egg problem)
# ─────────────────────────────────────────
step "STEP 2: Initialize cluster with kubeadm"
info "Running kubeadm init..."
info "Control plane endpoint: $LOCAL_IP:6443"
info "Pod CIDR: $POD_CIDR"

sudo kubeadm init \
  --control-plane-endpoint="$LOCAL_IP:6443" \
  --pod-network-cidr="$POD_CIDR" \
  --upload-certs \
  --v=5

# ─────────────────────────────────────────
# STEP 3: Setup kubectl for ubuntu user
# admin.conf contains credentials to
# access the cluster as admin
# ─────────────────────────────────────────
step "STEP 3: Setup kubectl"
info "Creating .kube directory..."
mkdir -p $HOME/.kube

info "Copying admin.conf..."
sudo cp /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

info "Verifying kubectl:"
kubectl get nodes

# ─────────────────────────────────────────
# STEP 4: Install Calico CNI
# Container Network Interface — without this
# pods cannot communicate with each other
# Node status will remain NotReady without CNI
# ─────────────────────────────────────────
step "STEP 4: Install Calico CNI"
info "Applying Calico manifest..."
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/calico.yaml

info "Waiting for Calico pods to be ready (max 2 minutes)..."
kubectl wait --for=condition=ready pod \
  -l k8s-app=calico-node \
  -n kube-system \
  --timeout=120s

# ─────────────────────────────────────────
# STEP 5: Update kubeconfig to use NLB
# Once cluster is running, replace the endpoint
# from local IP to NLB DNS so workers
# can join via NLB
# ─────────────────────────────────────────
step "STEP 5: Update endpoint to NLB"
info "Replacing endpoint with NLB DNS..."
sudo sed -i "s|$LOCAL_IP:6443|$NLB_DNS:6443|g" \
  /etc/kubernetes/admin.conf

sudo sed -i "s|$LOCAL_IP:6443|$NLB_DNS:6443|g" \
  $HOME/.kube/config

info "Verify new endpoint:"
grep "server:" $HOME/.kube/config

# ─────────────────────────────────────────
# STEP 6: Generate join command for Workers
# Token is valid for 24 hours
# ─────────────────────────────────────────
step "STEP 6: Generate join command"
info "Generating join command..."
JOIN_COMMAND=$(kubeadm token create --print-join-command)

info "Saving join command to file..."
echo "sudo $JOIN_COMMAND" > /tmp/join-command.sh
chmod +x /tmp/join-command.sh

# ─────────────────────────────────────────
# DONE
# ─────────────────────────────────────────
echo -e "\n${GREEN}═══════════════════════════════════════════${NC}"
echo -e "${GREEN} ✅ Cluster is ready!${NC}"
echo -e "${GREEN}═══════════════════════════════════════════${NC}"
echo ""
echo " Join command for Worker Nodes:"
echo " ─────────────────────────────────────────"
echo " $JOIN_COMMAND"
echo " ─────────────────────────────────────────"
echo ""
echo " Run the command above on each Worker Node with sudo prefix"
echo ""
echo " Verify cluster:"
echo " kubectl get nodes -o wide"
echo ""
echo -e "${GREEN}═══════════════════════════════════════════${NC}"
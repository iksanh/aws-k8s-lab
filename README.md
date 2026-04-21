# 🏗️ K8s Lab — Self-Managed Kubernetes di AWS

Lab infrastruktur Kubernetes di AWS menggunakan Terraform.  
Dibangun dari nol untuk memahami networking, security, dan K8s secara mendalam.

> **Lab environment:** KodeKloud | **OS:** Ubuntu 22.04 | **Runtime:** containerd | **CNI:** Calico

---

## 📐 Arsitektur
Internet
│
├──[port 22]────► Bastion Host (Public Subnet)
└──[port 80]────► ALB (Public Subnet)
│ NodePort 30080
▼
Worker Nodes (Private Subnet)
│ port 6443
▼
NLB Internal
│
▼
Control Plane (Private Subnet)
│ port 3306
▼
RDS MySQL (Private Subnet)

---

## 🖥️ Spesifikasi Infrastruktur

| Resource        | Type        | vCPU | RAM  | Storage |
|----------------|-------------|------|------|---------|
| Bastion         | t3.micro    | 2    | 1GB  | 10GB    |
| Control Plane   | t3.medium   | 2    | 4GB  | 30GB    |
| Worker Node × 2 | t3.medium   | 2    | 4GB  | 30GB    |
| RDS MySQL       | db.t3.micro | -    | -    | 20GB    |

**Total: 8 vCPU, 13GB RAM, 4 instances**

---

## 📁 Struktur File

setup_k8s_aws/
├── main.tf              # VPC, subnet, IGW, NAT, route tables
├── security_groups.tf   # 5 SG per tier + cross-reference rules
├── ec2.tf               # Bastion, Control Plane, Worker nodes
├── alb.tf               # ALB (external) + NLB (internal K8s API)
├── rds.tf               # RDS MySQL 8.0
├── variables.tf         # Semua variabel dengan validasi
├── outputs.tf           # IP, DNS, SSH commands
├── terraform.tfvars     # Secret values — JANGAN di-commit!
└── scripts/
├── master.sh        # Bootstrap CP (otomasi fase berikutnya)
└── worker.sh        # Bootstrap Worker (otomasi fase berikutnya)

---

## 🚀 Deploy Infrastruktur

### Prerequisites

```bash
# Pastikan tools tersedia
terraform version    # >= 1.6.0
aws sts get-caller-identity

# Generate SSH key kalau belum ada
ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -N ""
```

### Deploy

```bash
# Buat file secret
echo 'db_password = "YourPasswordHere!"' > terraform.tfvars

# Deploy
terraform init
terraform plan
terraform apply
```

### Lihat Output

```bash
terraform output
```

---

## ⚙️ Install Kubernetes (Manual)

> Install manual agar memahami setiap langkah.
> Jalankan **Step 1 dan Step 2 di semua node** (CP + Worker).

### Step 1 — SSH ke Setiap Node via Bastion

```bash
# Ambil IP dari terraform output
terraform output

# CP-1 (Terminal 1)
ssh -J ubuntu@<bastion-ip> ubuntu@<cp-1-ip>

# Worker-1 (Terminal 2)
ssh -J ubuntu@<bastion-ip> ubuntu@<worker-1-ip>

# Worker-2 (Terminal 3)
ssh -J ubuntu@<bastion-ip> ubuntu@<worker-2-ip>
```

### Step 2 — Install di Semua Node (CP + Worker)

```bash
# Disable swap
sudo swapoff -a
sudo sed -i '/swap/d' /etc/fstab

# Kernel modules
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
sudo modprobe overlay
sudo modprobe br_netfilter

# Sysctl
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system

# Install containerd
sudo apt-get update -y
sudo apt-get install -y ca-certificates curl gnupg
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
  sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) \
  signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list
sudo apt-get update -y
sudo apt-get install -y containerd.io
containerd config default | sudo tee /etc/containerd/config.toml
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' \
  /etc/containerd/config.toml
sudo systemctl restart containerd
sudo systemctl enable containerd

# Install kubeadm, kubelet, kubectl
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.29/deb/Release.key | \
  sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
  https://pkgs.k8s.io/core:/stable:/v1.29/deb/ /" | \
  sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update -y
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
```

### Step 3 — Init Cluster di CP-1

```bash
# Ganti <nlb-dns> dengan nilai dari: terraform output nlb_dns
sudo kubeadm init \
  --control-plane-endpoint="<nlb-dns>:6443" \
  --pod-network-cidr="192.168.0.0/16" \
  --upload-certs

# Setup kubectl
mkdir -p $HOME/.kube
sudo cp /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

### Step 4 — Install Calico CNI

```bash
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/calico.yaml

# Tunggu semua pod Running
kubectl get pods -n kube-system -w
```

### Step 5 — Join Worker Nodes

```bash
# Copy join command dari output kubeadm init tadi
# Jalankan di Worker-1 dan Worker-2

sudo kubeadm join <nlb-dns>:6443 \
  --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash>
```

### Step 6 — Verifikasi Cluster

```bash
kubectl get nodes -o wide
```

Output yang diharapkan:
NAME              STATUS   ROLES           AGE   VERSION
k8s-lab-cp-1      Ready    control-plane   5m    v1.29.x
k8s-lab-worker-1  Ready    <none>          2m    v1.29.x
k8s-lab-worker-2  Ready    <none>          2m    v1.29.x

---

## 🌐 Deploy WordPress

```bash
kubectl apply -f wordpress.yaml

# Cek status
kubectl get pods -o wide
kubectl get svc

# Akses via ALB
# http://<alb-dns>
```

---

## 🔧 Troubleshooting

**Node belum Ready:**
```bash
kubectl describe node <nama-node>
```

**Pod tidak jalan:**
```bash
kubectl describe pod <nama-pod>
kubectl logs <nama-pod>
```

**Reset kubeadm (kalau gagal init/join):**
```bash
sudo kubeadm reset -f
sudo rm -rf /etc/cni/net.d $HOME/.kube
```

---

## 💡 Pelajaran Penting

### Kenapa Custom VPC?
Default VPC semua subnet-nya public — tidak aman untuk cluster K8s.
Custom VPC memberi kontrol penuh atas networking dan isolasi.

### Kenapa Bastion Host?
Satu-satunya pintu masuk SSH dari internet.
CP dan Worker tidak punya public IP — hanya bisa diakses via Bastion.

### Kenapa NLB untuk K8s API?
Port 6443 adalah raw TCP — ALB (L7/HTTP) tidak bisa handle ini.
NLB (L4/TCP) yang tepat untuk forward ke K8s API Server.

### Kenapa etcd harus angka ganjil?
etcd butuh quorum majority (n/2 + 1).
2 node = toleransi 0 failure. 3 node = toleransi 1 failure.

---

## ⚠️ Catatan KodeKloud Lab
Limitasi akun:
├── Max 2 vCPU per instance
├── Max 10 vCPU total
├── Max 10 instances
├── Tidak support rds:CreateDBParameterGroup
└── Tidak support iam:CreateRole
Penyesuaian dari arsitektur ideal:
├── CP: 3 node → 1 node (vCPU limit)
└── Worker: 3 node → 2 node (vCPU limit

---

## 🗑️ Destroy

```bash
# Hapus semua resource setelah selesai belajar
terraform destroy
```

> ⚠️ Pastikan tidak ada data penting sebelum destroy!
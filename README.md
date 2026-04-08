# Kubernetes Lab di EC2 — Dari Nol dengan Terraform

Cluster: 1 Master + 2 Worker | OS: Ubuntu 22.04 | Runtime: containerd | CNI: Flannel

---

## Struktur file

```
k8s-terraform/
├── main.tf           # Resource AWS (EC2, SG, Key Pair)
├── variables.tf      # Konfigurasi yang bisa diubah
├── outputs.tf        # Output IP dan SSH command
└── scripts/
    ├── master.sh     # Bootstrap master node (otomatis via user_data)
    └── worker.sh     # Bootstrap worker nodes (otomatis via user_data)
```

---

## Langkah 1 — Persiapan di mesin lokal / Cloud Shell KodeKloud

```bash
# 1a. Generate SSH key pair (kalau belum punya)
ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -N ""

# 1b. Pastikan Terraform sudah terinstall
terraform version

# 1c. Pastikan AWS CLI sudah terkonfigurasi
aws sts get-caller-identity
```

---

## Langkah 2 — Deploy infrastruktur

```bash
# Clone / masuk ke direktori terraform
cd k8s-terraform/

# Inisialisasi Terraform (download provider)
terraform init

# Preview apa yang akan dibuat
terraform plan

# Deploy! (akan membuat 3 EC2 instance)
terraform apply -auto-approve
```

Output akan menampilkan IP semua node dan SSH command.

---

## Langkah 3 — Tunggu bootstrap selesai (~5 menit)

Bootstrap master node otomatis berjalan via `user_data`.
Pantau progresnya:

```bash
# SSH ke master
ssh -i ~/.ssh/id_rsa ubuntu@<MASTER_PUBLIC_IP>

# Pantau log bootstrap
tail -f /var/log/k8s-master-init.log

# Tunggu sampai muncul: "Master Node bootstrap SELESAI!"
```

---

## Langkah 4 — Join worker nodes ke cluster

```bash
# Di master: ambil join command
cat /tmp/join-command.sh
# Output contoh:
# kubeadm join 10.0.1.50:6443 --token abc123... --discovery-token-ca-cert-hash sha256:xyz...

# Buka terminal baru, SSH ke worker-1
ssh -i ~/.ssh/id_rsa ubuntu@<WORKER_1_PUBLIC_IP>
sudo bash -c "$(cat /tmp/join-command.sh)"   # paste join command dari master
# Tunggu: "This node has joined the cluster"

# SSH ke worker-2
ssh -i ~/.ssh/id_rsa ubuntu@<WORKER_2_PUBLIC_IP>
sudo bash -c "$(cat /tmp/join-command.sh)"   # sama, jalankan join command
```

---

## Langkah 5 — Verifikasi cluster

```bash
# Kembali ke master
kubectl get nodes -o wide
# Semua node harus STATUS: Ready

kubectl get pods -A
# Pastikan semua pod Running, termasuk flannel dan coredns
```

Output yang diharapkan:
```
NAME              STATUS   ROLES           AGE   VERSION
k8s-lab-master    Ready    control-plane   10m   v1.30.x
k8s-lab-worker-1  Ready    <none>          5m    v1.30.x
k8s-lab-worker-2  Ready    <none>          5m    v1.30.x
```

---

## Langkah 6 — Deploy aplikasi pertamamu!

```bash
# Deploy nginx sebagai test
kubectl create deployment nginx --image=nginx --replicas=2

# Expose via NodePort
kubectl expose deployment nginx --type=NodePort --port=80

# Cek service (lihat PORT yang di-assign)
kubectl get svc nginx

# Akses dari browser:
# http://<WORKER_PUBLIC_IP>:<NODEPORT>
```

---

## Variabel yang bisa dikustomisasi

Edit `variables.tf` atau pass via `-var`:

```bash
# Contoh: ganti region dan instance type
terraform apply \
  -var="region=ap-southeast-1" \
  -var="master_instance_type=t3.large" \
  -var="worker_count=3"
```

---

## Troubleshooting umum

**Node belum Ready setelah join:**
```bash
kubectl describe node <nama-node>
# Lihat bagian Events dan Conditions
```

**Pod CNI tidak jalan:**
```bash
kubectl get pods -n kube-flannel
kubectl logs -n kube-flannel <pod-name>
```

**Bootstrap master gagal:**
```bash
# Di master node
cat /var/log/k8s-master-init.log
cat /tmp/kubeadm-init.log
```

**Reset dan coba lagi:**
```bash
sudo kubeadm reset -f
sudo rm -rf /etc/cni/net.d /home/ubuntu/.kube
# Lalu jalankan ulang bootstrap
```

---

## Bersihkan setelah selesai belajar

```bash
# Hapus semua resource AWS (hindari biaya)
terraform destroy -auto-approve
```

output "master_public_ip" {
  description = "IP publik master node — pakai ini untuk SSH dan kubectl"
  value       = aws_instance.master.public_ip
}

output "master_private_ip" {
  description = "IP private master node (dipakai worker untuk join cluster)"
  value       = aws_instance.master.private_ip
}

output "worker_public_ips" {
  description = "IP publik semua worker node"
  value       = aws_instance.worker[*].public_ip
}

output "worker_private_ips" {
  description = "IP private semua worker node"
  value       = aws_instance.worker[*].private_ip
}

output "ssh_master" {
  description = "Command SSH ke master node"
  value       = "ssh -i ~/.ssh/id_rsa ubuntu@${aws_instance.master.public_ip}"
}

output "ssh_workers" {
  description = "Command SSH ke setiap worker node"
  value = [
    for idx, ip in aws_instance.worker[*].public_ip :
    "ssh -i ~/.ssh/id_rsa ubuntu@${ip}  # worker-${idx + 1}"
  ]
}

# Output untuk mendapatkan alamat database setelah jadi
output "rds_endpoint" {
  value = aws_db_instance.wordpress_db.endpoint
}

output "next_steps" {
  description = "Langkah selanjutnya setelah terraform apply"
  value = <<-EOT

    ============================================================
    CLUSTER SETUP SEDANG BERJALAN (tunggu ~5 menit)
    ============================================================

    1. SSH ke master dan cek status bootstrap:
       ssh -i ~/.ssh/id_rsa ubuntu@${aws_instance.master.public_ip}
       tail -f /var/log/k8s-master-init.log

    2. Setelah selesai, ambil join command:
       cat /tmp/join-command.sh

    3. SSH ke tiap worker dan jalankan join command tersebut:
       ssh -i ~/.ssh/id_rsa ubuntu@${aws_instance.worker[0].public_ip}
       sudo bash /tmp/join-command.sh    # paste join command dari step 2

    4. Kembali ke master, verifikasi node sudah join:
       kubectl get nodes -o wide

    ============================================================
  EOT
}

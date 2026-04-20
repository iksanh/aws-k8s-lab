# ─────────────────────────────────────────
# Networking
# ─────────────────────────────────────────
output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "nat_gateway_ip" {
  description = "IP publik NAT Gateway"
  value       = aws_eip.nat.public_ip
}


# ─────────────────────────────────────────
# Bastion
# ─────────────────────────────────────────
output "bastion_public_ip" {
  description = "IP publik Bastion Host"
  value       = aws_eip.bastion.public_ip
}

output "bastion_ssh" {
  description = "Command SSH ke Bastion"
  value       = "ssh -i ~/.ssh/id_rsa ubuntu@${aws_eip.bastion.public_ip}"
}

# ─────────────────────────────────────────
# Control Plane
# ─────────────────────────────────────────
output "control_plane_private_ips" {
  description = "Private IP semua Control Plane nodes"
  value       = aws_instance.control_plane[*].private_ip
}

output "ssh_cp1" {
  description = "Command SSH ke CP-1 via Bastion"
  value       = "ssh -J ubuntu@${aws_eip.bastion.public_ip} ubuntu@${aws_instance.control_plane[0].private_ip}"
}

# ─────────────────────────────────────────
# Worker Nodes
# ─────────────────────────────────────────
output "worker_private_ips" {
  description = "Private IP semua Worker nodes"
  value       = aws_instance.worker[*].private_ip
}


# ─────────────────────────────────────────
# ALB & NLB
# ─────────────────────────────────────────
output "alb_dns" {
  description = "DNS ALB — akses aplikasi via ini"
  value       = aws_lb.main.dns_name
}

output "nlb_dns" {
  description = "DNS NLB internal — endpoint K8s API Server"
  value       = aws_lb.control_plane.dns_name
}

# ─────────────────────────────────────────
# RDS
# ─────────────────────────────────────────
output "rds_endpoint" {
  description = "RDS endpoint — pakai ini di konfigurasi WordPress"
  value       = aws_db_instance.main.endpoint
  sensitive   = true
}

output "rds_db_name" {
  description = "Nama database RDS"
  value       = aws_db_instance.main.db_name
}


# ─────────────────────────────────────────
# Next Steps
# ─────────────────────────────────────────
output "next_steps" {
  description = "Langkah setelah terraform apply"
  value = <<-EOT

    ============================================================
    INFRASTRUKTUR SIAP — LANGKAH SELANJUTNYA
    ============================================================

    1. SSH ke CP-1 via Bastion:
       ssh -J ubuntu@${aws_eip.bastion.public_ip} ubuntu@${aws_instance.control_plane[0].private_ip}

    2. Install kubeadm, kubelet, kubectl di semua node

    3. Init cluster di CP-1:
       sudo kubeadm init --control-plane-endpoint="${aws_lb.control_plane.dns_name}:6443" --upload-certs

    4. Join CP-2 dan CP-3 sebagai control plane

    5. Join Worker-1, Worker-2, Worker-3

    6. Verifikasi:
       kubectl get nodes -o wide

    7. Akses aplikasi via ALB:
       http://${aws_lb.main.dns_name}
    ============================================================
  EOT
}
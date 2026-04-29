# ─────────────────────────────────────────
# Networking
# ─────────────────────────────────────────
output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "nat_gateway_ip" {
  description = "NAT Gateway public IP"
  value       = aws_eip.nat.public_ip
}


# ─────────────────────────────────────────
# Bastion
# ─────────────────────────────────────────
output "bastion_public_ip" {
  description = "Bastion host public IP"
  value       = aws_eip.bastion.public_ip
}

output "bastion_ssh" {
  description = "SSH command to Bastion"
  value       = "ssh -i ~/.ssh/id_rsa ubuntu@${aws_eip.bastion.public_ip}"
}

# ─────────────────────────────────────────
# Control Plane
# ─────────────────────────────────────────
output "control_plane_private_ips" {
  description = "Private IPs of all Control Plane nodes"
  value       = aws_instance.control_plane[*].private_ip
}

output "ssh_cp1" {
  description = "SSH command to CP-1 via Bastion"
  value       = "ssh -J ubuntu@${aws_eip.bastion.public_ip} ubuntu@${aws_instance.control_plane[0].private_ip}"
}

# ─────────────────────────────────────────
# Worker Nodes
# ─────────────────────────────────────────
output "worker_private_ips" {
  description = "Private IPs of all Worker nodes"
  value       = aws_instance.worker[*].private_ip
}


# ─────────────────────────────────────────
# ALB & NLB
# ─────────────────────────────────────────
output "alb_dns" {
  description = "ALB DNS — access application via this endpoint"
  value       = aws_lb.main.dns_name
}

output "nlb_dns" {
  description = "NLB DNS — Kubernetes API Server endpoint"
  value       = aws_lb.control_plane.dns_name
}

# ─────────────────────────────────────────
# RDS
# ─────────────────────────────────────────
output "rds_endpoint" {
  description = "RDS endpoint — use this in WordPress configuration"
  value       = aws_db_instance.main.endpoint
  sensitive   = true
}

output "rds_db_name" {
  description = "RDS database name"
  value       = aws_db_instance.main.db_name
}

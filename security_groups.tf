# ─────────────────────────────────────────
# SG Bastion
# Satu-satunya yang terima SSH dari internet
# Semua node lain hanya terima SSH dari SG ini
# ─────────────────────────────────────────

resource "aws_security_group" "bastion" {

  name        = "${var.cluster_name}-sg-bastion"
  description = "Bastion host — SSH entry point"
  vpc_id      = aws_vpc.main.id
  ingress {
    description = "SSH dari IP yang diizinkan"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.allowed_ssh_cidrs
  }

  egress {
    description = "Semua outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.cluster_name}-sg-bastion"
  }
}

# ─────────────────────────────────────────
# SG ALB
# Terima HTTP/HTTPS dari internet
# Forward ke worker NodePort
# ─────────────────────────────────────────
resource "aws_security_group" "alb" {
  name        = "${var.cluster_name}-sg-alb"
  description = "ALB — HTTP/HTTPS dari internet"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP dari internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS dari internet"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Forward ke worker nodes"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = {
    Name = "${var.cluster_name}-sg-alb"
  }
}

# ─────────────────────────────────────────
# SG Control Plane
# Paling ketat — otak cluster
# ─────────────────────────────────────────
resource "aws_security_group" "control_plane" {
  name        = "${var.cluster_name}-sg-cp"
  description = "Kubernetes Control Plane nodes"
  vpc_id      = aws_vpc.main.id

  # SSH hanya dari Bastion
  ingress {
    description     = "SSH dari Bastion"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.bastion.id]
  }

  # K8s API — dari Worker & Bastion (kubectl via tunnel)
  ingress {
    description     = "K8s API Server"
    from_port       = 6443
    to_port         = 6443
    protocol        = "tcp"
    security_groups = [aws_security_group.worker.id, aws_security_group.bastion.id]
  }

  # etcd — hanya sesama Control Plane
  ingress {
    description = "etcd peer — hanya sesama CP"
    from_port   = 2379
    to_port     = 2380
    protocol    = "tcp"
    self        = true
  }

  # Kubelet — antar sesama CP
  ingress {
    description = "Kubelet API"
    from_port   = 10250
    to_port     = 10250
    protocol    = "tcp"
    self        = true
  }

  # Internal traffic dari Worker
  ingress {
    description     = "Traffic dari Worker nodes"
    from_port       = 0
    to_port         = 0
    protocol        = "-1"
    security_groups = [aws_security_group.worker.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.cluster_name}-sg-cp"
  }
}
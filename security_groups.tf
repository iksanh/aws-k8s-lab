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
# SG Control Plane — tanpa cross-reference dulu
# ─────────────────────────────────────────
resource "aws_security_group" "control_plane" {
  name        = "${var.cluster_name}-sg-cp"
  description = "Kubernetes Control Plane nodes"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "SSH dari Bastion"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.bastion.id]
  }

  ingress {
    description = "etcd peer — hanya sesama CP"
    from_port   = 2379
    to_port     = 2380
    protocol    = "tcp"
    self        = true
  }

  ingress {
    description = "Kubelet API antar CP"
    from_port   = 10250
    to_port     = 10250
    protocol    = "tcp"
    self        = true
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

# ─────────────────────────────────────────
# SG Worker — tanpa cross-reference dulu
# ─────────────────────────────────────────
resource "aws_security_group" "worker" {
  name        = "${var.cluster_name}-sg-worker"
  description = "Kubernetes Worker Nodes"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "SSH dari Bastion"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.bastion.id]
  }

  ingress {
    description     = "NodePort dari ALB"
    from_port       = 30000
    to_port         = 32767
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  ingress {
    description = "Internal traffic antar worker"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.cluster_name}-sg-worker"
  }
}

# ─────────────────────────────────────────
# SG Rules — cross-reference antara CP & Worker
# Dipisah agar tidak cycle
# Kedua SG sudah exist dulu, baru rules ini dibuat
# ─────────────────────────────────────────

# CP terima API Server dari Worker & Bastion
resource "aws_security_group_rule" "cp_from_worker_api" {
  type                     = "ingress"
  from_port                = 6443
  to_port                  = 6443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.control_plane.id
  source_security_group_id = aws_security_group.worker.id
  description              = "K8s API dari Worker"
}

resource "aws_security_group_rule" "cp_from_bastion_api" {
  type                     = "ingress"
  from_port                = 6443
  to_port                  = 6443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.control_plane.id
  source_security_group_id = aws_security_group.bastion.id
  description              = "K8s API dari Bastion (kubectl tunnel)"
}

resource "aws_security_group_rule" "cp_from_worker_all" {
  type                     = "ingress"
  from_port                = 0
  to_port                  = 0
  protocol                 = "-1"
  security_group_id        = aws_security_group.control_plane.id
  source_security_group_id = aws_security_group.worker.id
  description              = "Semua traffic dari Worker"
}

# Worker terima dari Control Plane
resource "aws_security_group_rule" "worker_from_cp_kubelet" {
  type                     = "ingress"
  from_port                = 10250
  to_port                  = 10250
  protocol                 = "tcp"
  security_group_id        = aws_security_group.worker.id
  source_security_group_id = aws_security_group.control_plane.id
  description              = "Kubelet dari Control Plane"
}

resource "aws_security_group_rule" "worker_from_cp_all" {
  type                     = "ingress"
  from_port                = 0
  to_port                  = 0
  protocol                 = "-1"
  security_group_id        = aws_security_group.worker.id
  source_security_group_id = aws_security_group.control_plane.id
  description              = "Semua traffic dari Control Plane"
}
# ─────────────────────────────────────────
# SG RDS
# Database tidak kenal dunia luar
# Hanya terima koneksi MySQL dari Worker & CP
# ─────────────────────────────────────────
resource "aws_security_group" "rds" {
  name        = "${var.cluster_name}-sg-rds"
  description = "RDS MySQL — hanya dari K8s nodes"
  vpc_id      = aws_vpc.main.id

  # MySQL dari Worker Nodes
  ingress {
    description     = "MySQL dari Worker"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.worker.id]
  }

  # MySQL dari Control Plane (untuk migration/admin)
  ingress {
    description     = "MySQL dari Control Plane"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.control_plane.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.cluster_name}-sg-rds"
  }
}
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region
}

# ─────────────────────────────────────────
# AMI: Ubuntu 22.04 LTS (Jammy)
# ─────────────────────────────────────────
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical official

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ─────────────────────────────────────────
# Networking: pakai default VPC & subnet
# ─────────────────────────────────────────
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# ─────────────────────────────────────────
# Security Group
# ─────────────────────────────────────────
resource "aws_security_group" "k8s" {
  name        = "${var.cluster_name}-sg"
  description = "Kubernetes cluster security group"
  vpc_id      = data.aws_vpc.default.id

  # SSH — akses dari mana saja (sandbox)
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Kubernetes API server
  ingress {
    description = "K8s API Server"
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # NodePort services (untuk akses aplikasi dari luar)
  ingress {
    description = "NodePort Services"
    from_port   = 30000
    to_port     = 32767
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Semua traffic antar node dalam cluster (internal)
  ingress {
    description = "Internal cluster traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }

  # Semua outbound
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "${var.cluster_name}-sg"
    Cluster = var.cluster_name
  }
}


# ─────────────────────────────────────────
# Security Group RDS
# ─────────────────────────────────────────
# 1. Security Group untuk RDS
resource "aws_security_group" "rds_sg" {
  name        = "wordpress-rds-sg"
  description = "Allow inbound traffic from K8s Nodes"
  vpc_id      = data.aws_vpc.default.id

  # Mengizinkan traffic MySQL (3306) dari IP Private VPC Anda
  ingress {
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = ["172.31.0.0/16"] # Sesuai network K8s Iksan tadi
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# 2. RDS Instance (MySQL)
resource "aws_db_instance" "wordpress_db" {
  allocated_storage    = 20
  storage_type         = "gp2"
  engine               = "mysql"
  engine_version       = "8.0"
  instance_class       = "db.t3.micro" # Hemat biaya / Free Tier
  db_name              = "wordpressdb"
  username             = "admin"
  password             = "PasswordIksan123" # Gunakan Secrets Manager untuk produksi!
  parameter_group_name = "default.mysql8.0"
  skip_final_snapshot  = true
  publicly_accessible  = false # Sangat penting: DB tidak boleh dibuka ke internet
  vpc_security_group_ids = [aws_security_group.rds_sg.id]

  tags = {
    Name = "WordPress-DB-Iksan"
  }
}

# ─────────────────────────────────────────
# Key Pair
# ─────────────────────────────────────────
resource "aws_key_pair" "k8s" {
  key_name   = "${var.cluster_name}-key"
  public_key = file(var.public_key_path)

  tags = {
    Name = "${var.cluster_name}-key"
  }
}

# ─────────────────────────────────────────
# EC2: Master Node (1 node)
# ─────────────────────────────────────────
resource "aws_instance" "master" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.master_instance_type
  key_name                    = aws_key_pair.k8s.key_name
  subnet_id                   = data.aws_subnets.default.ids[0]
  vpc_security_group_ids      = [aws_security_group.k8s.id]
  associate_public_ip_address = true

  root_block_device {
    volume_size           = 20
    volume_type           = "gp3"
    delete_on_termination = true
  }

  user_data = templatefile("${path.module}/scripts/master.sh", {
    pod_cidr      = var.pod_cidr
    cluster_name  = var.cluster_name
    k8s_version   = var.k8s_version
  })

  tags = {
    Name    = "${var.cluster_name}-master"
    Role    = "master"
    Cluster = var.cluster_name
  }
}

# ─────────────────────────────────────────
# EC2: Worker Nodes (default: 2 nodes)
# ─────────────────────────────────────────
resource "aws_instance" "worker" {
  count                       = var.worker_count
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.worker_instance_type
  key_name                    = aws_key_pair.k8s.key_name
  subnet_id                   = data.aws_subnets.default.ids[0]
  vpc_security_group_ids      = [aws_security_group.k8s.id]
  associate_public_ip_address = true

  root_block_device {
    volume_size           = 20
    volume_type           = "gp3"
    delete_on_termination = true
  }

  user_data = templatefile("${path.module}/scripts/worker.sh", {
    k8s_version = var.k8s_version
  })

  tags = {
    Name    = "${var.cluster_name}-worker-${count.index + 1}"
    Role    = "worker"
    Cluster = var.cluster_name
    Index   = count.index + 1
  }
}

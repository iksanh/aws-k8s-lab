terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = var.cluster_name
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

#---------------------------------------
# Data Sources
#---------------------------------------

data "aws_availability_zones" "available" {
  state = "available"
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

#---------------------
#VPC
#---------------------

resource "aws_vpc" "main" {
  cidr_block = var.vpc_cidr
  # Wajib true agar EC2 dapat hostname AWS
  enable_dns_support = true

  # Wajib true agar RDS endpoint bisa di-resolve
  # dari dalam VPC. Tanpa ini koneksi ke RDS gagal
  # meski security group & subnet sudah benar
  enable_dns_hostnames = true

  tags = {
    Name = "${var.cluster_name}-vpc"
  }
}


# -----------------------------------------
# Internet Gateway
# Pintu dua arah untuk public subnet
# Bastion & ALB butuh ini untuk terima
# traffic dari internet
# -----------------------------------------

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.cluster_name}-igw"
  }

}

#----------------------------------------
# Public Subnets
# Untuk Bastion & ALB
# Min 2 subnet di AZ berbeda — syarat ALB
#----------------------------------------

resource "aws_subnet" "public" {
  count                   = length(var.public_subnet_cidrs)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.cluster_name}-public-${count.index + 1}"
    Tier = "public"
  }
}

# ─────────────────────────────────────────
# Private Subnets — Control Plane
# 3 subnet di 3 AZ berbeda
# Distribusi CP ke AZ berbeda agar tahan
# jika salah satu AZ down
# ─────────────────────────────────────────

resource "aws_subnet" "private_cp" {
  count = length(var.private_cp_subnet_cidrs)

  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_cp_subnet_cidrs[count.index]
  availability_zone = data.aws_availability_zones.available.names[count.index % length(data.aws_availability_zones.available.names)]

  tags = {
    Name = "${var.cluster_name}-private-cp-${count.index + 1}"
    Tier = "private-control-plane"
  }
}

# ─────────────────────────────────────────
# Private Subnets — Worker Node
# ─────────────────────────────────────────

resource "aws_subnet" "private_worker" {
  count = length(var.private_worker_subnet_cidrs)

  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_worker_subnet_cidrs[count.index]
  availability_zone = data.aws_availability_zones.available.names[count.index % length(data.aws_availability_zones.available.names)]

  tags = {
    Name = "${var.cluster_name}-private-worker-${count.index + 1}"
    Tier = "private-worker"
  }
}

# ─────────────────────────────────────────
# Private Subnets — RDS
# Min 2 subnet di AZ berbeda
# ─────────────────────────────────────────

resource "aws_subnet" "private_db" {
  count = length(var.private_db_subnet_cidrs)

  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_db_subnet_cidrs[count.index]
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = {
    Name = "${var.cluster_name}-private-worker-${count.index + 1}"
    Tier = "private-db"
  }
}

# ─────────────────────────────────────────
# Elastic IP untuk NAT Gateway
# ─────────────────────────────────────────
resource "aws_eip" "nat" {
  domain     = "vpc"
  depends_on = [aws_internet_gateway.main]

  tags = {
    Name = "${var.cluster_name}-nat-eip"
  }
}

# ─────────────────────────────────────────
# NAT Gateway
# Duduk di public subnet — melayani semua
# private subnet untuk outbound internet
# (apt update, pull image, dll)
# ─────────────────────────────────────────
resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id

  tags = {
    Name = "${var.cluster_name}-nat-gw"
  }

  depends_on = [aws_internet_gateway.main]
}

# ─────────────────────────────────────────
# Route Table — Public
# Traffic keluar lewat IGW
# ─────────────────────────────────────────

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${var.cluster_name}-rt-public"
  }
}

# Hubungkan public route table ke public subnets
resource "aws_route_table_association" "public" {
  count = length(aws_subnet.public)
  subnet_id = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
  
}

# ─────────────────────────────────────────
# Route Table — Private
# Traffic keluar lewat NAT Gateway
# ─────────────────────────────────────────
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = {
    Name = "${var.cluster_name}-rt-private"
  }
}

# Hubungkan ke subnet CP
resource "aws_route_table_association" "private_cp" {
  count          = length(aws_subnet.private_cp)
  subnet_id      = aws_subnet.private_cp[count.index].id
  route_table_id = aws_route_table.private.id
}

# Hubungkan ke subnet Worker
resource "aws_route_table_association" "private_worker" {
  count          = length(aws_subnet.private_worker)
  subnet_id      = aws_subnet.private_worker[count.index].id
  route_table_id = aws_route_table.private.id
}

# Hubungkan ke subnet RDS
resource "aws_route_table_association" "private_db" {
  count          = length(aws_subnet.private_db)
  subnet_id      = aws_subnet.private_db[count.index].id
  route_table_id = aws_route_table.private.id
}

# ─────────────────────────────────────────
# SSH Key Pair
# Public key di-upload ke AWS
# Private key tetap di laptop Anda
# ─────────────────────────────────────────

resource "aws_key_pair" "k8s" {
    key_name = "${var.cluster_name}-key"
    public_key = file(var.public_key_path)


    tags = {
      Name = "${var.cluster_name}-key"
    }
  
}

# ─────────────────────────────────────────
# Bastion Host
# Satu-satunya EC2 di public subnet
# Hanya sebagai jump server — tidak ada
# workload aplikasi di sini
# ─────────────────────────────────────────
resource "aws_instance" "bastion" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.bastion_instance_type
  key_name                    = aws_key_pair.k8s.key_name
  subnet_id                   = aws_subnet.public[0].id
  vpc_security_group_ids      = [aws_security_group.bastion.id]
  associate_public_ip_address = true

  root_block_device {
    volume_size           = 10
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true

     tags = {
    Name = "${var.cluster_name}-bastion-volume"
    Role = "bastion"
  }
  }

  user_data = <<-EOF
    #!/bin/bash

    set -e

    #set hostname
    hostnamectl set-hostname "${var.cluster_name}-bastion"

    #update & install dependencies
    apt-get update -y
    apt-get install -y softwere-properties-common python3-pip


    #add PPA Anasible (official)
    add-apt-repository --yes --update ppa:ansible/ansible

    #install Ansible
    apt-get install -y ansible

    #Verifikasi installasi
    ansible --version >> /var/log/ansible-install.log
  EOF

#   # Install SSM Agent — akses tanpa SSH (lebih aman)
#   user_data = <<-EOF
#     #!/bin/bash
#     apt-get update -y
#     snap install amazon-ssm-agent --classic
#     systemctl enable snap.amazon-ssm-agent.amazon-ssm-agent.service
#     systemctl start snap.amazon-ssm-agent.amazon-ssm-agent.service
#   EOF

  tags = {
    Name = "${var.cluster_name}-bastion"
    Role = "bastion"
  }
}

# Elastic IP untuk Bastion
# IP tidak berubah meski instance restart
resource "aws_eip" "bastion" {
  instance   = aws_instance.bastion.id
  domain     = "vpc"
  depends_on = [aws_internet_gateway.main]

  tags = {
    Name = "${var.cluster_name}-bastion-eip"
  }
}

# ─────────────────────────────────────────
# Control Plane Nodes (HA: 3 node)
# Tersebar di 3 AZ berbeda
# Tahan jika salah satu AZ down
# etcd quorum: butuh 2/3 node aktif
# ─────────────────────────────────────────
resource "aws_instance" "control_plane" {
  count = var.control_plane_count

  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.master_instance_type
  key_name                    = aws_key_pair.k8s.key_name
  subnet_id                   = aws_subnet.private_cp[
    count.index % length(aws_subnet.private_cp)
  ].id
  vpc_security_group_ids      = [aws_security_group.control_plane.id]
  associate_public_ip_address = false

  root_block_device {
    volume_size           = 30
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true

   tags = {
    Name = "${var.cluster_name}-cp-${count.index + 1}-volume"
    Role = "control-plane"
  }
  }

  user_data = <<-EOF
    #!/bin/bash
    hostnamectl set-hostname "${var.cluster_name}-cp-${count.index + 1}"
  EOF

#   user_data = templatefile("${path.module}/scripts/master.sh", {
#     pod_cidr     = var.pod_cidr
#     cluster_name = var.cluster_name
#     k8s_version  = var.k8s_version
#     node_index   = count.index
#   })

  tags = {
    Name  = "${var.cluster_name}-cp-${count.index + 1}"
    Role  = "control-plane"
  }
}

# ─────────────────────────────────────────
# Worker Nodes (default: 3)
# Tersebar di AZ berbeda
# Tidak boleh punya public IP
# ─────────────────────────────────────────
resource "aws_instance" "worker" {
  count = var.worker_count

  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.worker_instance_type
  key_name                    = aws_key_pair.k8s.key_name
  subnet_id                   = aws_subnet.private_worker[
    count.index % length(aws_subnet.private_worker)
  ].id
  vpc_security_group_ids      = [aws_security_group.worker.id]
  associate_public_ip_address = false

  root_block_device {
    volume_size           = 30
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true 

    tags = {
    Name = "${var.cluster_name}-worker-${count.index + 1}-volume"
    Role = "worker"
  }
  }

#   user_data = templatefile("${path.module}/scripts/worker.sh", {
#     k8s_version = var.k8s_version
#   })

  user_data = <<-EOF
    #!/bin/bash
    hostnamectl set-hostname "${var.cluster_name}-worker-${count.index + 1}"
  EOF

  tags = {
    Name  = "${var.cluster_name}-worker-${count.index + 1}"
    Role  = "worker"
    Index = count.index + 1
  }
}
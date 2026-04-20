#-------------------------------
# Global
#-------------------------------

variable "region" {
  description = "AWS REGION"
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
 description = "Name prefix for all resources"
 type        = string
 default     = "k8s-lab" 
}


variable "environment" {
  description = "Environment tag"
  type        = string
  default     = "lab"
}

#--------------------------
# VPC & Networking
#-------------------------


variable "vpc_cidr" {
  description = "CIDR block untuk VPC"
  type        = string
  default = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "CIDR public subnets (min 2 AZ untuk ALB)"
  type = list(string)
  default = [ "10.0.1.0/24","10.0.2.0/24" ]
}

variable "private_cp_subnet_cidrs" {
  description = "CIDR subnet Control Plane"
  type = list(string)
  default = [ "10.0.10.0/24","10.0.11.0/24","10.0.12.0/24" ]
}

variable "private_worker_subnet_cidrs" {
  description = "CIDR subnet Worker Nodes"
  type = list(string)
  default = [ "10.0.20.0/24","10.0.21.0/24","10.0.22.0/24" ]
}

variable "private_db_subnet_cidrs" {
  description = "CIDR subnet RDS (min 2 AZ)"
  type = list(string)
  default = [ "10.0.30.0/24","10.0.31.0/24"]
}

#-----------------------------------------
# SSH & Access 
#-----------------------------------------

variable "public_key_path" {
  description = "Path ke SSH Public key"
  type = string
  default = "~/.ssh/id_rsa.pub"
}

variable "allowed_ssh_cidrs" {
  description = "IP yang boleh SSH ke Bastion"
  type = list(string)
  default = [ "0.0.0.0/0" ]
  
}

#---------------------------------------
# EC2 Instance types 
#---------------------------------------

variable "bastion_instance_type" {
  description = "Instance type Bastion"
  type = string
  default = "t3.micro"
}

variable "master_instance_type" {
  description = "Instance type Control Plane"
  type = string
  default = "t3.medium"
}
variable "worker_instance_type" {
  description = "Instance type Worker Node"
  type = string
  default = "t3.medium"
}

variable "control_plane_count" {
  description = "Jumlah Control Plane (harus angka ganjil)"
  type = number
  default = 3

  validation {
    condition = var.control_plane_count % 2 != 0
    error_message = "Harus angka ganjil agar etcd quarum valid"
  }
}

variable "worker_count" {
  description = "Jumlah Worker Node"
  type = number
  default = 3  
}

#-----------------------------------------
# Kubernates
#-----------------------------------------

variable "k8s_version" {
  description = "Versi Kubernates"
  type = string
  default = "1.29"
}

#-----------------------------------------
# RDS
#-----------------------------------------

variable "pod_cidr" {
  description = "CIDR untuk Pod network (Calico)"
  type = string
  default = "192.168.0.0/16"
}

variable "db_name" {
  description = "Nama DB"
  type = string
  default = "wordpressdb"
}

variable "db_username" {
  description = "RDS master username"
  type = string
  sensitive = true
  default = "admin"
}

variable "db_password" {
  description = "RDS master password - isi via tfvars atau env TF_VAR_db_password"
  type = string
  sensitive = true
}

variable "db_instance_class" {
  description = "RDS instance class"
  type = string
  default = "db.t3.micro"
}



variable "db_allocated_storage" {
  description = "RDS storage in GB"
  type        = number
  default     = 20
}
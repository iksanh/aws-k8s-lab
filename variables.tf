variable "region" {
  description = "AWS region (sesuaikan dengan region sandbox KodeKloud kamu)"
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "Nama cluster — dipakai sebagai prefix resource"
  type        = string
  default     = "k8s-lab"
}

variable "public_key_path" {
  description = "Path ke public key SSH kamu (generate dulu: ssh-keygen -t rsa -b 4096)"
  type        = string
  default     = "~/.ssh/id_rsa.pub"
}

variable "master_instance_type" {
  description = "Instance type master node — minimal t3.medium (2vCPU/4GB) untuk kubeadm"
  type        = string
  default     = "t3.medium"
}

variable "worker_instance_type" {
  description = "Instance type worker nodes"
  type        = string
  default     = "t3.medium"
}

variable "worker_count" {
  description = "Jumlah worker node"
  type        = number
  default     = 2
}

variable "pod_cidr" {
  description = "CIDR untuk Pod network (Flannel default: 10.244.0.0/16)"
  type        = string
  default     = "10.244.0.0/16"
}

variable "k8s_version" {
  description = "Versi Kubernetes yang akan diinstall"
  type        = string
  default     = "1.30"
}

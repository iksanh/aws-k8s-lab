# ─────────────────────────────────────────
# IAM Role for EC2 nodes
# Required for EBS CSI Driver to create
# and attach EBS volumes
# ─────────────────────────────────────────

# Role can assume  EC2
resource "aws_iam_role" "k8s_node" {
  name = "${var.cluster_name}-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name = "${var.cluster_name}-node-role"
  }
}

# Policy for EBS CSI Driver
resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.k8s_node.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# Instance Profile ( attach to EC2)
resource "aws_iam_instance_profile" "k8s_node" {
  name = "${var.cluster_name}-node-profile"
  role = aws_iam_role.k8s_node.name
}
# ─────────────────────────────────────────
# RDS Subnet Group
# Wajib ada sebelum buat RDS instance
# Min 2 subnet di AZ berbeda
# ─────────────────────────────────────────
resource "aws_db_subnet_group" "main" {
  name        = "${var.cluster_name}-db-subnet-group"
  description = "RDS subnet group for ${var.cluster_name}"
  subnet_ids  = aws_subnet.private_db[*].id

  tags = {
    Name = "${var.cluster_name}-db-subnet-group"
  }
}

# ─────────────────────────────────────────
# RDS Parameter Group
# Custom konfigurasi MySQL
# ─────────────────────────────────────────
# ─────────────────────────────────────────
# RDS Parameter Group
# DINONAKTIFKAN: lab KodeKloud tidak izinkan
# rds:CreateDBParameterGroup
#
# AKTIFKAN DI PRODUCTION:
# Uncomment block ini dan ganti parameter_group_name
# di aws_db_instance dengan:
# parameter_group_name = aws_db_parameter_group.mysql.name
# ─────────────────────────────────────────
# resource "aws_db_parameter_group" "mysql" {
#   name        = "${var.cluster_name}-mysql-params"
#   family      = "mysql8.0"
#   description = "Custom parameter group for ${var.cluster_name}"

#   # Log query yang lambat (> 2 detik)
#   # Berguna untuk debug performance
#   parameter {
#     name  = "slow_query_log"
#     value = "1"
#   }

#   parameter {
#     name  = "long_query_time"
#     value = "2"
#   }

#   # Wajib pakai SSL untuk koneksi ke RDS
#   parameter {
#     name  = "require_secure_transport"
#     value = "ON"
#   }

#   tags = {
#     Name = "${var.cluster_name}-mysql-params"
#   }
# }


# ─────────────────────────────────────────
# RDS Instance MySQL
# ─────────────────────────────────────────
resource "aws_db_instance" "main" {
  identifier = "${var.cluster_name}-mysql"

  # Engine
  engine         = "mysql"
  engine_version = "8.0"

  # Compute & Storage
  instance_class        = var.db_instance_class
  allocated_storage     = var.db_allocated_storage
  max_allocated_storage = 100
  storage_type          = "gp3"
  storage_encrypted     = true

  # Database
  db_name  = var.db_name
  username = var.db_username
  password = var.db_password

  # Network & Security
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false
  port                   = 3306

  # Parameter Group
  parameter_group_name = "default.mysql8.0"
  # parameter_group_name = aws_db_parameter_group.mysql.name

  # Backup
  backup_retention_period = 7
  backup_window           = "02:00-03:00"
  maintenance_window      = "Mon:04:00-Mon:05:00"
  copy_tags_to_snapshot   = true

  # Lab: skip final snapshot
  # Production: ganti false
  skip_final_snapshot = true

  # Lab: tidak perlu Multi-AZ
  # Production: ganti true
  multi_az = false

  tags = {
    Name = "${var.cluster_name}-mysql"
  }

    # Enhanced Monitoring
      # DINONAKTIFKAN: lab KodeKloud tidak izinkan rds:CreateDBParameterGroup
  # AKTIFKAN DI PRODUCTION: metrics OS level per 60 detik
  
#   monitoring_interval = 60
#   monitoring_role_arn = aws_iam_role.rds_monitoring.arn


  # Performance Insights
    # DINONAKTIFKAN: lab KodeKloud tidak izinkan
  # AKTIFKAN DI PRODUCTION: analisa query lambat via AWS Console
  #--------------------------------------------------------------
#   performance_insights_enabled          = true
#   performance_insights_retention_period = 7
}

# ─────────────────────────────────────────
# IAM Role — RDS Enhanced Monitoring
# Izinkan RDS kirim metrics ke CloudWatch
# ─────────────────────────────────────────

# ─────────────────────────────────────────
# IAM Role RDS Enhanced Monitoring
# DINONAKTIFKAN: lab KodeKloud tidak izinkan iam:CreateRole
#
# AKTIFKAN DI PRODUCTION:
# Uncomment block ini agar RDS bisa kirim
# metrics OS level ke CloudWatch
# resource "aws_iam_role" "rds_monitoring" {
#   name = "${var.cluster_name}-rds-monitoring-role"

#   assume_role_policy = jsonencode({
#     Version = "2012-10-17"
#     Statement = [
#       {
#         Action = "sts:AssumeRole"
#         Effect = "Allow"
#         Principal = {
#           Service = "monitoring.rds.amazonaws.com"
#         }
#       }
#     ]
#   })

#   tags = {
#     Name = "${var.cluster_name}-rds-monitoring-role"
#   }
# }

# resource "aws_iam_role_policy_attachment" "rds_monitoring" {
#   role       = aws_iam_role.rds_monitoring.name
#   policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
# }
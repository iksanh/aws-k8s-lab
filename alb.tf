# ─────────────────────────────────────────
# Application Load Balancer
# Internet-facing — di public subnet
# Terima HTTP/HTTPS dari internet
# Forward ke worker NodePort
# ─────────────────────────────────────────

resource "aws_lb" "main" {
    name = "${var.cluster_name}-alb"
    internal = false
    load_balancer_type = "application"
    security_groups = [ aws_security_group.alb.id ]
    subnets = aws_subnet.public[*].id

    enable_deletion_protection = false

    tags = {
      Name = "${var.cluster_name}-alb"
    }
  
}


# ─────────────────────────────────────────
# Internal NLB — Control Plane
# Worker konek ke NLB (satu endpoint tetap)
# NLB forward ke CP yang masih hidup
# Kalau CP-1 mati → otomatis ke CP-2/CP-3
# ─────────────────────────────────────────
resource "aws_lb" "control_plane" {
  name               = "${var.cluster_name}-cp-nlb"
  internal           = true
  load_balancer_type = "network"
  subnets            = aws_subnet.private_cp[*].id

  enable_deletion_protection = false

  tags = {
    Name = "${var.cluster_name}-cp-nlb"
  }
}

# ─────────────────────────────────────────
# Target Group — Worker Nodes
# ALB forward ke NodePort worker
# Port 30080 — sesuaikan dengan NodePort
# service WordPress Anda nanti
# ─────────────────────────────────────────
resource "aws_lb_target_group" "workers" {
  name        = "${var.cluster_name}-tg-workers"
  port        = 30080
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "instance"

  health_check {
    enabled             = true
    path                = "/"
    port                = "traffic-port"
    protocol            = "HTTP"
    healthy_threshold   = 3
    unhealthy_threshold = 3
    timeout             = 10
    interval            = 30
    matcher             = "200-399"
  }

  tags = {
    Name = "${var.cluster_name}-tg-workers"
  }
}

# Attach semua Worker ke Target Group
resource "aws_lb_target_group_attachment" "workers" {
  count            = var.worker_count
  target_group_arn = aws_lb_target_group.workers.arn
  target_id        = aws_instance.worker[count.index].id
  port             = 30080
}


# ─────────────────────────────────────────
# Target Group — Control Plane
# NLB forward ke port 6443 (K8s API Server)
# Health check TCP — bukan HTTP
# ─────────────────────────────────────────
resource "aws_lb_target_group" "control_plane" {
  name        = "${var.cluster_name}-tg-cp"
  port        = 6443
  protocol    = "TCP"
  vpc_id      = aws_vpc.main.id
  target_type = "instance"

  health_check {
    protocol            = "TCP"
    port                = 6443
    healthy_threshold   = 3
    unhealthy_threshold = 3
    interval            = 10
  }

  tags = {
    Name = "${var.cluster_name}-tg-cp"
  }
}

# Attach semua CP ke Target Group
resource "aws_lb_target_group_attachment" "control_plane" {
  count            = var.control_plane_count
  target_group_arn = aws_lb_target_group.control_plane.arn
  target_id        = aws_instance.control_plane[count.index].id
  port             = 6443
}


# ─────────────────────────────────────────
# ALB Listener — HTTP
# Untuk lab: langsung forward ke worker
# Untuk production: redirect ke HTTPS
# ─────────────────────────────────────────
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.workers.arn
  }
}

# ─────────────────────────────────────────
# NLB Listener — TCP 6443
# Worker → NLB → Control Plane API Server
# ─────────────────────────────────────────
resource "aws_lb_listener" "control_plane" {
  load_balancer_arn = aws_lb.control_plane.arn
  port              = 6443
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.control_plane.arn
  }
}
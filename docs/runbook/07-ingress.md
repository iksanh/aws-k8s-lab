# NGINX Ingress Controller — Panduan Lengkap
> Berdasarkan pengalaman lab: install, konfigurasi, dan debug  
> Domain: `iksanhariji.my.id` | Cluster: Self-managed K8s di AWS

---

## ⚠️ Status ingress-nginx (2026)

| Project | Status | Keterangan |
|---------|--------|------------|
| `kubernetes/ingress-nginx` | ❌ Retired March 2026 | Yang kita pakai di lab ini |
| `nginxinc/kubernetes-ingress` (F5) | ✅ Aktif | Drop-in replacement |
| **Gateway API** | ✅ Standar baru K8s | Recommended untuk production baru |

> **Untuk lab:** ingress-nginx tetap valid untuk belajar konsep.  
> **Untuk production baru:** migrasi ke Gateway API atau NGINX Ingress F5.

---

## Konsep Dasar

### Analogi dengan AWS

| K8s | AWS | Fungsi |
|-----|-----|--------|
| Ingress Controller | ALB | "Mesin" yang handle routing |
| Ingress Resource | Listener Rules | Config routing per host/path |
| Service (ClusterIP) | Target Group | Endpoint internal ke Pod |

### Flow End-to-End

```
User Browser
  ↓
DNS (CNAME → ALB AWS)
  ↓
ALB Listener :80
  ↓
Target Group (port 30080)
  ↓
Worker Node :30080 (NodePort)
  ↓
NGINX Ingress Controller Pod
  ↓
Ingress Rule (match by host)
  ↓
Service (ClusterIP)
  ↓
Application Pod
```

### Host-based vs Path-based Routing

| | Host-based | Path-based |
|--|-----------|------------|
| **URL** | `grafana.domain.com` | `domain.com/grafana` |
| **Complexity** | ✅ Simpel | ⚠️ Kompleks |
| **Reliability** | ✅ Solid | ⚠️ Fragile (redirect loop) |
| **Security** | ✅ Per-domain control | ❌ Shared domain |
| **Production** | ✅ Recommended | ❌ Hindari untuk app seperti Grafana |

> **Aturan:** Grafana, Prometheus, ArgoCD → **selalu host-based**.  
> Path-based cocok untuk: API endpoints dalam satu aplikasi (`/v1/users`, `/v1/orders`).

---

## Bagian 1 — Install NGINX Ingress Controller

### 1.1 Install via Helm

```bash
# Add repo
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

# Install dengan NodePort fixed
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  --set controller.service.type=NodePort \
  --set controller.service.nodePorts.http=30080 \
  --set controller.service.nodePorts.https=32443
```

### 1.2 Verifikasi

```bash
# Pod harus 1/1 Running
kubectl get pods -n ingress-nginx

# Service harus NodePort dengan port yang benar
kubectl get svc -n ingress-nginx
```

Output yang benar:
```
NAME                       TYPE       PORT(S)
ingress-nginx-controller   NodePort   80:30080/TCP,443:32443/TCP
```

### 1.3 Cek IngressClass

```bash
kubectl get ingressclass
```

Output:
```
NAME    CONTROLLER
nginx   k8s.io/ingress-nginx
```

> ⚠️ **Penting:** `ingressClassName` di YAML harus sesuai dengan NAME di sini (`nginx`).

### 1.4 Mapping Port

| Layer | Port | Keterangan |
|-------|------|------------|
| ALB Listener | `:80` | Entry dari internet |
| Target Group | `:30080` | Forward ke NodePort |
| Worker Node (NodePort) | `:30080` | Diterima kube-proxy |
| Service NGINX | `:80` | Internal cluster |
| Pod NGINX | `:80` | Container listen |

---

## Bagian 2 — Setup AWS (Terraform)

### 2.1 Target Group

```hcl
resource "aws_lb_target_group" "ingress_nginx" {
  name        = "${var.cluster_name}-tg-ingress"
  port        = 30080
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "instance"

  deregistration_delay = 30

  health_check {
    enabled             = true
    path                = "/"
    port                = "traffic-port"
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 5
    interval            = 15
    matcher             = "200-499"   # NGINX root return 404 = normal & healthy
  }

  tags = {
    Name = "${var.cluster_name}-tg-ingress"
  }
}
```

> **Kenapa `200-499`?**  
> NGINX return `404` di root `/` karena tidak ada default rule.  
> `404` = NGINX **hidup dan bekerja**, bukan error. Matcher `200-399` akan mark worker sebagai unhealthy.

### 2.2 Target Group Attachment

```hcl
resource "aws_lb_target_group_attachment" "ingress_nginx" {
  count            = var.worker_count
  target_group_arn = aws_lb_target_group.ingress_nginx.arn
  target_id        = aws_instance.worker[count.index].id
  port             = 30080
}
```

### 2.3 ALB Listener

```hcl
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ingress_nginx.arn
  }
}
```

### 2.4 Security Group Worker

```hcl
# Wajib buka port NodePort dari SG ALB
ingress {
  from_port       = 30080
  to_port         = 30080
  protocol        = "tcp"
  security_groups = [aws_security_group.alb.id]
}
```

> ⚠️ **Kalau port NodePort berubah**, Security Group **harus ikut diupdate**. Ini sering jadi penyebab TG unhealthy.

---

## Bagian 3 — Setup DNS di Hostinger

### 3.1 Tambah CNAME Records

Login Hostinger → Domains → `iksanhariji.my.id` → DNS Records → Add Record:

| Type | Name | Target | TTL |
|------|------|--------|-----|
| CNAME | `argocd` | `<ALB-DNS-NAME>` | 300 |
| CNAME | `grafana` | `<ALB-DNS-NAME>` | 300 |
| CNAME | `prometheus` | `<ALB-DNS-NAME>` | 300 |

> **Tips:** Isi field Name hanya `argocd` (bukan `argocd.iksanhariji.my.id`). Hostinger auto-append domain.

### 3.2 Verifikasi Propagasi DNS

```bash
dig +short argocd.iksanhariji.my.id
dig +short grafana.iksanhariji.my.id
dig +short prometheus.iksanhariji.my.id
```

Harus return IP ALB. Propagasi biasanya 5-15 menit di Hostinger.

---

## Bagian 4 — ArgoCD Ingress

### 4.1 Persiapan — Enable Insecure Mode (WAJIB)

ArgoCD by default serve **HTTPS**. Untuk Ingress plain HTTP, harus di-set insecure mode:

```bash
# Enable insecure mode via ConfigMap
kubectl -n argocd patch configmap argocd-cmd-params-cm \
  --type merge \
  -p '{"data":{"server.insecure":"true"}}'

# Restart pod agar config baru aktif
kubectl -n argocd rollout restart deployment argocd-server
kubectl -n argocd rollout status deployment argocd-server
```

### 4.2 Verifikasi Insecure Mode

```bash
# Harus return 200, BUKAN 307 redirect HTTPS
CLUSTER_IP=$(kubectl get svc argocd-server -n argocd -o jsonpath='{.spec.clusterIP}')
curl -v http://$CLUSTER_IP:80
```

| Response | Artinya |
|----------|---------|
| `HTTP/1.1 200 OK` | ✅ Insecure mode aktif |
| `HTTP/1.1 307 Temporary Redirect` ke `https://` | ❌ Insecure mode belum aktif |

### 4.3 Simpan ConfigMap sebagai File (untuk GitOps)

```yaml
# apps/argocd/configmap-insecure.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-cmd-params-cm
  namespace: argocd
  labels:
    app.kubernetes.io/name: argocd-cmd-params-cm
    app.kubernetes.io/part-of: argocd
data:
  server.insecure: "true"
```

### 4.4 Pastikan Service ArgoCD ClusterIP

```bash
kubectl get svc argocd-server -n argocd

# Kalau masih NodePort, ubah ke ClusterIP
kubectl patch svc argocd-server -n argocd \
  -p '{"spec": {"type": "ClusterIP"}}'
```

### 4.5 Buat Ingress ArgoCD

```bash
cat > apps/argocd/ingress.yaml << 'EOF'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-server
  namespace: argocd
spec:
  ingressClassName: nginx
  rules:
    - host: argocd.iksanhariji.my.id
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: argocd-server
                port:
                  number: 80
EOF

kubectl apply -f apps/argocd/ingress.yaml
```

### 4.6 Verifikasi ArgoCD

```bash
kubectl get ingress -n argocd
curl -v http://argocd.iksanhariji.my.id
```

---

## Bagian 5 — Monitoring Ingress (Grafana & Prometheus)

### 5.1 Cek Service yang Ada

```bash
kubectl get svc -n monitoring | grep -E "grafana|prometheus"
```

Yang dibutuhkan:
- `kube-prometheus-stack-grafana` → port `80`
- `kube-prometheus-stack-prometheus` → port `9090`

### 5.2 Buat Ingress Monitoring (Host-based)

```bash
cat > apps/monitoring/ingress.yaml << 'EOF'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: monitoring
  namespace: monitoring
spec:
  ingressClassName: nginx
  rules:
    - host: grafana.iksanhariji.my.id
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: kube-prometheus-stack-grafana
                port:
                  number: 80
    - host: prometheus.iksanhariji.my.id
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: kube-prometheus-stack-prometheus
                port:
                  number: 9090
EOF

kubectl apply -f apps/monitoring/ingress.yaml
```

### 5.3 Verifikasi

```bash
kubectl get ingress -n monitoring
curl -v http://grafana.iksanhariji.my.id
curl -v http://prometheus.iksanhariji.my.id
```

### 5.4 Password Grafana

```bash
kubectl get secret -n monitoring kube-prometheus-stack-grafana \
  -o jsonpath="{.data.admin-password}" | base64 -d ; echo
```

Username: `admin`

---

## Bagian 6 — Checklist Lengkap

### Sebelum Apply Ingress
- [ ] Pod NGINX Ingress Controller `1/1 Running`
- [ ] TG AWS health status `healthy` (bukan unhealthy)
- [ ] Security Group worker buka port `30080` dari SG ALB
- [ ] DNS CNAME sudah propagasi (`dig +short <domain>` return IP ALB)

### Khusus ArgoCD
- [ ] ConfigMap `server.insecure: "true"` sudah di-set
- [ ] Pod `argocd-server` sudah restart setelah patch
- [ ] `curl` ke ClusterIP return `200` (bukan `307`)
- [ ] Service type `ClusterIP` (bukan NodePort)

### Khusus Monitoring
- [ ] Namespace Ingress = `monitoring` (bukan `argocd`!)
- [ ] Nama service benar (`kubectl get svc -n monitoring`)
- [ ] Port Grafana = `80`, Port Prometheus = `9090`

### YAML Ingress — Yang TIDAK Boleh Ada
- [ ] ❌ `backend-protocol: HTTPS` → penyebab 502 SSL handshake error
- [ ] ❌ `kubernetes.io/ingress.class: nginx` → deprecated, pakai `ingressClassName`
- [ ] ❌ `kubernetes.io/ingress.class: contour-internal` → controller salah
- [ ] ❌ `namespace: argocd` untuk monitoring Ingress → service tidak ketemu
- [ ] ❌ `port: number: 443` untuk ArgoCD insecure mode → harus 80
- [ ] ❌ Typo domain (`my.ig` vs `my.id`) → bedanya 1 huruf, dampaknya fatal

---

## Bagian 7 — Debugging Quick Reference

### Flow Debug (selalu dari luar ke dalam)

```
Layer 1: DNS
  dig +short argocd.iksanhariji.my.id
  → Harus return IP ALB

Layer 2: Target Group (AWS Console)
  EC2 → Target Groups → Targets
  → Status harus "healthy"

Layer 3: Security Group
  Port 30080 terbuka dari SG ALB?

Layer 4: Test direct ke NodePort
  curl -v -H "Host: argocd.iksanhariji.my.id" http://<worker-ip>:30080
  → 404 dari NGINX = normal (NGINX hidup)
  → Connection refused = NGINX problem
  → Connection timed out = Security Group blokir

Layer 5: Log NGINX ← PALING PENTING
  kubectl logs -n ingress-nginx \
    -l app.kubernetes.io/component=controller --tail=30

Layer 6: Ingress Resource
  kubectl get ingress -n <namespace> -o yaml
  → annotation benar? port benar? host benar?

Layer 7: Service Endpoints
  kubectl get endpoints <service> -n <namespace>
  → Kosong = problem (pod tidak match selector)

Layer 8: Pod Status
  kubectl get pods -n <namespace>
  kubectl logs <pod-name> -n <namespace>
```

### Error & Fix

| Error | Log Pattern | Penyebab | Fix |
|-------|-------------|----------|-----|
| `502 Bad Gateway` | `SSL handshake to upstream` | Annotation `backend-protocol: HTTPS` masih ada | Hapus annotation |
| `502 Bad Gateway` | `SSL handshake to upstream` | ArgoCD insecure mode belum aktif | Enable insecure mode |
| `503 Service Unavailable` | `no live upstreams` | Pod tidak ready / endpoint kosong | Cek pod status |
| `404 Not Found` | - | Host tidak match Ingress rule | Cek `host:` di YAML, cek typo |
| `Too many redirects` | - | Path-based routing loop | Pakai host-based routing |
| `TG unhealthy` | - | SG blokir / matcher salah | Buka port 30080, ubah matcher `200-499` |

### Command Paling Sering Dipakai

```bash
# Status NGINX
kubectl get pods -n ingress-nginx
kubectl get svc -n ingress-nginx

# Semua Ingress
kubectl get ingress -A

# Log NGINX real-time
kubectl logs -n ingress-nginx \
  -l app.kubernetes.io/component=controller -f

# Detail Ingress
kubectl describe ingress <name> -n <namespace>

# Hapus annotation
kubectl annotate ingress <name> -n <namespace> \
  nginx.ingress.kubernetes.io/backend-protocol-

# Test dengan host header
curl -v -H "Host: argocd.iksanhariji.my.id" http://<worker-ip>:30080
```

---

## Bagian 8 — Struktur File di Git

```
k8s-manifests/
├── README.md
├── apps/
│   ├── argocd/
│   │   ├── ingress.yaml
│   │   └── configmap-insecure.yaml
│   └── monitoring/
│       └── ingress.yaml
└── platform/
    └── ingress-nginx/
        └── values.yaml
```

### Contoh ArgoCD Application untuk GitOps

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: argocd-config
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/iksanhariji/k8s-manifests
    targetRevision: HEAD
    path: apps/argocd
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

---

## Bagian 9 — Production Best Practice

### Yang Boleh Public
```
argocd.company.com       → ArgoCD (dengan SSO)
grafana.company.com      → Grafana (dengan auth)
app.company.com          → Main application
api.company.com          → API
```

### Yang Harus Internal Only
```
prometheus.internal      → Prometheus (metrics sensitif!)
alertmanager.internal    → Alertmanager
```

### Yang Tidak Perlu Ingress
```
etcd                     → kubectl port-forward only
kube-apiserver metrics   → internal only
```

> ⚠️ **Prometheus tidak boleh public di production!**  
> Prometheus expose semua metrics cluster — CPU, memory, network, bahkan secrets metrics.  
> Akses via kubectl port-forward atau internal ALB saja.

---

## Bagian 10 — Pelajaran Terpenting dari Lab

### 1. State K8s Tidak Persistent saat Rebuild Cluster
Ingress, ConfigMap, Secret — **semua hilang** saat cluster di-destroy.  
Solusi: **GitOps** (ArgoCD watch Git repo → auto-sync saat cluster baru).

### 2. Namespace Harus Match Service
Ingress harus di namespace yang **sama** dengan Service.  
Monitoring Ingress → `namespace: monitoring`, bukan `namespace: argocd`.

### 3. Health Check Matcher `200-499`
NGINX root `/` return `404` = **normal**.  
Matcher harus `200-499` supaya TG tidak mark worker sebagai unhealthy.

### 4. Baca Log NGINX Dulu Sebelum Tebak
```bash
kubectl logs -n ingress-nginx \
  -l app.kubernetes.io/component=controller --tail=30
```
Log ini adalah **ground truth**. Semua tebakan tidak perlu kalau Anda baca log ini dulu.

### 5. Pakai Heredoc untuk Buat YAML Bersih
```bash
cat > ingress.yaml << 'EOF'
# YAML content di sini
EOF
```
Lebih reliable dari edit manual yang sering terbawa annotation lama.

### 6. ConfigMap > Patch Deployment untuk ArgoCD
```bash
# ✅ Cara benar — survive Helm upgrade
kubectl patch configmap argocd-cmd-params-cm ...

# ❌ Cara salah — hilang saat helm upgrade
kubectl patch deployment argocd-server ... --add args --insecure
```

---

*Dibuat berdasarkan pengalaman lab 3 hari — Mei 2026*  
*Cluster: Self-managed K8s di AWS | Domain: iksanhariji.my.id*
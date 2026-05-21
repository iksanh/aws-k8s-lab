# Ingress TLS — HTTPS dengan cert-manager

> Lanjutan dari runbook NGINX Ingress.
> Menambahkan HTTPS otomatis dengan sertifikat Let's Encrypt.
> Domain: `iksanhariji.my.id` | Cluster: Self-managed K8s di AWS

---

## Kenapa Butuh TLS?

Runbook Ingress sebelumnya semua pakai HTTP. Untuk production:

```
HTTP:
  - Traffic tidak terenkripsi
  - Browser tandai "Not Secure"
  - Password, token bisa di-sniff
  - Tidak boleh untuk production

HTTPS:
  - Traffic terenkripsi (TLS)
  - Browser tandai aman (gembok hijau)
  - Wajib untuk login, API, dashboard
```

---

## Pilihan Strategi TLS

| Strategi | SSL Termination | Kapan Dipakai |
|----------|----------------|---------------|
| TLS di ALB (ACM) | Di ALB | Native AWS, cert dari ACM |
| TLS di Ingress (cert-manager) | Di NGINX Ingress | Cloud-agnostic, cert dari Let's Encrypt |
| End-to-end TLS | Sampai pod | Compliance ketat (banking) |

Runbook ini pakai **cert-manager + Let's Encrypt** karena:
- Cloud-agnostic (jalan di EKS, GKE, AKS, on-prem)
- Sertifikat gratis dari Let's Encrypt
- Auto-renew otomatis (tidak perlu manual)
- Standar industri untuk Kubernetes

---

## Konsep cert-manager

```
cert-manager = operator yang manage TLS certificate di K8s

Komponen:
  1. cert-manager Controller
     -> pod yang request & renew certificate

  2. ClusterIssuer / Issuer
     -> "siapa yang mengeluarkan certificate"
     -> contoh: Let's Encrypt

  3. Certificate resource
     -> request certificate untuk domain tertentu

  4. Secret (auto-generated)
     -> tempat certificate disimpan
     -> di-reference oleh Ingress
```

### Flow cert-manager

```
1. Ingress dibuat dengan annotation cert-manager
   ↓
2. cert-manager detect Ingress butuh certificate
   ↓
3. cert-manager buat Certificate resource
   ↓
4. cert-manager request ke Let's Encrypt
   ↓
5. Let's Encrypt minta bukti kepemilikan domain (challenge)
   ↓
6. cert-manager selesaikan challenge (HTTP-01 atau DNS-01)
   ↓
7. Let's Encrypt issue certificate
   ↓
8. cert-manager simpan certificate ke Secret
   ↓
9. NGINX Ingress pakai Secret untuk serve HTTPS
   ↓
10. cert-manager auto-renew 30 hari sebelum expired
```

---

## Bagian 1 — Install cert-manager

### 1.1 Install via Helm

```bash
# Add repo
helm repo add jetstack https://charts.jetstack.io
helm repo update

# Install cert-manager dengan CRDs
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --set crds.enabled=true
```

### 1.2 Verifikasi

```bash
kubectl get pods -n cert-manager
```

Output yang benar (3 pod Running):
```
NAME                                       READY   STATUS
cert-manager-xxx                           1/1     Running
cert-manager-cainjector-xxx                1/1     Running
cert-manager-webhook-xxx                   1/1     Running
```

### 1.3 Verifikasi CRD Terinstall

```bash
kubectl get crd | grep cert-manager
```

Harus ada: `certificates`, `clusterissuers`, `issuers`, dll.

---

## Bagian 2 — Setup ClusterIssuer

ClusterIssuer = sumber certificate, berlaku cluster-wide.

### 2.1 Challenge Type — HTTP-01 vs DNS-01

| | HTTP-01 | DNS-01 |
|--|---------|--------|
| Cara verify | File di `/.well-known/` | TXT record di DNS |
| Butuh | Domain accessible port 80 | Akses ke DNS provider API |
| Wildcard cert | Tidak bisa | Bisa (`*.domain.com`) |
| Cocok untuk | Lab, simple setup | Production, wildcard |

Runbook ini pakai **HTTP-01** karena lebih simple untuk lab.

### 2.2 Buat ClusterIssuer — Staging Dulu

Selalu test dengan **staging** dulu. Let's Encrypt production punya
rate limit ketat (5 certificate per domain per minggu).

```bash
cat > platform/cert-manager/clusterissuer-staging.yaml << 'EOF'
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
spec:
  acme:
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    email: your-email@example.com
    privateKeySecretRef:
      name: letsencrypt-staging
    solvers:
      - http01:
          ingress:
            class: nginx
EOF

kubectl apply -f platform/cert-manager/clusterissuer-staging.yaml
```

### 2.3 Buat ClusterIssuer — Production

Setelah staging berhasil, baru pakai production:

```bash
cat > platform/cert-manager/clusterissuer-prod.yaml << 'EOF'
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: your-email@example.com
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
      - http01:
          ingress:
            class: nginx
EOF

kubectl apply -f platform/cert-manager/clusterissuer-prod.yaml
```

### 2.4 Verifikasi ClusterIssuer

```bash
kubectl get clusterissuer
```

Output:
```
NAME                  READY
letsencrypt-staging   True
letsencrypt-prod      True
```

`READY: True` artinya ClusterIssuer berhasil register ke Let's Encrypt.

---

## Bagian 3 — Prerequisite untuk HTTP-01 Challenge

HTTP-01 challenge mengharuskan Let's Encrypt bisa akses domain
kamu di port 80.

### 3.1 Pastikan DNS Sudah Benar

```bash
dig +short argocd.iksanhariji.my.id
```

Harus return IP ALB.

### 3.2 Pastikan ALB Listener Port 80 Aktif

Let's Encrypt akan akses:
```
http://argocd.iksanhariji.my.id/.well-known/acme-challenge/xxx
```

Jadi port 80 harus tetap terbuka dan route ke NGINX Ingress.

### 3.3 Pastikan NGINX Ingress Bisa Handle Challenge

cert-manager akan otomatis buat Ingress sementara untuk
path `/.well-known/acme-challenge/`. NGINX Ingress harus running
dan IngressClass `nginx` harus ada.

---

## Bagian 4 — Tambah TLS ke Ingress

### 4.1 Update Ingress ArgoCD dengan TLS

```bash
cat > apps/argocd/ingress.yaml << 'EOF'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-server
  namespace: argocd
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-staging
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - argocd.iksanhariji.my.id
      secretName: argocd-tls
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

Yang berubah dari versi HTTP:
- Annotation `cert-manager.io/cluster-issuer` -> trigger cert-manager
- Section `tls:` -> definisikan host dan secret untuk certificate

### 4.2 Pantau Proses Issue Certificate

```bash
# Cek Certificate resource
kubectl get certificate -n argocd

# Awalnya READY: False, tunggu beberapa menit
# NAME         READY   SECRET
# argocd-tls   False   argocd-tls

# Cek detail kalau lama
kubectl describe certificate argocd-tls -n argocd

# Cek challenge yang sedang berjalan
kubectl get challenge -n argocd
```

### 4.3 Verifikasi Certificate Berhasil

```bash
kubectl get certificate -n argocd
```

Output sukses:
```
NAME         READY   SECRET       AGE
argocd-tls   True    argocd-tls   2m
```

`READY: True` artinya certificate berhasil di-issue.

### 4.4 Test HTTPS (Staging)

```bash
# Staging certificate TIDAK trusted browser
# Pakai -k untuk skip verifikasi
curl -vk https://argocd.iksanhariji.my.id
```

Cek bagian certificate di output:
```
issuer: (STAGING) Let's Encrypt
```

Kalau muncul "STAGING" -> berarti flow bekerja, tinggal ganti ke prod.

---

## Bagian 5 — Switch ke Production Certificate

Setelah staging terbukti bekerja, ganti ke production.

### 5.1 Update Annotation

```bash
# Ganti cluster-issuer dari staging ke prod
kubectl annotate ingress argocd-server -n argocd \
  cert-manager.io/cluster-issuer=letsencrypt-prod --overwrite

# Hapus secret staging supaya cert-manager request ulang
kubectl delete secret argocd-tls -n argocd
```

### 5.2 Pantau Issue Certificate Production

```bash
kubectl get certificate -n argocd -w
```

Tunggu sampai `READY: True`.

### 5.3 Verifikasi HTTPS Production

```bash
# Tanpa -k, karena production cert trusted
curl -v https://argocd.iksanhariji.my.id
```

Buka di browser -> harus muncul gembok hijau (secure).

---

## Bagian 6 — Apply ke Semua Aplikasi

Update Ingress monitoring (Grafana + Prometheus) dengan TLS:

```bash
cat > apps/monitoring/ingress.yaml << 'EOF'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: monitoring
  namespace: monitoring
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - grafana.iksanhariji.my.id
      secretName: grafana-tls
    - hosts:
        - prometheus.iksanhariji.my.id
      secretName: prometheus-tls
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

> Catatan: setiap host punya `secretName` sendiri. cert-manager
> akan issue certificate terpisah per host.

---

## Bagian 7 — Force HTTPS Redirect

Supaya user yang akses HTTP otomatis redirect ke HTTPS:

```yaml
metadata:
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
```

`force-ssl-redirect: true` -> HTTP otomatis redirect ke HTTPS,
bahkan sebelum masuk ke aplikasi.

---

## Bagian 8 — Auto-Renew

cert-manager otomatis renew certificate. Tidak perlu action manual.

```
Let's Encrypt certificate valid 90 hari
  ↓
cert-manager cek setiap hari
  ↓
30 hari sebelum expired -> auto-renew
  ↓
Secret di-update otomatis
  ↓
NGINX Ingress reload certificate baru
```

Verifikasi tanggal expiry:
```bash
kubectl get certificate -n argocd \
  -o jsonpath='{.items[0].status.notAfter}'
```

---

## Bagian 9 — Troubleshooting

### Certificate stuck READY: False

```bash
# Cek detail certificate
kubectl describe certificate <name> -n <namespace>

# Cek certificaterequest
kubectl get certificaterequest -n <namespace>
kubectl describe certificaterequest <name> -n <namespace>

# Cek challenge
kubectl get challenge -n <namespace>
kubectl describe challenge <name> -n <namespace>
```

### Challenge stuck pending

Penyebab umum:
1. DNS belum propagasi -> `dig +short <domain>` harus return IP ALB
2. Port 80 tidak accessible dari internet
3. ALB tidak route `/.well-known/acme-challenge/` ke NGINX

Test manual:
```bash
# Buat dummy file challenge path harus accessible
curl -v http://<domain>/.well-known/acme-challenge/test
# Harus dapat response dari NGINX (404 OK), bukan timeout
```

### Error: rate limit exceeded

Penyebab: terlalu sering request production certificate.

Let's Encrypt production rate limit:
- 5 duplicate certificate per minggu
- 50 certificate per domain per minggu

Fix: pakai staging dulu untuk testing, baru production.

### Browser tetap "Not Secure" padahal certificate READY

Penyebab: masih pakai certificate staging.

Fix:
```bash
# Cek issuer certificate
kubectl get secret <tls-secret> -n <namespace> \
  -o jsonpath='{.data.tls\.crt}' | base64 -d | \
  openssl x509 -noout -issuer

# Kalau "STAGING" -> switch ke letsencrypt-prod (Bagian 5)
```

### cert-manager webhook error

```bash
# Restart cert-manager
kubectl rollout restart deployment -n cert-manager
```

---

## Bagian 10 — Checklist TLS

### Sebelum Setup TLS
- [ ] cert-manager 3 pod Running
- [ ] CRD cert-manager terinstall
- [ ] DNS sudah propagasi (return IP ALB)
- [ ] Port 80 accessible dari internet (untuk HTTP-01)

### Setup ClusterIssuer
- [ ] Email valid di ClusterIssuer
- [ ] ClusterIssuer staging READY: True
- [ ] ClusterIssuer prod READY: True

### Per Ingress
- [ ] Annotation `cert-manager.io/cluster-issuer` ada
- [ ] Section `tls:` dengan host dan secretName
- [ ] Test staging dulu sebelum production
- [ ] Certificate READY: True
- [ ] Browser muncul gembok hijau (production)

### Production Hardening
- [ ] `force-ssl-redirect: true` -> HTTP redirect ke HTTPS
- [ ] Ganti semua dari staging ke prod issuer
- [ ] Verifikasi auto-renew (cek notAfter date)

---

## Bagian 11 — Production Best Practice

### Wildcard Certificate (DNS-01)

Untuk banyak subdomain, pakai wildcard `*.iksanhariji.my.id`
dengan DNS-01 challenge. Butuh:
- Akses API DNS provider
- Secret credential DNS provider
- ClusterIssuer dengan solver `dns01`

Keuntungan: 1 certificate untuk semua subdomain.

### Simpan Manifest di Git (GitOps)

Semua resource TLS harus di Git:
```
k8s-manifests/
├── platform/
│   └── cert-manager/
│       ├── clusterissuer-staging.yaml
│       └── clusterissuer-prod.yaml
└── apps/
    ├── argocd/
    │   └── ingress.yaml      (sudah ada TLS)
    └── monitoring/
        └── ingress.yaml      (sudah ada TLS)
```

> Certificate Secret JANGAN di-commit ke Git -> auto-generated
> oleh cert-manager. Cukup commit ClusterIssuer dan Ingress.

### Monitoring Certificate Expiry

Set alert di Prometheus kalau certificate mau expired:
```yaml
- alert: CertificateExpiringSoon
  expr: certmanager_certificate_expiration_timestamp_seconds - time() < 7 * 86400
  annotations:
    summary: "Certificate {{ $labels.name }} expires in less than 7 days"
```

cert-manager harusnya auto-renew, tapi alert ini sebagai
safety net kalau renew gagal.

---

## Bagian 12 — Key Takeaway

- HTTP cukup untuk lab, HTTPS wajib untuk production
- cert-manager + Let's Encrypt = certificate gratis + auto-renew
- SELALU test dengan staging dulu (production punya rate limit ketat)
- HTTP-01 challenge butuh port 80 accessible dari internet
- DNS-01 challenge untuk wildcard certificate
- Certificate Secret auto-generated, jangan di-commit ke Git
- ClusterIssuer dan Ingress harus di Git untuk GitOps
- Auto-renew otomatis 30 hari sebelum expired
- Tetap pasang alert expiry sebagai safety net

Kenapa ini penting untuk karir:
- Semua production Kubernetes pakai HTTPS
- cert-manager adalah standar industri (bukan vendor-specific)
- Skill ini transferable ke EKS, GKE, AKS, on-premise
- Interview sering tanya: "bagaimana manage TLS di Kubernetes?"

---

*Lanjutan dari runbook NGINX Ingress*
*Cluster: Self-managed K8s di AWS | Domain: iksanhariji.my.id*
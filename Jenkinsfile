pipeline {
  agent any

  parameters {
    booleanParam(
      name: 'RESET_STATE',
      defaultValue: false,
      description: 'Centang HANYA saat sandbox AWS baru.'
    )
    booleanParam(
      name: 'AUTO_DESTROY_ON_FAILURE',
      defaultValue: false,
      description: 'Centang kalau mau cleanup otomatis saat gagal. Off = infra dibiarkan untuk inspeksi manual.'
    )
    string(
      name: 'MANIFEST_REF',
      defaultValue: 'main',
      description: 'Branch/tag/SHA dari aws-k8s-manifests yang akan dideploy.'
    )
  }

  options {
    timeout(time: 45, unit: 'MINUTES')
    disableConcurrentBuilds()
    ansiColor('xterm')
    timestamps()
  }

  environment {
    AWS_DEFAULT_REGION        = 'us-east-1'
    TF_IN_AUTOMATION          = 'true'
    ANSIBLE_HOST_KEY_CHECKING = 'False'
    INV                       = 'ansible/inventory/hosts.ini'
    MANIFEST_BASE             = "https://raw.githubusercontent.com/iksanh/aws-k8s-manifests/${params.MANIFEST_REF}"
  }

  stages {

    stage('1. Checkout') {
      steps {
        checkout scm
      }
    }

    stage('2. Reset Terraform State') {
      when { expression { params.RESET_STATE } }
      steps {
        sh 'rm -f terraform.tfstate terraform.tfstate.backup'
      }
    }

    stage('3. Terraform Apply — Fase 1 (no HTTPS)') {
      steps {
        withCredentials([string(credentialsId: 'db-password', variable: 'TF_VAR_db_password')]) {
          sh '''
            terraform init -input=false
            terraform apply -auto-approve -input=false -var enable_https_listener=false
          '''
        }
      }
    }

    stage('4. Wait ACM ISSUED') {
      steps {
        sh '''
          CERT_ARN=$(terraform output -raw acm_certificate_arn)
          for i in $(seq 1 40); do
            STATUS=$(aws acm describe-certificate \
                      --certificate-arn "$CERT_ARN" \
                      --region us-east-1 \
                      --query 'Certificate.Status' \
                      --output text)
            echo "ACM status: $STATUS ($i/40)"
            [ "$STATUS" = "ISSUED" ] && exit 0
            sleep 30
          done
          echo "ACM tidak ISSUED setelah ~20 menit (cek CNAME di Hostinger)"
          exit 1
        '''
      }
    }

    stage('5. Terraform Apply — Fase 2 (enable HTTPS)') {
      steps {
        withCredentials([string(credentialsId: 'db-password', variable: 'TF_VAR_db_password')]) {
          sh 'terraform apply -auto-approve -input=false -var enable_https_listener=true'
        }
      }
    }

    stage('6. Generate Ansible Inventory') {
      steps {
        sh '''#!/usr/bin/env bash
          set -euo pipefail
          export KNOWN_HOSTS_FILE="$WORKSPACE/.known_hosts"
          mkdir -p "$(dirname "$KNOWN_HOSTS_FILE")"
          touch "$KNOWN_HOSTS_FILE"
          source scripts/set-env.sh
          bash scripts/generate-inventory.sh
          cat "$INV"
        '''
      }
    }

    stage('7. Wait Nodes & Join Workers') {
      steps {
        sshagent(['k8s-ssh-key']) {
          sh '''#!/usr/bin/env bash
            set -euo pipefail
            source scripts/set-env.sh
            export ANSIBLE_SSH_ARGS="-o ForwardAgent=yes"

            # Wait all nodes reachable
            for i in $(seq 1 20); do
              ansible all -i "$INV" -m ping && break
              echo "Node belum siap, retry $i/20..."
              sleep 15
            done

            # Cek workers sudah join atau belum
            NODE_COUNT=$(ansible cp-1 -i "$INV" -b -m shell \
              -a "KUBECONFIG=/etc/kubernetes/admin.conf kubectl get nodes --no-headers | wc -l" \
              | tail -1 | tr -d "[:space:]")
            echo "Jumlah node terdaftar: $NODE_COUNT"

            if [ "$NODE_COUNT" -ge 3 ]; then
              echo "Workers sudah join, skip kubeadm join."
            else
              echo "Workers belum join, generate token dan join..."
              JOIN=$(ansible cp-1 -i "$INV" -b -m shell \
                       -a "kubeadm token create --print-join-command" | grep -E "^kubeadm join")
              ansible workers -i "$INV" -b -m shell -a "$JOIN" --timeout=120
            fi
          '''
        }
      }
    }

    stage('8. Verify Cluster Ready') {
      steps {
        sshagent(['k8s-ssh-key']) {
          sh '''#!/usr/bin/env bash
            set -euo pipefail
            source scripts/set-env.sh
            for i in $(seq 1 12); do
              OUT=$(ansible cp-1 -i "$INV" -m shell \
                     -a "KUBECONFIG=/etc/kubernetes/admin.conf kubectl get nodes --no-headers")
              echo "$OUT"
              echo "$OUT" | grep -q "NotReady" || { echo "Semua node Ready"; exit 0; }
              echo "Tunggu Calico CNI... $i/12"
              sleep 15
            done
            echo "Ada node NotReady"
            exit 1
          '''
        }
      }
    }

    stage('9. Install Cluster Tools (parallel)') {
      parallel {
        stage('Install Helm') {
          steps {
            sshagent(['k8s-ssh-key']) {
              sh '''#!/usr/bin/env bash
                set -euo pipefail
                source scripts/set-env.sh
                ansible cp-1 -i "$INV" -b -m shell -a '
                  if ! command -v helm >/dev/null 2>&1; then
                    curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
                    chmod 700 get_helm.sh
                    ./get_helm.sh
                    rm -f get_helm.sh
                  else
                    echo "Helm already installed: $(helm version --short)"
                  fi
                '
              '''
            }
          }
        }

        stage('Install ArgoCD') {
          steps {
            sshagent(['k8s-ssh-key']) {
              sh '''#!/usr/bin/env bash
                set -euo pipefail
                source scripts/set-env.sh
                ansible cp-1 -i "$INV" -b -m shell -a '
                  export KUBECONFIG=/etc/kubernetes/admin.conf
                  kubectl get ns argocd >/dev/null 2>&1 || kubectl create namespace argocd
                  kubectl apply -n argocd --server-side --force-conflicts \
                    -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.0.0/manifests/install.yaml
                  kubectl rollout status deployment argocd-server -n argocd --timeout=300s
                '
              '''
            }
          }
        }

        stage('Install apache2-utils on cp-1') {
          steps {
            sshagent(['k8s-ssh-key']) {
              sh '''#!/usr/bin/env bash
                set -euo pipefail
                source scripts/set-env.sh
                ansible cp-1 -i "$INV" -b -m apt \
                  -a "name=apache2-utils state=present update_cache=yes"
              '''
            }
          }
        }
      }
    }

    stage('10. Install AWS EBS CSI Driver') {
      steps {
        sshagent(['k8s-ssh-key']) {
          sh '''#!/usr/bin/env bash
            set -euo pipefail
            source scripts/set-env.sh
            ansible cp-1 -i "$INV" -b -m shell -a '
              export KUBECONFIG=/etc/kubernetes/admin.conf

              # Idempotent: check if release already exists
              if helm status aws-ebs-csi-driver -n kube-system >/dev/null 2>&1; then
                echo "EBS CSI driver already installed, skip."
              else
                helm repo add aws-ebs-csi-driver \
                  https://kubernetes-sigs.github.io/aws-ebs-csi-driver
                helm repo update
                helm install aws-ebs-csi-driver \
                  aws-ebs-csi-driver/aws-ebs-csi-driver \
                  --namespace kube-system \
                  --wait --timeout 5m
              fi

              kubectl get pods -n kube-system | grep ebs-csi || true
            '
          '''
        }
      }
    }

    stage('11. Bootstrap Monitoring Secrets') {
      steps {
        sshagent(['k8s-ssh-key']) {
          withCredentials([
            string(credentialsId: 'grafana-admin-pass', variable: 'GRAFANA_PASS'),
            string(credentialsId: 'prometheus-basic-pass', variable: 'PROM_PASS')
          ]) {
            sh '''#!/usr/bin/env bash
              set -euo pipefail
              source scripts/set-env.sh

              ansible cp-1 -i "$INV" -b -m shell \
                -e "grafana_pass=$GRAFANA_PASS" \
                -e "prom_pass=$PROM_PASS" \
                -e "manifest_base=$MANIFEST_BASE" \
                -a '
                  export KUBECONFIG=/etc/kubernetes/admin.conf

                  # Namespace dulu sebelum ArgoCD ambil alih
                  kubectl get ns monitoring >/dev/null 2>&1 || \
                    kubectl create namespace monitoring

                  # Grafana admin secret (idempotent via dry-run apply)
                  kubectl create secret generic grafana-admin -n monitoring \
                    --from-literal=admin-user=admin \
                    --from-literal=admin-password="$grafana_pass" \
                    --dry-run=client -o yaml | kubectl apply -f -

                  # Prometheus basic auth — htpasswd batch mode (-b)
                  htpasswd -bc /tmp/auth admin "$prom_pass"
                  kubectl create secret generic prometheus-basic-auth -n monitoring \
                    --from-file=auth=/tmp/auth \
                    --dry-run=client -o yaml | kubectl apply -f -
                  rm -f /tmp/auth

                  # StorageClass gp3 (cluster-scoped)
                  kubectl get storageclass gp3 >/dev/null 2>&1 || \
                    kubectl apply -f "$manifest_base/apps/monitoring/storageclass.yaml"
                '
            '''
          }
        }
      }
    }

    stage('12. Deploy App of Apps') {
      steps {
        sshagent(['k8s-ssh-key']) {
          sh '''#!/usr/bin/env bash
            set -euo pipefail
            source scripts/set-env.sh
            ansible cp-1 -i "$INV" -b -m shell \
              -e "manifest_base=$MANIFEST_BASE" \
              -a '
                export KUBECONFIG=/etc/kubernetes/admin.conf
                kubectl apply -f "$manifest_base/bootstrap/root-app.yaml"
              '
          '''
        }
      }
    }

    stage('13. Wait All Apps Synced') {
      steps {
        sshagent(['k8s-ssh-key']) {
          sh '''#!/usr/bin/env bash
            set -euo pipefail
            source scripts/set-env.sh
            ansible cp-1 -i "$INV" -b -m shell -a '
              export KUBECONFIG=/etc/kubernetes/admin.conf
              for i in $(seq 1 30); do
                APPS=$(kubectl get applications -n argocd --no-headers 2>/dev/null || true)
                if [ -z "$APPS" ]; then
                  echo "Belum ada Application di-create, tunggu... $i/30"
                  sleep 20
                  continue
                fi

                echo "$APPS"
                NOT_READY=$(echo "$APPS" | awk "{print \\$2 \\\" \\\" \\$3}" | grep -cv "^Synced Healthy$" || true)

                if [ "$NOT_READY" -eq 0 ]; then
                  echo "Semua app Synced + Healthy"
                  exit 0
                fi

                echo "Masih ada $NOT_READY app belum siap, retry $i/30..."
                sleep 20
              done

              echo "Timeout: ada app yang belum Synced/Healthy"
              kubectl get applications -n argocd
              exit 1
            '
          '''
        }
      }
    }

    stage('14. Smoke Test') {
      steps {
        sh '''#!/usr/bin/env bash
          set -euo pipefail
          ALB_DNS=$(terraform output -raw alb_dns_name)
          echo "ALB DNS: $ALB_DNS"

          # Optional: test endpoint kalau DNS sudah resolve
          for host in argocd grafana fastapi; do
            URL="https://${host}.iksanhariji.my.id/"
            CODE=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 10 "$URL" || echo "000")
            echo "$URL -> HTTP $CODE"
          done
        '''
      }
    }
  }

  post {
    failure {
      script {
        if (params.AUTO_DESTROY_ON_FAILURE) {
          echo 'Auto-destroy aktif. Membersihkan...'
          withCredentials([string(credentialsId: 'db-password', variable: 'TF_VAR_db_password')]) {
            sh 'terraform destroy -auto-approve -input=false -var enable_https_listener=false || true'
          }
        } else {
          echo 'Build gagal. Infra DIBIARKAN untuk inspeksi. Jalankan terraform destroy manual jika perlu.'
        }
      }
    }
    success {
      echo 'Lab siap. Akses:'
      echo '  ArgoCD     : https://argocd.iksanhariji.my.id'
      echo '  Grafana    : https://grafana.iksanhariji.my.id'
      echo '  Prometheus : https://prometheus.iksanhariji.my.id'
      echo '  FastAPI    : https://fastapi.iksanhariji.my.id'
    }
    always {
      cleanWs(patterns: [[pattern: '.known_hosts', type: 'INCLUDE']])
    }
  }
}
pipeline {
  agent any

  parameters {
    booleanParam(name: 'RESET_STATE', defaultValue: false,
                 description: 'Centang HANYA saat sandbox AWS baru.')
    booleanParam(name: 'AUTO_DESTROY_ON_FAILURE', defaultValue: false,
                 description: 'Centang kalau mau cleanup otomatis saat gagal. Off = infra dibiarkan, kamu inspeksi manual.')
  }

  options {
    timeout(time: 45, unit: 'MINUTES')
    disableConcurrentBuilds()
  }

  environment {
    AWS_DEFAULT_REGION        = 'us-east-1'
    TF_IN_AUTOMATION          = 'true'
    ANSIBLE_HOST_KEY_CHECKING = 'False'
    INV                       = 'ansible/inventory/hosts.ini'
  }

  stages {

    stage('1. Checkout') {
      steps { checkout scm }
    }

    stage('2. Reset State (tf-reset)') {
      when { expression { params.RESET_STATE } }
      steps {
        sh 'rm -f terraform.tfstate terraform.tfstate.backup'
      }
    }

    stage('3. Apply — fase 1 (ACM belum issued)') {
      steps {
        withCredentials([string(credentialsId: 'db-password', variable: 'TF_VAR_db_password')]) {
          sh 'terraform init -input=false'
          sh 'terraform apply -auto-approve -input=false -var enable_https_listener=false'
        }
      }
    }

    stage('4. Tunggu ACM ISSUED') {
      steps {
        sh '''
          CERT_ARN=$(terraform output -raw acm_certificate_arn)
          for i in $(seq 1 40); do
            STATUS=$(aws acm describe-certificate --certificate-arn "$CERT_ARN" \
                      --region us-east-1 --query 'Certificate.Status' --output text)
            echo "ACM status: $STATUS ($i/40)"
            [ "$STATUS" = "ISSUED" ] && exit 0
            sleep 30
          done
          echo "ACM tidak ISSUED setelah ~20 menit (cek CNAME di Hostinger)"; exit 1
        '''
      }
    }

    stage('5. Apply — fase 2 (enable HTTPS listener)') {
      steps {
        withCredentials([string(credentialsId: 'db-password', variable: 'TF_VAR_db_password')]) {
          sh 'terraform apply -auto-approve -input=false -var enable_https_listener=true'
        }
      }
    }

    stage('6. Set env + generate inventory') {
      steps {
        sh '''#!/usr/bin/env bash
          set -e
          export KNOWN_HOSTS_FILE="$WORKSPACE/.known_hosts"
          mkdir -p "$(dirname "$KNOWN_HOSTS_FILE")"
          touch "$KNOWN_HOSTS_FILE"
          source scripts/set-env.sh
          bash scripts/generate-inventory.sh
          cat "$INV"
        '''
      }
    }

    stage('7. Tunggu node siap + join workers') {
      steps {
        sh '''#!/usr/bin/env bash
          set -e
          eval "$(ssh-agent -s)"
          ssh-add /var/jenkins_home/.ssh/id_rsa
          source scripts/set-env.sh
          export ANSIBLE_SSH_ARGS="-o ForwardAgent=yes"

          for i in $(seq 1 20); do
            ansible all -i "$INV" -m ping && break
            echo "node belum siap, retry $i/20..."; sleep 15
          done

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

    stage('8. Verify cluster Ready') {
      steps {
        sh '''#!/usr/bin/env bash
          set -e
          source scripts/set-env.sh
          for i in $(seq 1 12); do
            OUT=$(ansible cp-1 -i "$INV" -m shell -a "kubectl get nodes --no-headers")
            echo "$OUT"
            echo "$OUT" | grep -q "NotReady" || { echo "semua Ready"; exit 0; }
            echo "tunggu Calico CNI... $i/12"; sleep 15
          done
          echo "ada node NotReady"; exit 1
        '''
      }
    }

    stage('9. Install Helm') {
      steps {
        sh '''#!/usr/bin/env bash
          set -e
          source scripts/set-env.sh
          ansible cp-1 -i "$INV" -b -m shell -a '
            if ! command -v helm >/dev/null 2>&1; then
                curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
                chmod 700 get_helm.sh
                ./get_helm.sh
            else
                echo "helm already installed: $(helm version --short)"
            fi
          '
        '''
      }
    }

    stage('10. Install ArgoCD') {
      steps {
        sh '''#!/usr/bin/env bash
          set -e
          eval "$(ssh-agent -s)"
          ssh-add /var/jenkins_home/.ssh/id_rsa
          source scripts/set-env.sh
          ansible cp-1 -i "$INV" -b -m shell -a "
            export KUBECONFIG=/etc/kubernetes/admin.conf &&
            kubectl get ns argocd >/dev/null 2>&1 || kubectl create namespace argocd &&
            kubectl apply -n argocd --server-side --force-conflicts \
              -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.0.0/manifests/install.yaml &&
            kubectl rollout status deployment argocd-server -n argocd --timeout=300s
          "
        '''
      }
    }

    stage('11. Install EBS CSI Driver') {
      steps {
        sh '''#!/usr/bin/env bash
          set -e
          source scripts/set-env.sh
          ansible cp-1 -i "$INV" -b -m shell -a "
            helm repo add aws-ebs-csi-driver \
              https://kubernetes-sigs.github.io/aws-ebs-csi-driver
            helm repo update

            helm status aws-ebs-csi-driver -n kube-system >/dev/null 2>&1 || \
              helm install aws-ebs-csi-driver \
                aws-ebs-csi-driver/aws-ebs-csi-driver \
                --namespace kube-system

            kubectl get pods -n kube-system | grep ebs-csi || true
          "
        '''
      }
    }

    stage('12. Configure Secret untuk Grafana & Prometheus') {
      steps {
        withCredentials([
          string(credentialsId: 'grafana-admin-pass', variable: 'GRAFANA_PASS'),
          string(credentialsId: 'prometheus-basic-pass', variable: 'PROM_PASS')
        ]) {
          sh '''#!/usr/bin/env bash
            set -e
            source scripts/set-env.sh

            ansible cp-1 -i "$INV" -b -m apt \
              -a "name=apache2-utils state=present update_cache=yes"

            ansible cp-1 -i "$INV" -b -m shell \
              -e "gp=$GRAFANA_PASS" \
              -e "pp=$PROM_PASS" \
              -a '
                kubectl get ns monitoring >/dev/null 2>&1 || kubectl create namespace monitoring

                kubectl create secret generic grafana-admin -n monitoring \
                  --from-literal=admin-user=admin \
                  --from-literal=admin-password="$gp" \
                  --dry-run=client -o yaml | kubectl apply -f -

                htpasswd -bc /tmp/auth admin "$pp"
                kubectl create secret generic prometheus-basic-auth -n monitoring \
                  --from-file=auth=/tmp/auth \
                  --dry-run=client -o yaml | kubectl apply -f -
                rm -f /tmp/auth

                kubectl get storageclass gp3 >/dev/null 2>&1 || \
                  kubectl apply -f https://raw.githubusercontent.com/iksanh/aws-k8s-manifests/main/apps/monitoring/resources/storageclass.yaml
              '
          '''
        }
      }
    }

    stage('13. Install Apps of apps') {
      steps {
        sh '''#!/usr/bin/env bash
          set -e
          source scripts/set-env.sh
          ansible cp-1 -i "$INV" -b -m shell -a "
            kubectl apply -f https://raw.githubusercontent.com/iksanh/aws-k8s-manifests/main/bootstrap/root-app.yaml
          "
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
    success { echo 'Lab siap.' }
  }
}
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
          source scripts/set-env.sh
          for i in $(seq 1 20); do
            ansible all -i "$INV" -m ping && break
            echo "node belum siap, retry $i/20..."; sleep 15
          done

          JOIN=$(ansible cp-1 -i "$INV" -m shell -b \
                   -a 'kubeadm token create --print-join-command' | grep -E '^kubeadm join')
          ansible workers -i "$INV" -b -m shell -a "$JOIN" --timeout=120
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

    stage('9. Install Helm + ArgoCD') {
      steps {
        sh '''#!/usr/bin/env bash
          set -e
          source scripts/set-env.sh
          ansible cp-1 -i "$INV" -b -m shell -a "
            command -v helm >/dev/null 2>&1 || (curl -fsSL -o /tmp/get_helm.sh \
              https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 && \
              bash /tmp/get_helm.sh) &&
            kubectl get ns argocd >/dev/null 2>&1 || kubectl create namespace argocd &&
            kubectl apply -n argocd --server-side --force-conflicts \
              -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.0.0/manifests/install.yaml &&
            kubectl rollout status deployment argocd-server -n argocd --timeout=300s &&
            kubectl apply -f https://raw.githubusercontent.com/iksanh/aws-k8s-manifests/main/apps/argo-cd/argocd-self.yaml
          "
        '''
      }
    }

    stage('10. Install Prometheus + Grafana stack') {
      steps {
        withCredentials([
          string(credentialsId: 'grafana-admin-pass', variable: 'GRAFANA_PASS'),
          string(credentialsId: 'prometheus-basic-pass', variable: 'PROM_PASS')
        ]) {
          sh '''#!/usr/bin/env bash
            set -e
            source scripts/set-env.sh
            ansible cp-1 -i "$INV" -b -m apt -a "name=apache2-utils state=present update_cache=yes"
            ansible cp-1 -i "$INV" -b -m shell -a "
              kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f - &&

              kubectl create secret generic grafana-admin -n monitoring \
                --from-literal=admin-user=admin \
                --from-literal=admin-password='$GRAFANA_PASS' \
                --dry-run=client -o yaml | kubectl apply -f - &&

              htpasswd -nbB admin '$PROM_PASS' > /tmp/auth &&
              kubectl create secret generic prometheus-basic-auth -n monitoring \
                --from-file=auth=/tmp/auth --dry-run=client -o yaml | kubectl apply -f - &&
              rm -f /tmp/auth &&

              helm repo add aws-ebs-csi-driver https://kubernetes-sigs.github.io/aws-ebs-csi-driver &&
              helm repo update &&
              helm upgrade --install aws-ebs-csi-driver aws-ebs-csi-driver/aws-ebs-csi-driver -n kube-system &&

              kubectl apply -f https://raw.githubusercontent.com/iksanh/aws-k8s-manifests/main/apps/monitoring/storageclass.yaml &&
              kubectl apply -f https://raw.githubusercontent.com/iksanh/aws-k8s-manifests/main/apps/monitoring/application.yaml &&
              kubectl apply -f https://raw.githubusercontent.com/iksanh/aws-k8s-manifests/main/apps/monitoring/ingress-monitoring.yaml
            "
          '''
        }
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
}

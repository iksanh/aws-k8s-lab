#!/bin/bash
# generate-inventory.sh
# Run from anywhere — script auto-navigates to project root

set -e

# Navigate to project root regardless of where script is executed
cd "$(dirname "$0")/.."

# Check if jq is installed, install if not found
if ! command -v jq &> /dev/null; then
  echo "⚠️  jq not found — installing..."
  if command -v apt-get &> /dev/null; then
    sudo apt-get update -y && sudo apt-get install -y jq
  elif command -v yum &> /dev/null; then
    sudo yum install -y jq
  elif command -v brew &> /dev/null; then
    brew install jq
  else
    echo "❌ Cannot install jq — unsupported package manager. Please install manually."
    exit 1
  fi
  echo "✅ jq installed successfully"
else
  echo "✅ jq already installed — $(jq --version)"
fi

OUTPUT_DIR="./ansible/inventory"
mkdir -p "$OUTPUT_DIR"

# Fetch outputs from Terraform
BASTION_IP=$(terraform output -raw bastion_public_ip)
CP_IPS=$(terraform output -json control_plane_private_ips | jq -r '.[]')
WORKER_IPS=$(terraform output -json worker_private_ips | jq -r '.[]')
SSH_KEY="~/.ssh/id_rsa"

# Generate hosts.ini — bastion section
cat > "$OUTPUT_DIR/hosts.ini" <<EOF
[bastion]
bastion ansible_host=${BASTION_IP} ansible_user=ubuntu ansible_ssh_private_key_file=${SSH_KEY}

[control_plane]
EOF

# Loop through control plane IPs
idx=1
for ip in $CP_IPS; do
  echo "cp-${idx} ansible_host=${ip} ansible_user=ubuntu ansible_ssh_private_key_file=${SSH_KEY}" >> "$OUTPUT_DIR/hosts.ini"
  ((idx++))
done

# Append workers section header
cat >> "$OUTPUT_DIR/hosts.ini" <<EOF

[workers]
EOF

# Loop through worker IPs
idx=1
for ip in $WORKER_IPS; do
  echo "worker-${idx} ansible_host=${ip} ansible_user=ubuntu ansible_ssh_private_key_file=${SSH_KEY}" >> "$OUTPUT_DIR/hosts.ini"
  ((idx++))
done

# Append group definitions and shared SSH proxy config
cat >> "$OUTPUT_DIR/hosts.ini" <<EOF

[k8s_cluster:children]
control_plane
workers

[k8s_cluster:vars]
ansible_ssh_common_args='-o StrictHostKeyChecking=no -o ProxyJump=ubuntu@${BASTION_IP}'
EOF

echo "✅ Inventory generated at $OUTPUT_DIR/hosts.ini"
cat "$OUTPUT_DIR/hosts.ini"
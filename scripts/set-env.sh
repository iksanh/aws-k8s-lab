#!/bin/bash
# set-env.sh
# Auto-generate environment variables from Terraform output
# Usage: source scripts/set-env.sh

# Navigate to project root
cd "$(dirname "$0")/.."

echo "🔍 Fetching Terraform outputs..."

# Bastion — single value
export BASTION_IP=$(terraform output -raw bastion_public_ip)

# Control Plane — dynamic array
mapfile -t CP_IPS_ARRAY < <(terraform output -json control_plane_private_ips | jq -r '.[]')

# Worker — dynamic array
mapfile -t WORKER_IPS_ARRAY < <(terraform output -json worker_private_ips | jq -r '.[]')

# Export as indexed variables
for i in "${!CP_IPS_ARRAY[@]}"; do
  export "CP$((i+1))_IP=${CP_IPS_ARRAY[$i]}"
done

for i in "${!WORKER_IPS_ARRAY[@]}"; do
  export "WORKER$((i+1))_IP=${WORKER_IPS_ARRAY[$i]}"
done

# Print summary
echo ""
echo "✅ Environment variables loaded:"
echo "   BASTION_IP = $BASTION_IP"

for i in "${!CP_IPS_ARRAY[@]}"; do
  varname="CP$((i+1))_IP"
  echo "   $varname = ${!varname}"
done

for i in "${!WORKER_IPS_ARRAY[@]}"; do
  varname="WORKER$((i+1))_IP"
  echo "   $varname = ${!varname}"
done

echo ""

# Export full arrays for loop usage
export CP_IPS="${CP_IPS_ARRAY[*]}"
export WORKER_IPS="${WORKER_IPS_ARRAY[*]}"
export ALL_NODE_IPS="${CP_IPS_ARRAY[*]} ${WORKER_IPS_ARRAY[*]}"

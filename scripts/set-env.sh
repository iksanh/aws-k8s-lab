#!/bin/bash
# set-env.sh
# Auto-generate environment variables from Terraform output
# Usage: source scripts/set-env.sh

# Navigate to project root regardless of where script is executed
cd "$(dirname "${BASH_SOURCE[0]}")/.."

echo "Fetching Terraform outputs..."

# single-value outputs
export BASTION_IP=$(terraform output -raw bastion_public_ip)
export NLB_DNS=$(terraform output -raw nlb_dns)
export ALB_DNS=$(terraform output -raw alb_dns)

# Control Plane IPS - dynamic array
mapfile -t CP_IPS_ARRAY < <(terraform output -json control_plane_private_ips | jq -r '.[]')

# Workers IPs - dynamic array
mapfile -t WORKER_IPS_ARRAY < <(terraform output -json worker_private_ips | jq -r '.[]')

# Export CP IPs as indexed variables
for i in "${!CP_IPS_ARRAY[@]}"; do
  export "CP$((i+1))_IP=${CP_IPS_ARRAY[$i]}"
done

# Export Worker IPs as indexed variables
for i in "${!WORKER_IPS_ARRAY[@]}"; do
  export "WORKER$((i+1))_IP=${WORKER_IPS_ARRAY[$i]}"
done

# Export full arrays for loop usage
export CP_IPS="${CP_IPS_ARRAY[*]}"
export WORKER_IPS="${WORKER_IPS_ARRAY[*]}"
export ALL_NODE_IPS="${CP_IPS_ARRAY[*]} ${WORKER_IPS_ARRAY[*]}"

# Print summary
echo "Environment variables loaded:"
echo "  BASTION_IP = $BASTION_IP"
echo "  NLB_DNS    = $NLB_DNS"
echo "  ALB_DNS    = $ALB_DNS"

for i in "${!CP_IPS_ARRAY[@]}"; do
  varname="CP$((i+1))_IP"
  echo "  $varname = ${!varname}"
done

for i in "${!WORKER_IPS_ARRAY[@]}"; do
  varname="WORKER$((i+1))_IP"
  echo "  $varname = ${!varname}"
done

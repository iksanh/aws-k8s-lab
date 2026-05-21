#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# helpers.sh
# Shared functions for cluster-addons install scripts
#
# Source this file at the top of each installer:
#   source "$(dirname "$0")/lib/helpers.sh"
# ═══════════════════════════════════════════════════════════════

# ─────────────────────────────────────────
# Colors for output
# ─────────────────────────────────────────
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

# ─────────────────────────────────────────
# Logging helpers
# ─────────────────────────────────────────
info()    { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }
step()    { echo -e "\n${BLUE}━━━ $1 ━━━${NC}"; }
skip()    { echo -e "${YELLOW}[SKIP]${NC} $1"; }

# ─────────────────────────────────────────
# Retry helper
# Usage: retry <max_attempts> <delay_seconds> <command...>
# Example: retry 5 10 kubectl apply -f manifest.yaml
# ─────────────────────────────────────────
retry() {
  local max_attempts=$1
  local delay=$2
  shift 2
  local attempt=1

  until "$@"; do
    if [ $attempt -ge $max_attempts ]; then
      error "Command failed after $max_attempts attempts: $*"
    fi
    warn "Attempt $attempt/$max_attempts failed, retrying in ${delay}s..."
    sleep $delay
    attempt=$((attempt + 1))
  done
}

# ─────────────────────────────────────────
# Password file management
# All passwords are saved to ~/password.txt on the node
# where this script runs (CP-1 in our setup).
# ─────────────────────────────────────────
PASSWORD_FILE="${PASSWORD_FILE:-$HOME/password.txt}"

# Initialize password file with a header (only if file doesn't exist)
init_password_file() {
  if [ ! -f "$PASSWORD_FILE" ]; then
    cat > "$PASSWORD_FILE" <<EOF
# Cluster Addons Passwords
# Generated: $(date)
# Location: $PASSWORD_FILE
#

EOF
    chmod 600 "$PASSWORD_FILE"
    info "Password file initialized: $PASSWORD_FILE"
  fi
}

# Save a credential to the password file.
# Idempotent: if the same label already exists, the line is replaced.
# Usage: save_password "<label>" "<value>"
# Example: save_password "ArgoCD admin" "abc123XYZ"
save_password() {
  local label="$1"
  local value="$2"

  init_password_file

  # Remove existing line with same label, then append fresh one
  sed -i "/^${label}:/d" "$PASSWORD_FILE"
  echo "${label}: ${value}" >> "$PASSWORD_FILE"

  info "Password saved: ${label} (file: $PASSWORD_FILE)"
}

# ─────────────────────────────────────────
# Kubernetes existence checks
# Used for idempotency — skip install if already present
# ─────────────────────────────────────────

# Returns 0 (true) if namespace exists, 1 (false) otherwise
namespace_exists() {
  kubectl get namespace "$1" >/dev/null 2>&1
}

# Returns 0 if helm release exists in given namespace
helm_release_exists() {
  local release="$1"
  local namespace="$2"
  helm status "$release" -n "$namespace" >/dev/null 2>&1
}

# Returns 0 if deployment exists in given namespace
deployment_exists() {
  local name="$1"
  local namespace="$2"
  kubectl get deployment "$name" -n "$namespace" >/dev/null 2>&1
}

# ─────────────────────────────────────────
# Wait for deployment to be ready
# Usage: wait_deployment <name> <namespace> [timeout_seconds]
# ─────────────────────────────────────────
wait_deployment() {
  local name="$1"
  local namespace="$2"
  local timeout="${3:-300}"

  info "Waiting for deployment '$name' in namespace '$namespace' (timeout: ${timeout}s)..."
  kubectl wait --for=condition=available \
    deployment/"$name" \
    -n "$namespace" \
    --timeout="${timeout}s"
}

# ─────────────────────────────────────────
# Pre-flight checks
# Verify required CLIs and cluster access before starting
# ─────────────────────────────────────────
preflight_check() {
  step "Pre-flight check"

  for cmd in kubectl helm; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      error "Required command not found: $cmd"
    fi
  done

  if ! kubectl cluster-info >/dev/null 2>&1; then
    error "Cannot reach Kubernetes cluster. Check kubeconfig."
  fi

  info "kubectl: $(kubectl version --client -o json 2>/dev/null | grep gitVersion | head -1 | tr -d ' ,"')"
  info "helm:    $(helm version --short 2>/dev/null)"
  info "cluster: $(kubectl config current-context)"
}
#!/usr/bin/env bash
set -euo pipefail

# Preflight + Deploy Wrapper
# - Validates required tools and versions
# - Ensures Kubernetes cluster is reachable
# - Then invokes the existing portable deploy script unchanged
#
# Usage:
#   ./deploy-opensearch-observability-stack-preflight.sh
#
# Environment overrides:
#   MIN_CPU_CORES   default: 4
#   MIN_MEM_MB      default: 6000
#   KUBE_CONTEXT    default: current context
#
# Note: This script does NOT modify the original deployment logic.

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR"

log() { echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
success() { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] ✅ $*${NC}"; }
warn() { echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] ⚠️  $*${NC}"; }
err() { echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ❌ $*${NC}"; }

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    err "$1 is required but not installed"; exit 1
  fi
}

check_version() {
  local tool=$1; shift
  local want=$1; shift
  local have
  have="$($tool version 2>/dev/null | head -n1 | sed -E 's/[^0-9]*([0-9]+\.[0-9]+\.[0-9]+).*/\1/')" || have=""
  if [[ -z "$have" ]]; then
    warn "Could not parse $tool version; continuing"
    return 0
  fi
  if printf '%s\n%s\n' "$want" "$have" | sort -V | head -n1 | grep -qx "$want" && \
     printf '%s\n%s\n' "$want" "$have" | sort -V | tail -n1 | grep -qx "$have"; then
    # have >= want
    return 0
  else
    err "$tool >= $want required (found $have)"; exit 1
  fi
}

check_cluster() {
  if ! kubectl cluster-info >/dev/null 2>&1; then
    err "Cannot reach a Kubernetes cluster with kubectl. Please start minikube/kind or configure kubeconfig, then retry."
    exit 1
  fi
}

check_resources() {
  local min_cpu=${MIN_CPU_CORES:-4}
  local min_mem=${MIN_MEM_MB:-6000}

  # Attempt to detect host resources (best-effort)
  local cpu_cores mem_mb
  cpu_cores=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 0)
  mem_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)

  if [[ "$cpu_cores" -lt "$min_cpu" ]]; then
    warn "Detected CPU cores $cpu_cores < recommended $min_cpu. Deployment may be slow or fail."
  fi
  if [[ "$mem_mb" -lt "$min_mem" ]]; then
    warn "Detected memory ${mem_mb}MB < recommended ${min_mem}MB. Deployment may be slow or fail."
  fi
}

check_required_files() {
  local files=(
    "$ROOT_DIR/opensearch-values.yaml"
    "$ROOT_DIR/opensearch-dashboard-values.yaml"
    "$ROOT_DIR/jaeger-values.yaml"
    "$ROOT_DIR/jaeger-config.yaml"
    "$ROOT_DIR/jaeger-query-service.yaml"
    "$ROOT_DIR/otel-demo-values.yaml"
  )
  for f in "${files[@]}"; do
    [[ -f "$f" ]] || { err "Missing required file: $f"; exit 1; }
  done
}

main() {
  log "Running preflight checks..."

  need bash
  need curl
  need kubectl
  need helm

  # Minimum versions (relaxed; adjust if you need stricter)
  check_version kubectl 1.25.0 || true
  check_version helm 3.10.0 || true

  check_required_files
  check_resources
  check_cluster

  success "Preflight checks passed"

  log "Invoking portable deployment script..."
  exec "$ROOT_DIR/deploy-opensearch-observability-stack-portable.sh"
}

main "$@"


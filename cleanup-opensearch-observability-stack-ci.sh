#!/usr/bin/env bash
set -euo pipefail

# Fast, non-interactive cleanup suitable for CI
# Uses force deletion as per preference for faster teardown.

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
success() { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] ✅ $*${NC}"; }
warn() { echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] ⚠️  $*${NC}"; }

main() {
  log "Stopping any existing port-forward processes..."
  pkill -f "kubectl port-forward" 2>/dev/null || true

  log "Uninstalling Helm releases (if present)..."
  helm uninstall otel-demo -n otel-demo 2>/dev/null || true
  helm uninstall jaeger -n jaeger 2>/dev/null || true
  helm uninstall opensearch-dashboards -n opensearch 2>/dev/null || true
  helm uninstall opensearch -n opensearch 2>/dev/null || true

  log "Deleting namespaces with force and zero grace period..."
  for ns in otel-demo jaeger opensearch; do
    kubectl delete namespace "$ns" --force --grace-period=0 2>/dev/null || true
  done

  log "Waiting briefly for resources to terminate..."
  sleep 5

  log "Cleanup complete (CI)."
  success "All teardown steps issued. Remaining resources (if any) should terminate shortly."
}

main "$@"


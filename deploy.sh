#!/usr/bin/env bash
set -euo pipefail

# Unified Deploy Script: Preflight + Deploy + Port-forward (self-contained)
# - Performs environment preflight checks
# - Pre-pulls required images
# - Deploys OpenSearch, OpenSearch Dashboards, Jaeger (local chart), and OTEL Demo
# - Verifies key services
# - Optionally starts port-forwarding at the end
#
# Usage:
#   chmod +x deploy.sh
#   ./deploy.sh
#
# Optional flags:
#   --auto-port-forward     Start port-forwarding without prompting
#   --no-port-forward       Do not prompt or start port-forwarding
#   --skip-prepull          Skip image pre-pull (not recommended)
#   --timeout <seconds>     Rollout timeout per resource (default: 600)
#
# Notes:
# - All paths resolved relative to the script directory.
# - Exits on first error.

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR"

# Defaults
AUTO_PORT_FORWARD=false
PROMPT_PORT_FORWARD=true
SKIP_PREPULL=false
ROLLOUT_TIMEOUT=600

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --auto-port-forward)
      AUTO_PORT_FORWARD=true
      PROMPT_PORT_FORWARD=false
      shift
      ;;
    --no-port-forward)
      AUTO_PORT_FORWARD=false
      PROMPT_PORT_FORWARD=false
      shift
      ;;
    --skip-prepull)
      SKIP_PREPULL=true
      shift
      ;;
    --timeout)
      ROLLOUT_TIMEOUT="${2:-600}"
      shift 2
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

log()    { echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')] $*${NC}"; }
success(){ echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] ✅ $*${NC}"; }
warn()   { echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] ⚠️  $*${NC}"; }
err()    { echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ❌ $*${NC}"; exit 1; }

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    err "$1 is required but not installed"
  fi
}

check_version() {
  local tool=$1 want=$2 have=""
  have="$($tool version 2>/dev/null | head -n1 | sed -E 's/[^0-9]*([0-9]+\.[0-9]+\.[0-9]+).*/\1/')" || have=""
  if [[ -z "$have" ]]; then
    warn "Could not parse $tool version; continuing"
    return 0
  fi
  if printf '%s\n%s\n' "$want" "$have" | sort -V | head -n1 | grep -qx "$want" && \
     printf '%s\n%s\n' "$want" "$have" | sort -V | tail -n1 | grep -qx "$have"; then
    return 0
  else
    err "$tool >= $want required (found $have)"
  fi
}

check_cluster() {
  if ! kubectl cluster-info >/dev/null 2>&1; then
    err "Cannot reach a Kubernetes cluster with kubectl. Start your cluster (e.g., minikube) and retry."
  fi
}

check_resources() {
  local min_cpu=${MIN_CPU_CORES:-4}
  local min_mem=${MIN_MEM_MB:-6000}
  local cpu_cores mem_mb
  cpu_cores=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 0)
  mem_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)
  if [[ "$cpu_cores" -lt "$min_cpu" ]]; then
    warn "Detected CPU cores $cpu_cores < recommended $min_cpu"
  fi
  if [[ "$mem_mb" -lt "$min_mem" ]]; then
    warn "Detected memory ${mem_mb}MB < recommended ${min_mem}MB"
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
    [[ -f "$f" ]] || err "Missing required file: $f"
  done
}

build_jaeger_deps() {
  local chart_dir="$ROOT_DIR/helm-charts/charts/jaeger"
  if [[ -f "$chart_dir/Chart.yaml" ]]; then
    log "Building Helm dependencies for Jaeger chart..."
    mkdir -p "$chart_dir/charts"
    helm dependency build "$chart_dir"
    success "Helm dependencies for Jaeger chart are ready"
  else
    err "Jaeger chart not found at $chart_dir"
  fi
}

# Wait helpers
wait_for_deployment() {
  local namespace=$1 deployment=$2 timeout=${3:-${ROLLOUT_TIMEOUT}s}
  log "Waiting for deployment $deployment in $namespace..."
  if ! kubectl rollout status deployment/"$deployment" -n "$namespace" --timeout="$timeout"; then
    kubectl -n "$namespace" get deploy "$deployment" -o wide || true
    kubectl -n "$namespace" describe deploy "$deployment" || true
    kubectl -n "$namespace" get pods -l app.kubernetes.io/name="$deployment" -o wide || true
    err "Deployment $deployment failed to become available in $namespace"
  fi
  success "Deployment $deployment is ready"
}

wait_for_statefulset() {
  local namespace=$1 sts=$2 timeout=${3:-${ROLLOUT_TIMEOUT}s}
  log "Waiting for statefulset $sts in $namespace..."
  if ! kubectl rollout status statefulset/"$sts" -n "$namespace" --timeout="$timeout"; then
    kubectl -n "$namespace" get statefulset "$sts" -o wide || true
    kubectl -n "$namespace" describe statefulset "$sts" || true
    kubectl -n "$namespace" get pods -l statefulset.kubernetes.io/pod-name -o wide || true
    err "StatefulSet $sts failed to become ready in $namespace"
  fi
  success "StatefulSet $sts is ready"
}

# Pre-pull images using available container runtime (mandatory unless --skip-prepull)
prepull_images() {
  log "Pre-pulling container images to speed up deployment..."
  local images=(
    # Core
    "opensearchproject/opensearch:2.11.0"
    "opensearchproject/opensearch-dashboards:2.11.0"
    "jaegertracing/jaeger:2.9.0"
    "busybox:latest"
    # OTEL Demo
    "ghcr.io/open-feature/flagd:v0.11.1"
    "ghcr.io/open-telemetry/demo:2.0.2-accounting"
    "ghcr.io/open-telemetry/demo:2.0.2-ad"
    "ghcr.io/open-telemetry/demo:2.0.2-cart"
    "ghcr.io/open-telemetry/demo:2.0.2-checkout"
    "ghcr.io/open-telemetry/demo:2.0.2-currency"
    "ghcr.io/open-telemetry/demo:2.0.2-email"
    "ghcr.io/open-telemetry/demo:2.0.2-flagd-ui"
    "ghcr.io/open-telemetry/demo:2.0.2-fraud-detection"
    "ghcr.io/open-telemetry/demo:2.0.2-frontend"
    "ghcr.io/open-telemetry/demo:2.0.2-frontend-proxy"
    "ghcr.io/open-telemetry/demo:2.0.2-image-provider"
    "ghcr.io/open-telemetry/demo:2.0.2-kafka"
    "ghcr.io/open-telemetry/demo:2.0.2-load-generator"
    "ghcr.io/open-telemetry/demo:2.0.2-payment"
    "ghcr.io/open-telemetry/demo:2.0.2-product-catalog"
    "ghcr.io/open-telemetry/demo:2.0.2-quote"
    "ghcr.io/open-telemetry/demo:2.0.2-recommendation"
    "ghcr.io/open-telemetry/demo:2.0.2-shipping"
    "valkey/valkey:7.2-alpine"
  )

  local pull_cmd=""
  if command -v minikube >/dev/null 2>&1; then
    pull_cmd="minikube image pull"
  elif command -v docker >/dev/null 2>&1; then
    pull_cmd="docker pull"
  elif command -v nerdctl >/dev/null 2>&1; then
    pull_cmd="nerdctl pull"
  elif command -v crictl >/dev/null 2>&1; then
    pull_cmd="crictl pull"
  else
    err "No supported container runtime found (minikube/docker/nerdctl/crictl). Cannot pre-pull images."
  fi

  local total=${#images[@]} current=0 failed=()
  log "Found $total images to pre-pull"
  for img in "${images[@]}"; do
    current=$((current + 1))
    log "[$current/$total] Pulling $img..."
    if $pull_cmd "$img" >/dev/null 2>&1; then
      success "[$current/$total] $img"
    else
      warn "[$current/$total] Failed to pull $img (will retry during deployment)"
      failed+=("$img")
    fi
  done
  if [[ ${#failed[@]} -eq 0 ]]; then
    success "All images pre-pulled successfully"
  else
    warn "${#failed[@]} images failed to pre-pull; continuing"
    log "Failed images: ${failed[*]}"
  fi
}

# Verify service is responding by temporary port-forward
verify_service() {
  local service_name=$1 namespace=$2 port=$3 endpoint=${4:-"/"} timeout=${5:-30}
  log "Verifying service $service_name responds on port $port..."
  kubectl port-forward -n "$namespace" svc/"$service_name" "$port":"$port" &
  local pf_pid=$!
  sleep 3
  local count=0
  while [ $count -lt $timeout ]; do
    if curl -s -o /dev/null -w "%{http_code}" "http://localhost:$port$endpoint" | grep -q "200\|404"; then
      success "Service $service_name is responding"
      kill "$pf_pid" 2>/dev/null || true
      return 0
    fi
    sleep 1
    count=$((count + 1))
  done
  kill "$pf_pid" 2>/dev/null || true
  warn "Service $service_name verification timed out"
  return 1
}

start_port_forwarding() {
  log "Starting port-forward sessions in background..."
  kubectl port-forward -n jaeger svc/jaeger-query-clusterip 16686:16686 &
  kubectl port-forward -n opensearch svc/opensearch-dashboards 5601:5601 &
  kubectl port-forward -n opensearch svc/opensearch-cluster-single 9200:9200 &
  kubectl port-forward -n otel-demo svc/frontend-proxy 8080:8080 &
  kubectl port-forward -n otel-demo svc/load-generator 8089:8089 &
  success "Port forwarding started. Use 'pkill -f "kubectl port-forward"' to stop all."
}

final_instructions() {
  echo ""
  log "Deployment Complete!"
  echo ""
  echo -e "${GREEN}Access Information:${NC}"
  echo "=================="
  echo ""
  echo -e "${BLUE}Services (after port-forwarding):${NC}"
  echo "• Jaeger UI: http://localhost:16686"
  echo "• OpenSearch Dashboards: http://localhost:5601"
  echo "• OpenSearch API: http://localhost:9200"
  echo "• OTEL Demo Frontend: http://localhost:8080"
  echo "• Load Generator: http://localhost:8089"
  echo ""
}

cleanup_trap() {
  log "Script interrupted. Cleaning up background port-forwards..."
  pkill -f "kubectl port-forward" 2>/dev/null || true
  exit 1
}

trap cleanup_trap INT TERM

main() {
  log "Running preflight checks..."
  need bash
  need curl
  need kubectl
  need helm

  check_version kubectl 1.25.0 || true
  check_version helm 3.10.0 || true

  check_required_files
  check_resources
  check_cluster
  build_jaeger_deps
  success "Preflight checks passed"

  log "Setting up Helm repositories..."
  helm repo add opensearch https://opensearch-project.github.io/helm-charts/ || warn "OpenSearch repo already exists"
  helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts || warn "Open-Telemetry repo already exists"
  helm repo update
  success "Helm repositories updated"

  if ! $SKIP_PREPULL; then
    prepull_images
  else
    warn "Skipping image pre-pull as requested"
  fi

  log "Deploying OpenSearch..."
  helm install opensearch opensearch/opensearch \
    --namespace opensearch \
    --create-namespace \
    --version 2.19.0 \
    --set image.tag=2.11.0 \
    -f "$SCRIPT_DIR/opensearch-values.yaml" \
    --wait --timeout=10m
  success "OpenSearch deployed"

  wait_for_statefulset opensearch opensearch-cluster-single "${ROLLOUT_TIMEOUT}s"
  verify_service opensearch-cluster-single opensearch 9200 "/_cluster/health" || true

  log "Deploying OpenSearch Dashboards..."
  helm install opensearch-dashboards opensearch/opensearch-dashboards \
    --namespace opensearch \
    -f "$SCRIPT_DIR/opensearch-dashboard-values.yaml" \
    --wait --timeout=10m
  success "OpenSearch Dashboards deployed"

  wait_for_deployment opensearch opensearch-dashboards "${ROLLOUT_TIMEOUT}s"

  log "Deploying Jaeger (local chart)..."
  helm install jaeger "$SCRIPT_DIR/helm-charts/charts/jaeger" \
    --namespace jaeger \
    --create-namespace \
    --set provisionDataStore.cassandra=false \
    --set allInOne.enabled=true \
    --set storage.type=none \
    --set allInOne.image.repository=jaegertracing/jaeger \
    --set allInOne.image.tag=2.9.0 \
    --set-file userconfig="$SCRIPT_DIR/jaeger-config.yaml" \
    -f "$SCRIPT_DIR/jaeger-values.yaml" \
    --wait --timeout=10m
  success "Jaeger deployed"

  wait_for_deployment jaeger jaeger "${ROLLOUT_TIMEOUT}s"

  log "Creating Jaeger query ClusterIP service..."
  kubectl apply -n jaeger -f "$SCRIPT_DIR/jaeger-query-service.yaml"
  success "Jaeger query ClusterIP service created"

  verify_service jaeger-query-clusterip jaeger 16686 "/api/services" || true

  log "Deploying OTEL Demo..."
  helm install otel-demo open-telemetry/opentelemetry-demo \
    -f "$SCRIPT_DIR/otel-demo-values.yaml" \
    --namespace otel-demo \
    --create-namespace \
    --wait --timeout=15m
  success "OTEL Demo deployed"

  wait_for_deployment otel-demo frontend "${ROLLOUT_TIMEOUT}s"
  wait_for_deployment otel-demo load-generator "${ROLLOUT_TIMEOUT}s"

  kubectl get pods -A | grep -E "(opensearch|jaeger|otel-demo)" || true
  success "All components deployed successfully!"

  final_instructions

  if $AUTO_PORT_FORWARD; then
    start_port_forwarding
  elif $PROMPT_PORT_FORWARD; then
    read -p "Would you like to automatically start port-forwarding? (y/N): " -n 1 -r || true
    echo
    if [[ ${REPLY:-N} =~ ^[Yy]$ ]]; then
      start_port_forwarding
    fi
  fi
}

main "$@"


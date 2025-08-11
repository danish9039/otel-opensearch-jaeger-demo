#!/bin/bash

# OpenSearch Observability Stack Deployment Script (Portable Variant)
# This script is a portable copy of deploy-opensearch-observability-stack.sh
# Changes:
# - Resolves all paths relative to this script's directory
# - Mandatory image pre-pull with runtime detection (minikube/docker/nerdctl/crictl)
# - More robust rollout wait logic for Deployments and StatefulSets
# - Explicit namespace handling for Jaeger service apply
# Author: AI Assistant
# Date: $(date +%Y-%m-%d)

set -euo pipefail  # Safer bash options

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Determine script directory (for portability)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Logging helpers
log() {
  echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
}

success() {
  echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] ✅ $1${NC}"
}

warning() {
  echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] ⚠️  $1${NC}"
}

error() {
  echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ❌ $1${NC}"
  exit 1
}

# Ensure a command exists
check_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    error "$1 is required but not installed."
  fi
}

# Wait for a Deployment to complete
wait_for_deployment() {
  local namespace=$1
  local deployment=$2
  local timeout=${3:-600s}
  log "Waiting for deployment $deployment in namespace $namespace to be available..."
  if ! kubectl rollout status deployment/"$deployment" -n "$namespace" --timeout="$timeout"; then
    kubectl -n "$namespace" get deploy "$deployment" -o wide || true
    kubectl -n "$namespace" describe deploy "$deployment" || true
    kubectl -n "$namespace" get pods -l app.kubernetes.io/name="$deployment" -o wide || true
    error "Deployment $deployment failed to become available in $namespace"
  fi
  success "Deployment $deployment is ready"
}

# Wait for a StatefulSet to complete
wait_for_statefulset() {
  local namespace=$1
  local statefulset=$2
  local timeout=${3:-600s}
  log "Waiting for statefulset $statefulset in namespace $namespace to be ready..."
  if ! kubectl rollout status statefulset/"$statefulset" -n "$namespace" --timeout="$timeout"; then
    kubectl -n "$namespace" get statefulset "$statefulset" -o wide || true
    kubectl -n "$namespace" describe statefulset "$statefulset" || true
    kubectl -n "$namespace" get pods -l statefulset.kubernetes.io/pod-name -o wide || true
    error "StatefulSet $statefulset failed to become ready in $namespace"
  fi
  success "StatefulSet $statefulset is ready"
}

# Pre-pull images using available container runtime (mandatory)
prepull_images() {
  log "Pre-pulling container images to speed up deployment..."

  # All required images (copied from original script)
  local images=(
    # Core Infrastructure
    "opensearchproject/opensearch:2.11.0"
    "opensearchproject/opensearch-dashboards:2.11.0"
    "jaegertracing/jaeger:2.9.0"
    "busybox:latest"

    # OpenTelemetry Demo images
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

  # Pick a pull strategy (mandatory pre-pull)
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
    error "No supported container runtime found (minikube/docker/nerdctl/crictl). Cannot pre-pull images."
  fi

  local total_images=${#images[@]}
  local current=0
  local failed_images=()
  log "Found $total_images images to pre-pull"

  for image in "${images[@]}"; do
    current=$((current + 1))
    log "[$current/$total_images] Pulling $image..."
    if $pull_cmd "$image" >/dev/null 2>&1; then
      success "[$current/$total_images] ✅ $image"
    else
      warning "[$current/$total_images] ⚠️  Failed to pull $image (will retry during deployment)"
      failed_images+=("$image")
    fi
  done

  if [ ${#failed_images[@]} -eq 0 ]; then
    success "All $total_images images pre-pulled successfully!"
  else
    warning "${#failed_images[@]} images failed to pre-pull but deployment will continue"
    log "Failed images: ${failed_images[*]}"
  fi
  echo ""
}

# Verify service is responding by temporary port-forward
verify_service() {
  local service_name=$1
  local namespace=$2
  local port=$3
  local endpoint=${4:-"/"}
  local timeout=${5:-30}

  log "Verifying service $service_name is responding..."
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
  warning "Service $service_name verification timed out"
  return 1
}

main() {
  log "Starting OpenSearch Observability Stack Deployment (Portable Variant)"

  # Check prerequisites
  log "Checking prerequisites..."
  check_command kubectl
  check_command helm

  # Verify cluster connectivity
  if ! kubectl cluster-info >/dev/null 2>&1; then
    error "Cannot connect to Kubernetes cluster. Please ensure your kubeconfig is set up and the cluster is reachable."
  fi
  success "Prerequisites check passed"

  # Required config files (resolved relative to script)
  local required_files=(
    "$SCRIPT_DIR/opensearch-values.yaml"
    "$SCRIPT_DIR/opensearch-dashboard-values.yaml"
    "$SCRIPT_DIR/jaeger-values.yaml"
    "$SCRIPT_DIR/jaeger-config.yaml"
    "$SCRIPT_DIR/jaeger-query-service.yaml"
    "$SCRIPT_DIR/otel-demo-values.yaml"
  )
  for file in "${required_files[@]}"; do
    if [ ! -f "$file" ]; then
      error "Required file $file not found"
    fi
  done
  success "All required configuration files found"

  # Local jaeger helm chart exists
  if [ ! -d "$SCRIPT_DIR/helm-charts/charts/jaeger" ]; then
    error "Local Jaeger helm chart not found at $SCRIPT_DIR/helm-charts/charts/jaeger"
  fi
  success "Local Jaeger helm chart found"

  # Set up Helm repositories
  log "Setting up Helm repositories..."
  helm repo add opensearch https://opensearch-project.github.io/helm-charts/ || warning "OpenSearch repo already exists"
  helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts || warning "Open-Telemetry repo already exists"
  helm repo update
  success "Helm repositories updated"

  # Mandatory pre-pull of all required images
  prepull_images

  # Deploy OpenSearch
  log "Deploying OpenSearch..."
  helm install opensearch opensearch/opensearch \
    --namespace opensearch \
    --create-namespace \
    --version 2.19.0 \
    --set image.tag=2.11.0 \
    -f "$SCRIPT_DIR/opensearch-values.yaml" \
    --wait --timeout=10m
  success "OpenSearch deployed successfully"

  # Wait for OpenSearch to be fully ready (uses StatefulSet name from values)
  wait_for_statefulset opensearch opensearch-cluster-single 600s

  # Verify OpenSearch API responds
  verify_service opensearch-cluster-single opensearch 9200 "/_cluster/health"

  # Deploy OpenSearch Dashboards
  log "Deploying OpenSearch Dashboards..."
  helm install opensearch-dashboards opensearch/opensearch-dashboards \
    --namespace opensearch \
    -f "$SCRIPT_DIR/opensearch-dashboard-values.yaml" \
    --wait --timeout=10m
  success "OpenSearch Dashboards deployed successfully"

  # Wait for Dashboards Deployment
  wait_for_deployment opensearch opensearch-dashboards 600s

  # Deploy Jaeger (local chart)
  log "Deploying Jaeger..."
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
  success "Jaeger deployed successfully"

  # Wait for Jaeger Deployment
  wait_for_deployment jaeger jaeger 600s

  # Create ClusterIP service for Jaeger query (explicit namespace and absolute path)
  log "Creating Jaeger query ClusterIP service..."
  kubectl apply -n jaeger -f "$SCRIPT_DIR/jaeger-query-service.yaml"
  success "Jaeger query ClusterIP service created"

  # Verify Jaeger Query responds
  verify_service jaeger-query-clusterip jaeger 16686 "/api/services"

  # Deploy OTEL Demo
  log "Deploying OTEL Demo..."
  helm install otel-demo open-telemetry/opentelemetry-demo \
    -f "$SCRIPT_DIR/otel-demo-values.yaml" \
    --namespace otel-demo \
    --create-namespace \
    --wait --timeout=15m
  success "OTEL Demo deployed successfully"

  # Wait for key OTEL Demo deployments
  wait_for_deployment otel-demo frontend 600s
  wait_for_deployment otel-demo load-generator 600s

  # Final verification
  log "Performing final verification..."
  kubectl get pods -A | grep -E "(opensearch|jaeger|otel-demo)" || true
  success "All components deployed successfully!"

  echo ""
  log "🎉 Deployment Complete! 🎉"
  echo ""
  echo -e "${GREEN}Access Information:${NC}"
  echo "=================="
  echo ""
  echo -e "${BLUE}To access the services, run the following port-forward commands:${NC}"
  echo ""
  echo "# Core Observability Stack"
  echo "kubectl port-forward -n jaeger svc/jaeger-query-clusterip 16686:16686 &"
  echo "kubectl port-forward -n opensearch svc/opensearch-dashboards 5601:5601 &"
  echo "kubectl port-forward -n opensearch svc/opensearch-cluster-single 9200:9200 &"
  echo ""
  echo "# OTEL Demo Frontend & Load Generator"
  echo "kubectl port-forward -n otel-demo svc/frontend-proxy 8080:8080 &"
  echo "kubectl port-forward -n otel-demo svc/load-generator 8089:8089 &"
  echo ""
  echo -e "${BLUE}Service URLs (after port-forwarding):${NC}"
  echo "• Jaeger UI: http://localhost:16686"
  echo "• OpenSearch Dashboards: http://localhost:5601"
  echo "• OpenSearch API: http://localhost:9200"
  echo "• OTEL Demo Frontend: http://localhost:8080"
  echo "• Load Generator: http://localhost:8089"
  echo ""
  echo -e "${YELLOW}Note: Use Ctrl+C to stop port-forwarding when done${NC}"
  echo ""

  # Optionally start port forwarding automatically (same behavior as original)
  read -p "Would you like to automatically start port-forwarding? (y/N): " -n 1 -r || true
  echo
  if [[ ${REPLY:-N} =~ ^[Yy]$ ]]; then
    log "Starting port-forward services..."
    kubectl port-forward -n jaeger svc/jaeger-query-clusterip 16686:16686 &
    kubectl port-forward -n opensearch svc/opensearch-dashboards 5601:5601 &
    kubectl port-forward -n opensearch svc/opensearch-cluster-single 9200:9200 &
    kubectl port-forward -n otel-demo svc/frontend-proxy 8080:8080 &
    kubectl port-forward -n otel-demo svc/load-generator 8089:8089 &
    success "Port forwarding started. Use 'pkill -f \"kubectl port-forward\"' to stop all."
  fi
}

cleanup() {
  log "Script interrupted. Cleaning up..."
  pkill -f "kubectl port-forward" 2>/dev/null || true
  exit 1
}

trap cleanup INT TERM

main "$@"


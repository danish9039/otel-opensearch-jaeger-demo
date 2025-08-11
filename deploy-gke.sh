#!/bin/bash

# GKE HTTPS Ingress Deployment Script
# This script automates the complete setup of HTTPS ingress with cert-manager on GKE
# It deploys: NGINX ingress controller, cert-manager, Let's Encrypt issuer, and all services

set -e

# Configuration
NGINX_INGRESS_URL="https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.8.1/deploy/static/provider/cloud/deploy.yaml"
CERT_MANAGER_URL="https://github.com/cert-manager/cert-manager/releases/download/v1.14.2/cert-manager.yaml"
CLUSTER_ISSUER_FILE="cluster-issuer.yaml"
INGRESS_TLS_FILE="ingress-with-tls.yaml"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Helper functions
print_status() {
    echo -e "${BLUE}===> $1${NC}"
}

print_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

print_error() {
    echo -e "${RED}❌ $1${NC}"
}

wait_for_pods() {
    local namespace=$1
    print_status "Waiting for pods in namespace '$namespace' to be ready..."
    
    while true; do
        if kubectl get pods -n $namespace --no-headers 2>/dev/null | grep -v Running | grep -v Completed | grep -q .; then
            echo "    Still waiting for pods to be ready..."
            sleep 10
        else
            print_success "All pods in namespace '$namespace' are ready!"
            break
        fi
    done
}

wait_for_external_ip() {
    local service=$1
    local namespace=$2
    print_status "Waiting for external IP for service '$service' in namespace '$namespace'..."
    
    while true; do
        EXTERNAL_IP=$(kubectl get svc $service -n $namespace -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
        if [ -n "$EXTERNAL_IP" ] && [ "$EXTERNAL_IP" != "null" ]; then
            print_success "External IP assigned: $EXTERNAL_IP"
            break
        else
            echo "    Still waiting for external IP..."
            sleep 10
        fi
    done
}

# Main deployment
echo -e "${BLUE}"
echo "=============================================="
echo "  GKE HTTPS Ingress Deployment Script"
echo "=============================================="
echo -e "${NC}"

# Step 1: Install NGINX Ingress Controller
print_status "Step 1: Installing NGINX Ingress Controller"
kubectl apply -f $NGINX_INGRESS_URL
wait_for_pods "ingress-nginx"

# Step 2: Install Cert-Manager
print_status "Step 2: Installing Cert-Manager"
kubectl apply -f $CERT_MANAGER_URL
wait_for_pods "cert-manager"

# Step 3: Get external IP
print_status "Step 3: Getting external IP for ingress controller"
wait_for_external_ip "ingress-nginx-controller" "ingress-nginx"

# Step 4: Apply ClusterIssuer
print_status "Step 4: Applying Let's Encrypt ClusterIssuer"
if [ ! -f "$CLUSTER_ISSUER_FILE" ]; then
    print_error "File '$CLUSTER_ISSUER_FILE' not found! Please ensure it exists with your email configured."
    exit 1
fi
kubectl apply -f $CLUSTER_ISSUER_FILE
print_success "ClusterIssuer applied successfully"

# Step 5: Deploy services and ingress with TLS
print_status "Step 5: Deploying services and ingress with TLS"
if [ ! -f "$INGRESS_TLS_FILE" ]; then
    print_error "File '$INGRESS_TLS_FILE' not found! Please ensure it exists."
    exit 1
fi
kubectl apply -f $INGRESS_TLS_FILE
print_success "Services and ingress with TLS applied successfully"

# Step 6: Final status and instructions
print_status "Step 6: Deployment Summary"

# Get final external IP
FINAL_EXTERNAL_IP=$(kubectl get svc ingress-nginx-controller -n ingress-nginx -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

echo -e "${GREEN}"
echo "🎉 Deployment completed successfully!"
echo "=============================================="
echo "External IP: $FINAL_EXTERNAL_IP"
echo "=============================================="
echo -e "${NC}"

print_warning "IMPORTANT: Configure your DNS records to point to $FINAL_EXTERNAL_IP"
echo ""
echo "DNS Configuration needed:"
echo "  jaegertracing.fun → $FINAL_EXTERNAL_IP"
echo "  shop.jaegertracing.fun → $FINAL_EXTERNAL_IP" 
echo "  loadgen.jaegertracing.fun → $FINAL_EXTERNAL_IP"
echo "  opensearch.jaegertracing.fun → $FINAL_EXTERNAL_IP"
echo ""

print_status "Checking certificate status..."
echo "Monitor certificate provisioning with:"
echo "  kubectl get certificate -n ingress-nginx"
echo "  kubectl describe certificate jaegertracing-fun-tls -n ingress-nginx"
echo ""

print_status "Testing the setup:"
echo "Once DNS is configured, you can access:"
echo "  https://jaegertracing.fun (Jaeger UI)"
echo "  https://shop.jaegertracing.fun (Shop Frontend)"
echo "  https://loadgen.jaegertracing.fun (Load Generator)" 
echo "  https://opensearch.jaegertracing.fun (OpenSearch Dashboards)"
echo ""

print_success "Setup is complete! 🚀"

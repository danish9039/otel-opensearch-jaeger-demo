#!/bin/bash

# Test Image Pre-pulling Script
# This script demonstrates the pre-pulling functionality

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
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

# Test images (smaller set for quick demonstration)
test_prepull_images() {
    log "Testing image pre-pulling functionality..."
    
    # Test with a smaller set of images for faster demo
    local images=(
        "busybox:latest"
        "nginx:alpine"
        "redis:alpine"
    )
    
    local total_images=${#images[@]}
    local current=0
    local failed_images=()
    
    log "Testing with $total_images images for demonstration"
    
    for image in "${images[@]}"; do
        current=$((current + 1))
        log "[$current/$total_images] Pulling $image..."
        
        if minikube image pull "$image" > /dev/null 2>&1; then
            success "[$current/$total_images] ✅ $image"
        else
            warning "[$current/$total_images] ⚠️  Failed to pull $image"
            failed_images+=("$image")
        fi
    done
    
    if [ ${#failed_images[@]} -eq 0 ]; then
        success "All $total_images test images pulled successfully!"
        log "✨ Image pre-pulling functionality is working correctly!"
    else
        warning "${#failed_images[@]} images failed to pull"
        log "Failed images: ${failed_images[*]}"
    fi
    
    echo ""
    log "Verifying images are now available locally..."
    
    for image in "${images[@]}"; do
        if minikube image ls | grep -q "$image"; then
            success "✅ $image is available locally"
        else
            warning "⚠️  $image not found locally"
        fi
    done
    
    echo ""
    log "🎉 Image pre-pulling test completed!"
}

# Main function
main() {
    log "Starting Image Pre-pulling Test"
    
    # Check prerequisites
    if ! command -v minikube &> /dev/null; then
        error "minikube is required but not installed."
    fi
    
    if ! minikube status > /dev/null 2>&1; then
        error "minikube is not running. Please start minikube first."
    fi
    
    success "Prerequisites check passed"
    
    # Remove test images first to simulate fresh environment
    log "Cleaning up test images to simulate fresh environment..."
    minikube image rm busybox:latest > /dev/null 2>&1 || true
    minikube image rm nginx:alpine > /dev/null 2>&1 || true
    minikube image rm redis:alpine > /dev/null 2>&1 || true
    success "Test environment prepared"
    
    # Test the pre-pulling functionality
    test_prepull_images
    
    log "Test completed successfully!"
}

# Run main function
main "$@"

#!/bin/bash
# =============================================================================
# Complete Deployment Script for gabs-massage.de
# =============================================================================
# This script runs on the production server to deploy gabs-massage for the
# first time. It handles everything: pull code, SSL certs, containers, nginx.
#
# Usage (on production server):
#   ./deploy-gabs-massage.sh
# =============================================================================

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}ℹ${NC}  $1"; }
log_success() { echo -e "${GREEN}✅${NC} $1"; }
log_warning() { echo -e "${YELLOW}⚠️${NC}  $1"; }
log_error() { echo -e "${RED}❌${NC} $1"; }
separator() { echo ""; echo "========================================"; echo "$1"; echo "========================================"; }

# Check we're on production
if [ ! -d "/opt/multi-tenant-platform" ]; then
    log_error "This script must run on the production server"
    exit 1
fi

cd /opt/multi-tenant-platform

separator "🚀 DEPLOYING GABS-MASSAGE.DE"

# Step 1: Pull latest platform configuration
separator "📥 STEP 1: Pull Latest Configuration"
log_info "Pulling latest platform code..."
git pull origin main
log_success "Platform code updated"

# Step 2: Set up environment variables
separator "🔐 STEP 2: Configure Environment Variables"
if [ ! -f "deploy/apps/gabs-massage/.env" ]; then
    log_warning "Creating .env file - YOU MUST SET PRODUCTION SECRETS!"
    cp deploy/apps/gabs-massage/.env.example deploy/apps/gabs-massage/.env
    log_error "STOP! Edit deploy/apps/gabs-massage/.env and set strong secrets!"
    log_info "Run: nano deploy/apps/gabs-massage/.env"
    exit 1
else
    log_success "Environment file exists"
fi

# Step 3: Provision SSL certificates
separator "🔐 STEP 3: Provision SSL Certificates"
log_info "Auto-provisioning SSL for gabs-massage domains..."
if ./lib/provision-ssl-certs.sh; then
    log_success "SSL certificates provisioned"
else
    log_error "SSL provisioning failed!"
    log_info "Check DNS is propagated: dig gabs-massage.de"
    log_info "Wait a few minutes and try again"
    exit 1
fi

# Step 4: Wait for Docker image to be available
separator "🐳 STEP 4: Pull Docker Image"
log_info "Pulling latest gabs-massage Docker image..."
docker pull ghcr.io/duersjefen/physiotherapy-scheduler:latest
log_success "Docker image ready"

# Step 5: Start application containers
separator "🚀 STEP 5: Start Application Containers"
log_info "Starting gabs-massage containers..."
cd deploy/apps/gabs-massage
docker compose up -d
cd /opt/multi-tenant-platform
log_success "Containers started"

# Wait for containers to be healthy
log_info "Waiting for containers to become healthy..."
sleep 10

# Check health
log_info "Checking container health..."
docker ps | grep gabs-massage

# Step 6: Deploy nginx configuration
separator "🌐 STEP 6: Deploy Nginx Configuration"
log_info "Deploying nginx with staging-first strategy..."
./lib/deploy-platform-safe.sh nginx --force

separator "✅ DEPLOYMENT COMPLETE!"
echo ""
log_success "gabs-massage.de has been deployed!"
echo ""
log_info "Verify deployment:"
echo "  curl https://gabs-massage.de/health"
echo "  curl https://staging.gabs-massage.de/health"
echo ""
log_info "Visit in browser:"
echo "  https://gabs-massage.de"
echo "  https://staging.gabs-massage.de"
echo ""

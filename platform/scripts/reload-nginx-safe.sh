#!/bin/bash
# =============================================================================
# Safe Nginx Reload Script - Deploy Hook for Certbot
# =============================================================================
# This script is called ONLY when certbot successfully renews a certificate
# It validates nginx config before reloading to prevent breaking production
#
# Called by: certbot renew --deploy-hook "/scripts/reload-nginx-safe.sh"
#
# Exit codes:
#   0 - Success (nginx reloaded)
#   1 - Failure (validation failed, nginx NOT reloaded)
# =============================================================================

set -euo pipefail

# Logging
log_info() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] ℹ️  $1"
}

log_success() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] ✅ $1"
}

log_error() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] ❌ $1" >&2
}

log_info "Certificate renewed - preparing to reload nginx..."

# Check which domains were renewed (certbot sets these env vars)
if [ -n "${RENEWED_DOMAINS:-}" ]; then
    log_info "Renewed domains: $RENEWED_DOMAINS"
fi

if [ -n "${RENEWED_LINEAGE:-}" ]; then
    log_info "Renewed lineage: $RENEWED_LINEAGE"
fi

# Step 1: Validate nginx configuration
log_info "Validating nginx configuration..."
if docker exec platform-nginx nginx -t 2>&1; then
    log_success "Nginx configuration is valid"
else
    log_error "Nginx configuration validation FAILED!"
    log_error "Nginx will NOT be reloaded to prevent service disruption"
    log_error "Please check nginx config manually: docker exec platform-nginx nginx -t"
    exit 1
fi

# Step 2: Reload nginx
log_info "Reloading nginx..."
if docker exec platform-nginx nginx -s reload 2>&1; then
    log_success "Nginx successfully reloaded with renewed certificates"
else
    log_error "Nginx reload FAILED!"
    log_error "Service may be disrupted. Check nginx logs: docker logs platform-nginx"
    exit 1
fi

# Step 3: Verify nginx is still running
sleep 2
if docker exec platform-nginx nginx -T > /dev/null 2>&1; then
    log_success "Nginx is running correctly after reload"
else
    log_error "Nginx appears to be down after reload!"
    log_error "Immediate action required! Check: docker logs platform-nginx"
    exit 1
fi

log_success "Certificate renewal complete - nginx reloaded successfully"
exit 0

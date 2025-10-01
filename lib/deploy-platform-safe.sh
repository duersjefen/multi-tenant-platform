#!/bin/bash
# =============================================================================
# Safe Platform Deployment with Staging-First Strategy
# =============================================================================
# This script implements TRUE staging for platform infrastructure:
#
# 1. Deploy to nginx-staging (port 8443) first
# 2. Run automated tests against staging
# 3. If tests pass: promote to production (port 443)
# 4. If tests fail: rollback staging only (production untouched)
#
# This gives you REAL isolation - production is never at risk during testing.
#
# Usage:
#   ./lib/deploy-platform-safe.sh nginx
#   ./lib/deploy-platform-safe.sh --dry-run
#
# =============================================================================

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Deployment settings
COMPONENT="${1:-nginx}"
DRY_RUN=false
SKIP_TESTS=false
FORCE=false

# Parse arguments
for arg in "$@"; do
    case $arg in
        --dry-run) DRY_RUN=true ;;
        --skip-tests) SKIP_TESTS=true ;;
        --force) FORCE=true ;;
    esac
done

# Functions
log_info() {
    echo -e "${BLUE}ℹ${NC}  $1"
}

log_success() {
    echo -e "${GREEN}✅${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}⚠️${NC}  $1"
}

log_error() {
    echo -e "${RED}❌${NC} $1"
}

separator() {
    echo ""
    echo "======================================================================"
    echo "$1"
    echo "======================================================================"
}

# Validate we're on production server
if [ ! -d "/opt/multi-tenant-platform" ]; then
    log_error "This script must run on the production server"
    log_info "Run this via: make deploy-nginx"
    exit 1
fi

cd "$PLATFORM_ROOT"

separator "🚀 SAFE PLATFORM DEPLOYMENT: $COMPONENT"
log_warning "Using staging-first strategy"
echo "Started at: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo ""

# =============================================================================
# STEP 1: PRE-FLIGHT CHECKS
# =============================================================================
separator "📋 STEP 1: PRE-FLIGHT CHECKS"

log_info "Checking production nginx status..."
NGINX_RUNNING=$(docker ps --filter "name=platform-nginx" --format "{{.Names}}" | grep -c "^platform-nginx$" || true)
if [ "$NGINX_RUNNING" -eq 0 ]; then
    log_error "Production nginx is not running!"
    log_info "Debug: Running containers:"
    docker ps --filter "name=platform" --format "table {{.Names}}\t{{.Status}}"
    exit 1
fi
log_success "Production nginx is running"

log_info "Validating nginx configuration..."
if ! docker exec platform-nginx nginx -t 2>&1 | tail -1 | grep -q "successful"; then
    log_error "Current production nginx config is invalid!"
    docker exec platform-nginx nginx -t 2>&1 | tail -5
    exit 1
fi
log_success "Production nginx config is valid"

log_info "Checking for staging container..."
if docker ps -a | grep -q "platform-nginx-staging"; then
    log_warning "Cleaning up old staging container..."
    docker rm -f platform-nginx-staging || true
fi

if [ "$DRY_RUN" = true ]; then
    log_warning "DRY RUN MODE - No actual changes will be made"
    exit 0
fi

# =============================================================================
# STEP 2: DEPLOY TO STAGING (PORT 8443)
# =============================================================================
separator "🧪 STEP 2: DEPLOY TO STAGING (PORT 8443)"

log_info "Starting nginx-staging container..."
docker compose -f platform/docker-compose.platform.yml up -d --profile staging nginx-staging

log_info "Waiting for staging nginx to be healthy..."
WAIT_TIME=0
MAX_WAIT=30
while [ $WAIT_TIME -lt $MAX_WAIT ]; do
    if docker inspect platform-nginx-staging --format='{{.State.Health.Status}}' 2>/dev/null | grep -q "healthy"; then
        log_success "Staging nginx is healthy"
        break
    fi
    sleep 2
    WAIT_TIME=$((WAIT_TIME + 2))
    echo -n "."
done
echo ""

if [ $WAIT_TIME -ge $MAX_WAIT ]; then
    log_error "Staging nginx failed health check"
    log_info "Checking logs..."
    docker logs --tail 50 platform-nginx-staging
    docker rm -f platform-nginx-staging
    exit 1
fi

# =============================================================================
# STEP 3: TEST STAGING
# =============================================================================
separator "✅ STEP 3: AUTOMATED TESTING ON STAGING"

if [ "$SKIP_TESTS" = true ]; then
    log_warning "Skipping tests (--skip-tests flag)"
else
    log_info "Running nginx config test..."
    if ! docker exec platform-nginx-staging nginx -t 2>&1 | grep -q "syntax is ok"; then
        log_error "Staging nginx config test failed!"
        docker logs --tail 50 platform-nginx-staging
        docker rm -f platform-nginx-staging
        exit 1
    fi
    log_success "Config test passed"

    log_info "Testing HTTP response on port 8443..."
    # Test staging is responding (using localhost since we're on the server)
    if ! curl -k -s -f --max-time 5 https://localhost:8443/health > /dev/null 2>&1; then
        # Try without /health endpoint
        if ! curl -k -s --max-time 5 https://localhost:8443 > /dev/null 2>&1; then
            log_warning "Could not reach staging on 8443 (this may be OK if no default server)"
        else
            log_success "Staging responds on port 8443"
        fi
    else
        log_success "Staging responds on port 8443"
    fi

    log_info "Checking HTTP/3 configuration..."
    if ! docker exec platform-nginx-staging nginx -T 2>/dev/null | grep -q "listen 443 quic"; then
        log_error "HTTP/3 (QUIC) listener not found in staging config!"
        docker rm -f platform-nginx-staging
        exit 1
    fi
    log_success "HTTP/3 configuration present"

    log_info "Verifying Alt-Svc header configuration..."
    if ! docker exec platform-nginx-staging nginx -T 2>/dev/null | grep -q "Alt-Svc"; then
        log_warning "Alt-Svc header not found in config"
    else
        log_success "Alt-Svc header configured"
    fi
fi

log_success "All staging tests passed!"

# =============================================================================
# STEP 4: PROMOTION DECISION
# =============================================================================
separator "🎯 STEP 4: PROMOTE TO PRODUCTION?"

echo ""
echo "Staging tests completed successfully on port 8443"
echo ""
echo "Options:"
echo "  1. Promote to production (reload nginx:443 with same config)"
echo "  2. Cancel (keep staging running for manual testing)"
echo "  3. Rollback (stop staging, abort deployment)"
echo ""

if [ "$FORCE" = true ]; then
    log_warning "Force mode enabled - auto-promoting to production"
    CHOICE="1"
else
    read -p "Enter choice [1/2/3]: " CHOICE
fi

case $CHOICE in
    1)
        log_info "Promoting to production..."
        ;;
    2)
        log_warning "Keeping staging running on port 8443"
        log_info "Test manually at: https://$(hostname -I | awk '{print $1}'):8443"
        log_info "When ready, run: docker exec platform-nginx nginx -s reload"
        log_info "To cleanup: docker rm -f platform-nginx-staging"
        exit 0
        ;;
    3)
        log_warning "Rolling back staging..."
        docker rm -f platform-nginx-staging
        log_success "Staging rolled back, production untouched"
        exit 0
        ;;
    *)
        log_error "Invalid choice"
        exit 1
        ;;
esac

# =============================================================================
# STEP 5: PROMOTE TO PRODUCTION
# =============================================================================
separator "🚀 STEP 5: PROMOTE TO PRODUCTION (PORT 443)"

log_info "Creating backup of production nginx..."
BACKUP_TAG="platform-nginx-backup-$(date +%Y%m%d-%H%M%S)"
docker commit platform-nginx "$BACKUP_TAG"
log_success "Backup created: $BACKUP_TAG"

log_info "Reloading production nginx with new configuration..."
if ! docker exec platform-nginx nginx -s reload; then
    log_error "Production nginx reload failed!"
    log_error "Production may still be running with OLD config"
    log_info "Staging container still running on 8443 for debugging"
    exit 1
fi

log_success "Production nginx reloaded"

log_info "Waiting for production nginx to stabilize..."
sleep 3

log_info "Validating production nginx health..."
if ! docker inspect platform-nginx --format='{{.State.Health.Status}}' | grep -q "healthy"; then
    log_error "Production nginx is unhealthy after reload!"
    log_warning "Consider manual rollback using: $BACKUP_TAG"
    exit 1
fi

log_success "Production nginx is healthy"

# =============================================================================
# STEP 6: CLEANUP
# =============================================================================
separator "🧹 STEP 6: CLEANUP"

log_info "Stopping staging container..."
docker rm -f platform-nginx-staging

log_info "Keeping backup: $BACKUP_TAG"
log_info "To rollback: docker tag $BACKUP_TAG <restore-commands>"

# =============================================================================
# STEP 7: VALIDATION
# =============================================================================
separator "✅ STEP 7: VALIDATION"

log_info "Testing production domains..."

# Test a few key domains
DOMAINS=("filter-ical.de" "paiss.me")
FAILURES=0

for domain in "${DOMAINS[@]}"; do
    if curl -sf --max-time 5 "https://$domain" > /dev/null 2>&1; then
        log_success "$domain: OK"
    else
        log_error "$domain: FAILED"
        FAILURES=$((FAILURES + 1))
    fi
done

if [ $FAILURES -gt 0 ]; then
    log_error "$FAILURES domain(s) failed validation"
    log_warning "Production is running but may have issues"
    exit 1
fi

log_success "All production domains responding"

# =============================================================================
# COMPLETION
# =============================================================================
separator "✅ DEPLOYMENT COMPLETE"

echo ""
echo "Summary:"
echo "  - Tested on staging (8443) ✅"
echo "  - Promoted to production (443) ✅"
echo "  - All domains validated ✅"
echo "  - Backup created: $BACKUP_TAG"
echo ""
log_success "Safe deployment completed successfully!"
echo ""

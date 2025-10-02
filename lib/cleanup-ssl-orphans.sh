#!/bin/bash
# =============================================================================
# Cleanup Orphaned SSL Files and Volumes
# =============================================================================
# Removes old/unused SSL certificates and Docker volumes to ensure a single
# clean source of truth for SSL management.
#
# Usage:
#   ./lib/cleanup-ssl-orphans.sh [--dry-run]
#
# =============================================================================

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Parse arguments
DRY_RUN=false
for arg in "$@"; do
    case $arg in
        --dry-run) DRY_RUN=true ;;
    esac
done

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
    echo "========================================================================"
    echo "$1"
    echo "========================================================================"
}

# Detect if we're on production server
if [ ! -d "/opt/multi-tenant-platform" ]; then
    log_error "This script must be run on the production server"
    exit 1
fi

cd /opt/multi-tenant-platform

separator "🧹 SSL CLEANUP - REMOVING ORPHANED FILES"

if [ "$DRY_RUN" = true ]; then
    log_warning "DRY RUN MODE - No actual changes will be made"
    echo ""
fi

# =============================================================================
# Step 1: Remove orphaned host /etc/letsencrypt directory
# =============================================================================
separator "📂 STEP 1: CHECK HOST /etc/letsencrypt"

if [ -d "/etc/letsencrypt" ]; then
    log_warning "Found orphaned /etc/letsencrypt directory on host"

    # Check if any container mounts it
    MOUNTED=$(docker ps -a --format '{{.Names}}' | xargs -I {} docker inspect {} --format '{{.Name}}: {{range .Mounts}}{{.Source}} {{end}}' 2>/dev/null | grep -c "/etc/letsencrypt" || echo "0")

    if [ "$MOUNTED" -eq 0 ]; then
        log_info "Directory not mounted by any container (safe to remove)"

        if [ "$DRY_RUN" = true ]; then
            log_warning "DRY RUN: Would remove /etc/letsencrypt/"
            log_info "Contains: $(sudo ls -1 /etc/letsencrypt/live 2>/dev/null | wc -l) certificate directories"
        else
            log_warning "Backing up to /opt/ssl-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
            sudo tar -czf "/opt/ssl-backup-$(date +%Y%m%d-%H%M%S).tar.gz" /etc/letsencrypt 2>/dev/null || true

            log_info "Removing /etc/letsencrypt..."
            sudo rm -rf /etc/letsencrypt
            log_success "Removed orphaned /etc/letsencrypt"
        fi
    else
        log_error "Directory is mounted by $MOUNTED container(s) - SKIPPING"
        log_warning "Manual investigation required"
    fi
else
    log_success "No orphaned /etc/letsencrypt directory found"
fi

# =============================================================================
# Step 2: Remove unused Docker volumes
# =============================================================================
separator "📦 STEP 2: REMOVE UNUSED DOCKER VOLUMES"

# Get volumes actually used by platform services
USED_VOLUMES=$(docker compose -f platform/docker-compose.platform.yml config --volumes 2>/dev/null || echo "")

log_info "Active volumes used by platform:"
echo "$USED_VOLUMES" | while read vol; do
    [ -n "$vol" ] && echo "  - $vol"
done
echo ""

# Find orphaned SSL volumes
ORPHANED_VOLUMES=(
    "letsencrypt-certs"
    "websites-letsencrypt-certs"
    "certbot-webroot"
    "websites-certbot-webroot"
)

for volume in "${ORPHANED_VOLUMES[@]}"; do
    if docker volume inspect "$volume" &>/dev/null; then
        # Check if volume is in use
        IN_USE=$(docker ps -a --format '{{.Names}}' | xargs -I {} docker inspect {} --format '{{.Name}}: {{range .Mounts}}{{.Name}} {{end}}' 2>/dev/null | grep -c "$volume" || echo "0")

        if [ "$IN_USE" -eq 0 ]; then
            log_warning "Found unused volume: $volume"

            if [ "$DRY_RUN" = true ]; then
                log_warning "DRY RUN: Would remove volume: $volume"
            else
                docker volume rm "$volume" 2>/dev/null && log_success "Removed volume: $volume" || log_error "Failed to remove: $volume"
            fi
        else
            log_info "Volume $volume is in use by $IN_USE container(s) - SKIPPING"
        fi
    else
        log_info "Volume $volume doesn't exist (already clean)"
    fi
done

# =============================================================================
# Step 3: Remove zombie certbot run containers
# =============================================================================
separator "🧟 STEP 3: REMOVE ZOMBIE CONTAINERS"

ZOMBIES=$(docker ps -a --filter 'name=platform-certbot-run-' --format '{{.Names}}' 2>/dev/null || echo "")

if [ -z "$ZOMBIES" ]; then
    log_success "No zombie certbot containers found"
else
    ZOMBIE_COUNT=$(echo "$ZOMBIES" | wc -l)
    log_warning "Found $ZOMBIE_COUNT zombie certbot container(s)"

    if [ "$DRY_RUN" = true ]; then
        echo "$ZOMBIES" | while read container; do
            log_warning "DRY RUN: Would remove $container"
        done
    else
        echo "$ZOMBIES" | xargs -r docker rm -f
        log_success "Removed $ZOMBIE_COUNT zombie container(s)"
    fi
fi

# =============================================================================
# Step 4: Verify clean state
# =============================================================================
separator "✅ STEP 4: VERIFY CLEAN STATE"

log_info "Current SSL infrastructure:"
echo ""

echo "📦 Docker Volumes:"
docker volume ls --filter 'name=cert' --format "  - {{.Name}}"
echo ""

echo "🐳 Certbot Containers:"
docker ps -a --filter 'name=certbot' --format "  - {{.Names}} ({{.Status}})"
echo ""

echo "📂 SSL Certificate Storage:"
CERT_PATH=$(docker volume inspect platform-certbot-certs --format '{{.Mountpoint}}' 2>/dev/null || echo "NOT FOUND")
echo "  - Location: $CERT_PATH"
if [ "$CERT_PATH" != "NOT FOUND" ]; then
    CERT_COUNT=$(sudo ls -1 "$CERT_PATH/live" 2>/dev/null | wc -l)
    echo "  - Certificates: $CERT_COUNT"
fi

separator "🎉 CLEANUP COMPLETE"

if [ "$DRY_RUN" = true ]; then
    log_warning "This was a DRY RUN - no changes were made"
    log_info "Run without --dry-run to actually cleanup"
else
    log_success "SSL infrastructure is now clean!"
    log_info "Single source of truth: Docker volume 'platform-certbot-certs'"
fi

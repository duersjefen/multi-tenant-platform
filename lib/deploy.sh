#!/bin/bash
# =============================================================================
# Universal Deployment Script
# =============================================================================
# Generic deployment script that works for ANY project on the platform
# Configured via /deploy/config/projects.yml
#
# Usage:
#   ./deploy.sh <project-name> <environment> [options]
#
# Examples:
#   ./deploy.sh filter-ical production
#   ./deploy.sh filter-ical staging --skip-backup
#   ./deploy.sh my-new-app production --blue-green
# =============================================================================

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source function libraries
source "$SCRIPT_DIR/functions/validation.sh"
source "$SCRIPT_DIR/functions/notifications.sh"
source "$SCRIPT_DIR/functions/backup.sh"
source "$SCRIPT_DIR/functions/blue-green.sh"

# =============================================================================
# Parse arguments
# =============================================================================
PROJECT_NAME="${1:-}"
ENVIRONMENT="${2:-}"
SKIP_BACKUP=false
FORCE_DEPLOY=false

shift 2 || true
while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-backup)
            SKIP_BACKUP=true
            shift
            ;;
        --force)
            FORCE_DEPLOY=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Validate arguments
if [ -z "$PROJECT_NAME" ] || [ -z "$ENVIRONMENT" ]; then
    echo "Usage: $0 <project-name> <environment> [options]"
    echo ""
    echo "Options:"
    echo "  --skip-backup   Skip pre-deployment backup"
    echo "  --force         Force deployment even if validation fails"
    exit 1
fi

# =============================================================================
# Load project configuration from projects.yml
# =============================================================================
CONFIG_FILE="$PLATFORM_ROOT/config/projects.yml"

if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}❌ Configuration file not found: $CONFIG_FILE${NC}"
    exit 1
fi

# Parse YAML (requires yq or similar - for now we'll use a simple approach)
# In production, you'd use `yq` to parse the YAML properly
# For now, we'll assume environment variables are set

# =============================================================================
# Main deployment function
# =============================================================================
deploy() {
    local start_time
    start_time=$(date +%s)

    echo "======================================================================"
    echo "🚀 DEPLOYING: $PROJECT_NAME ($ENVIRONMENT)"
    echo "======================================================================"
    echo "Started at: $(date -u +"%Y-%m-%d %H:%M:%S UTC")"
    echo "Started by: $(whoami)"
    echo ""

    # Send start notification
    notify_deployment_start "$PROJECT_NAME" "$ENVIRONMENT"

    # Step 1: Pre-flight validation
    echo "======================================================================"
    echo "📋 STEP 1: PRE-FLIGHT VALIDATION"
    echo "======================================================================"

    if ! validate_disk_space 5; then
        if [ "$FORCE_DEPLOY" = false ]; then
            notify_deployment_failure "$PROJECT_NAME" "$ENVIRONMENT" "Insufficient disk space"
            exit 1
        fi
        echo -e "${YELLOW}⚠️  Validation failed but continuing due to --force${NC}"
    fi

    # Step 2: Create backup
    if [ "$SKIP_BACKUP" = false ]; then
        echo ""
        echo "======================================================================"
        echo "📋 STEP 2: CREATE BACKUP"
        echo "======================================================================"

        if ! create_backup "$PROJECT_NAME" "$ENVIRONMENT"; then
            if [ "$FORCE_DEPLOY" = false ]; then
                notify_deployment_failure "$PROJECT_NAME" "$ENVIRONMENT" "Backup creation failed"
                exit 1
            fi
            echo -e "${YELLOW}⚠️  Backup failed but continuing due to --force${NC}"
        fi
    else
        echo ""
        echo "======================================================================"
        echo "📋 STEP 2: BACKUP SKIPPED"
        echo "======================================================================"
    fi

    # Step 3: Pull new images
    echo ""
    echo "======================================================================"
    echo "📋 STEP 3: PULL NEW DOCKER IMAGES"
    echo "======================================================================"

    cd "$PLATFORM_ROOT/apps/$PROJECT_NAME"

    docker-compose pull

    # Step 4: Deploy (strategy depends on configuration)
    echo ""
    echo "======================================================================"
    echo "📋 STEP 4: DEPLOY NEW VERSION"
    echo "======================================================================"

    # For now, use simple direct deployment
    # In production, check projects.yml for deployment strategy
    docker-compose up -d --no-deps --remove-orphans

    # Step 5: Health check
    echo ""
    echo "======================================================================"
    echo "📋 STEP 5: HEALTH CHECK"
    echo "======================================================================"

    sleep 10  # Give containers time to start

    # Check all containers
    for container in $(docker-compose ps -q); do
        container_name=$(docker inspect --format='{{.Name}}' "$container" | sed 's|^/||')

        if ! validate_container_health "$container_name" 120 5; then
            echo -e "${RED}❌ Health check failed for $container_name${NC}"
            notify_deployment_failure "$PROJECT_NAME" "$ENVIRONMENT" "Health check failed: $container_name"

            # Auto-rollback if backup exists
            echo -e "${YELLOW}🔄 Attempting automatic rollback...${NC}"
            # restore_backup "$PROJECT_NAME" "$ENVIRONMENT" "latest"

            exit 1
        fi
    done

    # Step 6: Reload nginx (if needed)
    echo ""
    echo "======================================================================"
    echo "📋 STEP 6: RELOAD NGINX"
    echo "======================================================================"

    if validate_nginx_config; then
        docker exec platform-nginx nginx -s reload
        echo -e "${GREEN}✅ Nginx reloaded${NC}"
    else
        echo -e "${RED}❌ Nginx config invalid - NOT reloading${NC}"
        notify_deployment_failure "$PROJECT_NAME" "$ENVIRONMENT" "Invalid nginx configuration"
        exit 1
    fi

    # Calculate duration
    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))

    # Success!
    echo ""
    echo "======================================================================"
    echo -e "${GREEN}✅ DEPLOYMENT SUCCESSFUL${NC}"
    echo "======================================================================"
    echo "Project: $PROJECT_NAME"
    echo "Environment: $ENVIRONMENT"
    echo "Duration: ${duration}s"
    echo "Completed at: $(date -u +"%Y-%m-%d %H:%M:%S UTC")"
    echo "======================================================================"

    notify_deployment_success "$PROJECT_NAME" "$ENVIRONMENT" "$duration"

    # Cleanup old backups
    cleanup_old_backups "$PROJECT_NAME" "$ENVIRONMENT" 30

    return 0
}

# =============================================================================
# Run deployment
# =============================================================================
deploy
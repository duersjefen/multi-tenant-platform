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
source "$SCRIPT_DIR/functions/manifest.sh"

# =============================================================================
# Parse arguments
# =============================================================================
PROJECT_NAME="${1:-}"
ENVIRONMENT="${2:-}"
SKIP_BACKUP=false
FORCE_DEPLOY=false

# Export ENVIRONMENT so docker-compose can use it
export ENVIRONMENT

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

    if ! validate_all "$PROJECT_NAME" "$ENVIRONMENT" "$PLATFORM_ROOT"; then
        if [ "$FORCE_DEPLOY" = false ]; then
            notify_deployment_failure "$PROJECT_NAME" "$ENVIRONMENT" "Pre-flight validation failed"
            exit 1
        fi
        echo -e "${YELLOW}⚠️  Validation failed but continuing due to --force${NC}"
    fi

    # Step 2: Create backup
    local backup_name="none"
    local database_backup_file="none"
    if [ "$SKIP_BACKUP" = false ]; then
        echo ""
        echo "======================================================================"
        echo "📋 STEP 2: CREATE BACKUP"
        echo "======================================================================"

        # Step 2.1: Backup database first (most critical)
        if database_backup_file=$(backup_database "$PROJECT_NAME" "$ENVIRONMENT"); then
            echo "📝 Database backup created"
        else
            if [ "$FORCE_DEPLOY" = false ]; then
                notify_deployment_failure "$PROJECT_NAME" "$ENVIRONMENT" "Database backup failed"
                exit 1
            fi
            echo -e "${YELLOW}⚠️  Database backup failed but continuing due to --force${NC}"
            database_backup_file="none"
        fi

        # Step 2.2: Backup containers and volumes
        if backup_name=$(create_backup "$PROJECT_NAME" "$ENVIRONMENT"); then
            echo "📝 Container backup created: $backup_name"
        else
            if [ "$FORCE_DEPLOY" = false ]; then
                notify_deployment_failure "$PROJECT_NAME" "$ENVIRONMENT" "Container backup failed"
                exit 1
            fi
            echo -e "${YELLOW}⚠️  Container backup failed but continuing due to --force${NC}"
            backup_name="none"
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

    cd "$PLATFORM_ROOT/configs/$PROJECT_NAME"

    # Docker Compose project name (includes environment suffix)
    COMPOSE_PROJECT="${PROJECT_NAME}-${ENVIRONMENT}"

    docker-compose -p "$COMPOSE_PROJECT" pull

    # Step 4: Deploy (strategy depends on configuration)
    echo ""
    echo "======================================================================"
    echo "📋 STEP 4: DEPLOY NEW VERSION"
    echo "======================================================================"

    # Stop and remove existing containers if they exist
    # Docker keeps stopped containers with their names, blocking new deployments
    echo "🔍 Checking for existing containers..."
    EXISTING_CONTAINERS=$(docker-compose -p "$COMPOSE_PROJECT" ps -q 2>/dev/null || true)
    if [ -n "$EXISTING_CONTAINERS" ]; then
        echo -e "${YELLOW}⚠️  Stopping and removing existing containers...${NC}"
        docker-compose -p "$COMPOSE_PROJECT" down --volumes
        echo -e "${GREEN}✅ Old containers removed${NC}"
    fi

    # Deploy new containers
    # --remove-orphans cleans up any containers not in current docker-compose
    docker-compose -p "$COMPOSE_PROJECT" up -d --remove-orphans

    # Step 4.5: Run database migrations (if backend exists)
    echo ""
    echo "======================================================================"
    echo "📋 STEP 4.5: DATABASE MIGRATIONS"
    echo "======================================================================"

    # Check if this project has a backend with Alembic
    if docker-compose -p "$COMPOSE_PROJECT" ps --services 2>/dev/null | grep -q "backend"; then
        echo "🗄️  Running database migrations..."

        # Wait for backend container to be ready
        sleep 5

        # Run migrations inside the backend container
        BACKEND_CONTAINER=$(docker-compose -p "$COMPOSE_PROJECT" ps -q backend 2>/dev/null | head -1)

        if [ -n "$BACKEND_CONTAINER" ]; then
            # Check if alembic exists in the container
            if docker exec "$BACKEND_CONTAINER" sh -c "command -v alembic" >/dev/null 2>&1; then
                # First-time setup: stamp database if alembic_version table doesn't exist
                if ! docker exec "$BACKEND_CONTAINER" sh -c "cd /app && python -c \"from alembic import command; from alembic.config import Config; cfg = Config('/app/alembic.ini'); command.current(cfg)\"" >/dev/null 2>&1; then
                    echo "📌 First deployment: stamping database to current version..."
                    docker exec "$BACKEND_CONTAINER" sh -c "cd /app && alembic stamp head"
                fi

                # Run migrations
                if docker exec "$BACKEND_CONTAINER" sh -c "cd /app && alembic upgrade head"; then
                    echo -e "${GREEN}✅ Database migrations applied${NC}"
                else
                    echo -e "${RED}❌ Migration failed!${NC}"
                    notify_deployment_failure "$PROJECT_NAME" "$ENVIRONMENT" "Database migration failed"
                    exit 1
                fi
            else
                echo "ℹ️  No Alembic found - skipping migrations"
            fi
        else
            echo -e "${YELLOW}⚠️  Backend container not found - skipping migrations${NC}"
        fi
    else
        echo "ℹ️  No backend service - skipping database migrations"
    fi

    # Step 5: Health check
    echo ""
    echo "======================================================================"
    echo "📋 STEP 5: HEALTH CHECK"
    echo "======================================================================"

    sleep 10  # Give containers time to start

    # Check all containers
    for container in $(docker-compose -p "$COMPOSE_PROJECT" ps -q); do
        container_name=$(docker inspect --format='{{.Name}}' "$container" | sed 's|^/||')

        if ! validate_container_health "$container_name" 120 5; then
            echo -e "${RED}❌ Health check failed for $container_name${NC}"
            notify_deployment_failure "$PROJECT_NAME" "$ENVIRONMENT" "Health check failed: $container_name"

            # Auto-rollback if backup exists
            local latest_backup
            if latest_backup=$(get_latest_backup "$PROJECT_NAME" "$ENVIRONMENT"); then
                echo -e "${YELLOW}🔄 Attempting automatic rollback to: $latest_backup${NC}"
                if restore_backup "$PROJECT_NAME" "$ENVIRONMENT" "$latest_backup"; then
                    echo -e "${GREEN}✅ Rollback successful${NC}"
                    notify_deployment_failure "$PROJECT_NAME" "$ENVIRONMENT" "Health check failed - rolled back to $latest_backup"
                else
                    echo -e "${RED}❌ Rollback failed${NC}"
                    notify_deployment_failure "$PROJECT_NAME" "$ENVIRONMENT" "Health check failed AND rollback failed"
                fi
            else
                echo -e "${YELLOW}⚠️  No backup available for rollback${NC}"
                notify_deployment_failure "$PROJECT_NAME" "$ENVIRONMENT" "Health check failed - no backup available"
            fi

            exit 1
        fi
    done

    # Step 5.5: Smoke tests (BEFORE traffic switch)
    echo ""
    echo "======================================================================"
    echo "📋 STEP 5.5: SMOKE TESTS (PRE-TRAFFIC SWITCH)"
    echo "======================================================================"

    if ! validate_smoke_tests "$PROJECT_NAME" "$ENVIRONMENT"; then
        echo -e "${RED}❌ Smoke tests failed${NC}"
        notify_deployment_failure "$PROJECT_NAME" "$ENVIRONMENT" "Smoke tests failed"

        # Auto-rollback if backup exists
        local latest_backup
        if latest_backup=$(get_latest_backup "$PROJECT_NAME" "$ENVIRONMENT"); then
            echo -e "${YELLOW}🔄 Attempting automatic rollback to: $latest_backup${NC}"
            if restore_backup "$PROJECT_NAME" "$ENVIRONMENT" "$latest_backup"; then
                echo -e "${GREEN}✅ Rollback successful${NC}"
                notify_deployment_failure "$PROJECT_NAME" "$ENVIRONMENT" "Smoke tests failed - rolled back to $latest_backup"
            else
                echo -e "${RED}❌ Rollback failed${NC}"
                notify_deployment_failure "$PROJECT_NAME" "$ENVIRONMENT" "Smoke tests failed AND rollback failed"
            fi
        else
            echo -e "${YELLOW}⚠️  No backup available for rollback${NC}"
            notify_deployment_failure "$PROJECT_NAME" "$ENVIRONMENT" "Smoke tests failed - no backup available"
        fi

        exit 1
    fi

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

    # Step 7: Cleanup dangling resources (AFTER successful deployment)
    echo ""
    echo "======================================================================"
    echo "📋 STEP 7: CLEANUP DANGLING RESOURCES"
    echo "======================================================================"

    # Cleanup dangling images (old containers already removed in Step 4)
    echo "🧹 Cleaning up dangling Docker images..."
    docker image prune -f > /dev/null 2>&1 || true
    echo -e "${GREEN}✅ Cleanup complete${NC}"

    # Calculate duration
    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))

    # Get git SHA from platform repo
    local git_sha
    git_sha=$(cd "$PLATFORM_ROOT" && git rev-parse HEAD 2>/dev/null || echo "unknown")

    # Step 8: Save deployment manifest
    echo ""
    echo "======================================================================"
    echo "📋 STEP 8: SAVE DEPLOYMENT MANIFEST"
    echo "======================================================================"

    save_deployment_manifest "$PROJECT_NAME" "$ENVIRONMENT" "$backup_name" "$git_sha" "$database_backup_file"

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
    cleanup_old_database_backups "$PROJECT_NAME" "$ENVIRONMENT" 30

    return 0
}

# =============================================================================
# Run deployment
# =============================================================================
deploy
#!/bin/bash
# =============================================================================
# Platform Infrastructure Deployment Script
# =============================================================================
# Deploys platform-level changes (nginx, monitoring, certbot)
# These changes affect ALL hosted projects!
#
# Usage:
#   ./lib/deploy-platform.sh <component> [options]
#
# Components:
#   nginx         - Reverse proxy and SSL termination
#   monitoring    - Prometheus, Grafana, Alertmanager
#   certbot       - SSL certificate management
#   all           - All platform components
#
# Options:
#   --skip-backup   Skip backup creation
#   --force         Deploy even if validation fails
#   --dry-run       Show what would be done without doing it
#
# Examples:
#   ./lib/deploy-platform.sh nginx
#   ./lib/deploy-platform.sh monitoring --skip-backup
#   ./lib/deploy-platform.sh all --dry-run
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

# =============================================================================
# Configuration
# =============================================================================
COMPONENT="${1:-}"
SKIP_BACKUP=false
FORCE_DEPLOY=false
DRY_RUN=false

shift 1 || true
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
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            exit 1
            ;;
    esac
done

# Validate component argument
if [ -z "$COMPONENT" ]; then
    echo "Usage: $0 <component> [options]"
    echo ""
    echo "Components:"
    echo "  nginx         - Reverse proxy and SSL termination"
    echo "  monitoring    - Prometheus, Grafana, Alertmanager"
    echo "  certbot       - SSL certificate management"
    echo "  all           - All platform components"
    echo ""
    echo "Options:"
    echo "  --skip-backup   Skip backup creation"
    echo "  --force         Deploy even if validation fails"
    echo "  --dry-run       Show what would be done without doing it"
    exit 1
fi

# Valid components
VALID_COMPONENTS=("nginx" "monitoring" "certbot" "all")
if [[ ! " ${VALID_COMPONENTS[@]} " =~ " ${COMPONENT} " ]]; then
    echo -e "${RED}❌ Invalid component: $COMPONENT${NC}"
    echo "Valid components: ${VALID_COMPONENTS[*]}"
    exit 1
fi

# =============================================================================
# Helper Functions
# =============================================================================

# Backup a Docker container
backup_container() {
    local container_name="$1"
    local backup_tag="$2"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY RUN] Would backup: $container_name → $backup_tag"
        return 0
    fi

    echo "📦 Creating backup of $container_name..."

    if ! docker ps --format '{{.Names}}' | grep -q "^${container_name}$"; then
        echo -e "${YELLOW}⚠️  Container $container_name not running - skipping backup${NC}"
        return 0
    fi

    if docker commit "$container_name" "$backup_tag"; then
        echo -e "${GREEN}✅ Backup created: $backup_tag${NC}"
        return 0
    else
        echo -e "${RED}❌ Failed to create backup${NC}"
        return 1
    fi
}

# Restore from backup
restore_container() {
    local container_name="$1"
    local backup_tag="$2"

    echo "🔄 Restoring $container_name from backup..."

    # Stop current container
    docker stop "$container_name" 2>/dev/null || true
    docker rm "$container_name" 2>/dev/null || true

    # Start from backup image
    # Note: This is simplified - in production you'd restore the full docker-compose setup
    echo -e "${YELLOW}⚠️  Manual rollback required:${NC}"
    echo "   1. docker compose -f platform/docker-compose.platform.yml down $container_name"
    echo "   2. Edit docker-compose.platform.yml to use backup image: $backup_tag"
    echo "   3. docker compose -f platform/docker-compose.platform.yml up -d $container_name"

    return 1  # Signal that manual intervention is needed
}

# Test all projects after platform change
test_all_projects() {
    echo "🧪 Testing all projects are accessible..."

    if ! "$SCRIPT_DIR/validate-all-projects.sh"; then
        echo -e "${RED}❌ Project validation failed!${NC}"
        return 1
    fi

    echo -e "${GREEN}✅ All projects accessible${NC}"
    return 0
}

# =============================================================================
# Component Deployment Functions
# =============================================================================

deploy_nginx() {
    local start_time
    start_time=$(date +%s)

    echo "======================================================================"
    echo "🚀 DEPLOYING PLATFORM COMPONENT: NGINX"
    echo "======================================================================"
    echo "⚠️  WARNING: This affects ALL hosted projects!"
    echo "Started at: $(date -u +"%Y-%m-%d %H:%M:%S UTC")"
    echo ""

    if [ "$DRY_RUN" = true ]; then
        echo -e "${BLUE}[DRY RUN MODE - No changes will be made]${NC}"
        echo ""
    fi

    # Step 1: Regenerate nginx configs from source of truth
    echo "======================================================================"
    echo "📋 STEP 1: REGENERATE NGINX CONFIGS"
    echo "======================================================================"

    if [ "$DRY_RUN" = false ]; then
        echo "🔧 Regenerating nginx configs from projects.yml..."
        cd "$PLATFORM_ROOT"

        if python3 lib/generate-nginx-configs.py; then
            echo -e "${GREEN}✅ Nginx configs regenerated successfully${NC}"
        else
            echo -e "${RED}❌ Config generation failed${NC}"
            if [ "$FORCE_DEPLOY" = false ]; then
                exit 1
            fi
            echo -e "${YELLOW}⚠️  Continuing despite failure due to --force${NC}"
        fi
    else
        echo "[DRY RUN] Would regenerate nginx configs from projects.yml"
    fi

    # Step 1.5: Provision SSL certificates (auto-creates placeholders if needed)
    echo ""
    echo "======================================================================"
    echo "📋 STEP 1.5: PROVISION SSL CERTIFICATES"
    echo "======================================================================"

    if [ "$DRY_RUN" = false ]; then
        echo "Checking for missing SSL certificates..."
        if "$SCRIPT_DIR/provision-ssl-certs.sh"; then
            echo -e "${GREEN}✅ SSL certificates provisioned${NC}"
        else
            echo -e "${YELLOW}⚠️  SSL provisioning had warnings (continuing)${NC}"
        fi
    else
        echo "[DRY RUN] Would provision missing SSL certificates"
    fi

    # Step 2: Pre-flight validation
    echo ""
    echo "======================================================================"
    echo "📋 STEP 2: PRE-FLIGHT VALIDATION"
    echo "======================================================================"

    # Validate nginx config syntax
    if [ "$DRY_RUN" = false ]; then
        if ! validate_nginx_config; then
            if [ "$FORCE_DEPLOY" = false ]; then
                echo -e "${RED}❌ Nginx config invalid - aborting${NC}"
                exit 1
            fi
            echo -e "${YELLOW}⚠️  Nginx config invalid but continuing due to --force${NC}"
        fi
    else
        echo "[DRY RUN] Would validate nginx config"
    fi

    # Validate disk space
    if ! validate_disk_space 2; then
        if [ "$FORCE_DEPLOY" = false ]; then
            exit 1
        fi
        echo -e "${YELLOW}⚠️  Low disk space but continuing due to --force${NC}"
    fi

    # Step 3: Backup current nginx
    if [ "$SKIP_BACKUP" = false ]; then
        echo ""
        echo "======================================================================"
        echo "📋 STEP 2: CREATE BACKUP"
        echo "======================================================================"

        BACKUP_TAG="platform-nginx-backup-$(date +%Y%m%d-%H%M%S)"

        if ! backup_container "platform-nginx" "$BACKUP_TAG"; then
            if [ "$FORCE_DEPLOY" = false ]; then
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

    # Step 3: Pull new image
    echo ""
    echo "======================================================================"
    echo "📋 STEP 3: PULL NEW NGINX IMAGE"
    echo "======================================================================"

    if [ "$DRY_RUN" = false ]; then
        cd "$PLATFORM_ROOT"
        docker compose -f platform/docker-compose.platform.yml pull nginx
    else
        echo "[DRY RUN] Would pull: macbre/nginx-http3:latest"
    fi

    # Step 5: Deploy new nginx
    echo ""
    echo "======================================================================"
    echo "📋 STEP 5: DEPLOY NEW NGINX"
    echo "======================================================================"

    if [ "$DRY_RUN" = false ]; then
        docker compose -f platform/docker-compose.platform.yml up -d nginx

        # Wait for nginx to start
        echo "⏳ Waiting for nginx to start..."
        sleep 5
    else
        echo "[DRY RUN] Would deploy new nginx container"
    fi

    # Step 6: Validate nginx health
    echo ""
    echo "======================================================================"
    echo "📋 STEP 6: HEALTH CHECK"
    echo "======================================================================"

    if [ "$DRY_RUN" = false ]; then
        if ! validate_container_health "platform-nginx" 60 5; then
            echo -e "${RED}❌ Nginx health check failed!${NC}"

            if [ "$SKIP_BACKUP" = false ]; then
                echo ""
                echo -e "${YELLOW}🔄 ATTEMPTING ROLLBACK...${NC}"
                restore_container "platform-nginx" "$BACKUP_TAG"
            fi

            exit 1
        fi
    else
        echo "[DRY RUN] Would validate nginx health"
    fi

    # Step 7: Test all projects
    echo ""
    echo "======================================================================"
    echo "📋 STEP 7: VALIDATE ALL PROJECTS"
    echo "======================================================================"

    if [ "$DRY_RUN" = false ]; then
        if ! test_all_projects; then
            echo -e "${RED}❌ Project validation failed!${NC}"

            if [ "$SKIP_BACKUP" = false ]; then
                echo ""
                echo -e "${YELLOW}🔄 ATTEMPTING ROLLBACK...${NC}"
                restore_container "platform-nginx" "$BACKUP_TAG"
            fi

            exit 1
        fi
    else
        echo "[DRY RUN] Would validate all projects"
    fi

    # Step 8: Cleanup old images
    echo ""
    echo "======================================================================"
    echo "📋 STEP 8: CLEANUP"
    echo "======================================================================"

    if [ "$DRY_RUN" = false ]; then
        echo "🧹 Cleaning up old Docker images..."
        docker image prune -f > /dev/null 2>&1 || true
        echo -e "${GREEN}✅ Cleanup complete${NC}"
    else
        echo "[DRY RUN] Would cleanup old images"
    fi

    # Calculate duration
    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))

    # Success!
    echo ""
    echo "======================================================================"
    echo -e "${GREEN}✅ NGINX DEPLOYMENT SUCCESSFUL${NC}"
    echo "======================================================================"
    echo "Component: nginx"
    echo "Duration: ${duration}s"
    echo "Completed at: $(date -u +"%Y-%m-%d %H:%M:%S UTC")"

    if [ "$SKIP_BACKUP" = false ]; then
        echo ""
        echo "💾 Backup available for rollback:"
        echo "   Tag: $BACKUP_TAG"
        echo "   To rollback: docker tag $BACKUP_TAG <image> && redeploy"
    fi

    echo "======================================================================"

    return 0
}

deploy_monitoring() {
    echo "======================================================================"
    echo "🚀 DEPLOYING PLATFORM COMPONENT: MONITORING"
    echo "======================================================================"
    echo "Components: Prometheus, Grafana, Alertmanager"
    echo ""

    if [ "$DRY_RUN" = true ]; then
        echo -e "${BLUE}[DRY RUN MODE]${NC}"
        echo "Would deploy: prometheus, grafana, alertmanager, node-exporter, cadvisor"
        return 0
    fi

    cd "$PLATFORM_ROOT"

    echo "📦 Pulling latest monitoring images..."
    docker compose -f platform/docker-compose.platform.yml pull prometheus grafana alertmanager node-exporter cadvisor

    echo "🚀 Deploying monitoring stack..."
    docker compose -f platform/docker-compose.platform.yml up -d prometheus grafana alertmanager node-exporter cadvisor

    echo "⏳ Waiting for services to start..."
    sleep 10

    # Validate each service
    for service in prometheus grafana alertmanager; do
        if ! validate_container_health "platform-$service" 60 5; then
            echo -e "${RED}❌ $service failed to start${NC}"
            return 1
        fi
    done

    echo -e "${GREEN}✅ Monitoring stack deployed successfully${NC}"
    return 0
}

deploy_certbot() {
    echo "======================================================================"
    echo "🚀 DEPLOYING PLATFORM COMPONENT: CERTBOT"
    echo "======================================================================"
    echo "SSL Certificate Management"
    echo ""

    if [ "$DRY_RUN" = true ]; then
        echo -e "${BLUE}[DRY RUN MODE]${NC}"
        echo "Would deploy: certbot"
        return 0
    fi

    cd "$PLATFORM_ROOT"

    echo "📦 Pulling latest certbot image..."
    docker compose -f platform/docker-compose.platform.yml pull certbot

    echo "🚀 Deploying certbot..."
    docker compose -f platform/docker-compose.platform.yml up -d certbot

    echo -e "${GREEN}✅ Certbot deployed successfully${NC}"
    return 0
}

deploy_all() {
    echo "======================================================================"
    echo "🚀 DEPLOYING ALL PLATFORM COMPONENTS"
    echo "======================================================================"
    echo "⚠️  WARNING: This is a major platform update!"
    echo ""

    if [ "$DRY_RUN" = true ]; then
        echo -e "${BLUE}[DRY RUN MODE]${NC}"
    fi

    # Deploy in order of dependency
    deploy_nginx || return 1
    echo ""

    deploy_monitoring || return 1
    echo ""

    deploy_certbot || return 1
    echo ""

    echo "======================================================================"
    echo -e "${GREEN}✅ ALL PLATFORM COMPONENTS DEPLOYED${NC}"
    echo "======================================================================"

    return 0
}

# =============================================================================
# Main Deployment Logic
# =============================================================================

main() {
    case "$COMPONENT" in
        nginx)
            deploy_nginx
            ;;
        monitoring)
            deploy_monitoring
            ;;
        certbot)
            deploy_certbot
            ;;
        all)
            deploy_all
            ;;
        *)
            echo -e "${RED}❌ Unknown component: $COMPONENT${NC}"
            exit 1
            ;;
    esac
}

# Run main deployment
main

#!/bin/bash
# =============================================================================
# Blue-Green Deployment Functions
# =============================================================================
# Zero-downtime deployment by switching traffic between blue/green environments
# Source this file: source /deploy/lib/functions/blue-green.sh
# =============================================================================

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# =============================================================================
# get_active_environment
# Returns the currently active environment (blue or green)
# =============================================================================
get_active_environment() {
    local project_name="$1"

    # Check which environment is currently receiving traffic
    # This could be stored in a file, Redis, or environment variable
    local state_file="/opt/websites/state/${project_name}.active"

    if [ -f "$state_file" ]; then
        cat "$state_file"
    else
        # Default to blue if no state file exists
        echo "blue"
    fi
}

# =============================================================================
# get_inactive_environment
# Returns the currently inactive environment (the one to deploy to)
# =============================================================================
get_inactive_environment() {
    local project_name="$1"
    local active
    active=$(get_active_environment "$project_name")

    if [ "$active" = "blue" ]; then
        echo "green"
    else
        echo "blue"
    fi
}

# =============================================================================
# deploy_to_inactive
# Deploys new version to the inactive environment
# =============================================================================
deploy_to_inactive() {
    local project_name="$1"
    local inactive
    inactive=$(get_inactive_environment "$project_name")

    echo -e "${BLUE}🚀 Deploying to INACTIVE environment: $inactive${NC}"

    # Pull new images with environment-specific tags
    docker-compose -f "/deploy/apps/${project_name}/docker-compose.yml" pull

    # Start containers in inactive environment
    docker-compose -f "/deploy/apps/${project_name}/docker-compose.yml" \
        up -d --no-deps --scale "${project_name}-${inactive}=1"

    echo -e "${GREEN}✅ Deployed to $inactive environment${NC}"
    return 0
}

# =============================================================================
# validate_inactive_environment
# Validates that the inactive environment is healthy before switching
# =============================================================================
validate_inactive_environment() {
    local project_name="$1"
    local inactive
    inactive=$(get_inactive_environment "$project_name")

    echo -e "${BLUE}🔍 Validating $inactive environment...${NC}"

    # Source validation functions
    source "$(dirname "${BASH_SOURCE[0]}")/validation.sh"

    # Check container health
    for container in $(docker ps --filter "name=${project_name}-${inactive}" --format "{{.Names}}"); do
        if ! validate_container_health "$container" 120 5; then
            return 1
        fi
    done

    # Check application health endpoints
    # This would be configured per-project in projects.yml
    # For now, we'll do a simple HTTP check
    local health_url="http://localhost:3000/health"  # Example
    if ! validate_health_endpoint "$health_url" 200 10 5; then
        return 1
    fi

    echo -e "${GREEN}✅ $inactive environment is healthy${NC}"
    return 0
}

# =============================================================================
# switch_traffic
# Switches traffic from active to inactive environment
# =============================================================================
switch_traffic() {
    local project_name="$1"
    local current_active
    local new_active

    current_active=$(get_active_environment "$project_name")
    new_active=$(get_inactive_environment "$project_name")

    echo -e "${BLUE}🔄 Switching traffic: $current_active → $new_active${NC}"

    # Update nginx upstream to point to new environment
    # This could be done by:
    # 1. Updating nginx config and reloading
    # 2. Using a service discovery mechanism
    # 3. Updating environment variables and restarting nginx

    # Example: Update state file
    local state_dir="/opt/websites/state"
    mkdir -p "$state_dir"
    echo "$new_active" > "$state_dir/${project_name}.active"

    # Reload nginx to pick up new configuration
    docker exec platform-nginx nginx -s reload

    echo -e "${GREEN}✅ Traffic switched to $new_active environment${NC}"
    return 0
}

# =============================================================================
# cleanup_old_environment
# Stops and removes containers from the old environment
# =============================================================================
cleanup_old_environment() {
    local project_name="$1"
    local wait_time="${2:-300}"  # Wait 5 minutes by default

    local old_environment
    # The old environment is now the inactive one (we just switched)
    old_environment=$(get_inactive_environment "$project_name")

    echo -e "${YELLOW}⏳ Waiting ${wait_time}s before cleaning up $old_environment environment...${NC}"
    sleep "$wait_time"

    echo -e "${BLUE}🗑️  Cleaning up $old_environment environment...${NC}"

    # Stop containers from old environment
    for container in $(docker ps --filter "name=${project_name}-${old_environment}" --format "{{.Names}}"); do
        echo "Stopping $container..."
        docker stop "$container"
    done

    echo -e "${GREEN}✅ Cleaned up $old_environment environment${NC}"
    return 0
}

# =============================================================================
# rollback
# Rolls back to the previous environment
# =============================================================================
rollback() {
    local project_name="$1"

    echo -e "${RED}⚠️  ROLLING BACK DEPLOYMENT${NC}"

    # Switch traffic back to the old environment
    local current_active
    local rollback_to

    current_active=$(get_active_environment "$project_name")
    if [ "$current_active" = "blue" ]; then
        rollback_to="green"
    else
        rollback_to="blue"
    fi

    echo -e "${BLUE}🔄 Rolling back: $current_active → $rollback_to${NC}"

    # Check if rollback environment is still running
    if ! docker ps --filter "name=${project_name}-${rollback_to}" --format "{{.Names}}" | grep -q "${project_name}"; then
        echo -e "${RED}❌ Cannot rollback: $rollback_to environment is not running${NC}"
        return 1
    fi

    # Update state file
    local state_dir="/opt/websites/state"
    echo "$rollback_to" > "$state_dir/${project_name}.active"

    # Reload nginx
    docker exec platform-nginx nginx -s reload

    echo -e "${GREEN}✅ Rolled back to $rollback_to environment${NC}"
    return 0
}

# =============================================================================
# blue_green_deploy
# Main blue-green deployment orchestration
# =============================================================================
blue_green_deploy() {
    local project_name="$1"

    echo "======================================================================"
    echo "🔵 BLUE-GREEN DEPLOYMENT: $project_name"
    echo "======================================================================"

    local active
    local inactive

    active=$(get_active_environment "$project_name")
    inactive=$(get_inactive_environment "$project_name")

    echo "Current active environment: $active"
    echo "Deploying to: $inactive"
    echo ""

    # Step 1: Deploy to inactive environment
    if ! deploy_to_inactive "$project_name"; then
        echo -e "${RED}❌ Deployment to $inactive failed${NC}"
        return 1
    fi

    # Step 2: Validate inactive environment
    if ! validate_inactive_environment "$project_name"; then
        echo -e "${RED}❌ Validation of $inactive failed - rolling back${NC}"
        rollback "$project_name"
        return 1
    fi

    # Step 3: Switch traffic
    if ! switch_traffic "$project_name"; then
        echo -e "${RED}❌ Traffic switch failed - rolling back${NC}"
        rollback "$project_name"
        return 1
    fi

    # Step 4: Cleanup old environment (in background)
    cleanup_old_environment "$project_name" 300 &

    echo ""
    echo -e "${GREEN}✅ BLUE-GREEN DEPLOYMENT SUCCESSFUL${NC}"
    echo "======================================================================"
    return 0
}
#!/bin/bash
# =============================================================================
# Deployment Manifest Functions
# =============================================================================
# Track deployment state and history
# Source this file: source /deploy/lib/functions/manifest.sh
# =============================================================================

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# =============================================================================
# save_deployment_manifest
# Saves deployment state and history
# =============================================================================
save_deployment_manifest() {
    local project_name="$1"
    local environment="$2"
    local backup_name="${3:-none}"
    local git_sha="${4:-unknown}"
    local database_backup_file="${5:-none}"
    local manifest_dir="/opt/deployments/${project_name}/${environment}"
    local manifest_file="${manifest_dir}/manifest.json"

    echo "📝 Saving deployment manifest..."

    mkdir -p "$manifest_dir"

    # Get current images from running containers
    local compose_project="${project_name}-${environment}"
    local images_json="{"
    local first=true

    for container in $(docker-compose -p "$compose_project" ps -q 2>/dev/null); do
        local container_name=$(docker inspect --format='{{.Name}}' "$container" | sed 's|^/||')
        local image=$(docker inspect --format='{{.Config.Image}}' "$container")
        local service_name="${container_name#${project_name}-}"
        service_name="${service_name%-${environment}}"

        if [ "$first" = true ]; then
            first=false
        else
            images_json+=","
        fi

        images_json+="\"${service_name}\":\"${image}\""
    done
    images_json+="}"

    # Create deployment record
    local deployment_record=$(cat <<EOF
{
  "version": "latest",
  "deployed_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "deployed_by": "$(whoami)",
  "git_sha": "${git_sha}",
  "backup": "${backup_name}",
  "database_backup": "${database_backup_file}",
  "images": ${images_json}
}
EOF
)

    # Load existing manifest or create new one
    if [ -f "$manifest_file" ]; then
        # Append to history (keep last 10 deployments)
        local current_deployment=$(cat "$manifest_file" | jq -r '.current_deployment')
        local history=$(cat "$manifest_file" | jq -r '.deployment_history // []')

        # Add current to history
        local updated_history=$(echo "$history" | jq --argjson current "$current_deployment" '. + [$current] | .[-10:]')

        # Create new manifest with updated history
        cat > "$manifest_file" <<EOF
{
  "project": "${project_name}",
  "environment": "${environment}",
  "current_deployment": ${deployment_record},
  "deployment_history": ${updated_history}
}
EOF
    else
        # Create new manifest
        cat > "$manifest_file" <<EOF
{
  "project": "${project_name}",
  "environment": "${environment}",
  "current_deployment": ${deployment_record},
  "deployment_history": []
}
EOF
    fi

    echo -e "${GREEN}✅ Deployment manifest saved${NC}"
    echo "   Location: $manifest_file"
    return 0
}

# =============================================================================
# get_deployment_status
# Shows current deployment status
# =============================================================================
get_deployment_status() {
    local project_name="$1"
    local environment="$2"
    local manifest_file="/opt/deployments/${project_name}/${environment}/manifest.json"

    if [ ! -f "$manifest_file" ]; then
        echo -e "${YELLOW}⚠️  No deployment manifest found${NC}"
        return 1
    fi

    echo "======================================================================"
    echo -e "${BLUE}📊 DEPLOYMENT STATUS: ${project_name} (${environment})${NC}"
    echo "======================================================================"

    # Parse and display current deployment
    local deployed_at=$(jq -r '.current_deployment.deployed_at' "$manifest_file")
    local deployed_by=$(jq -r '.current_deployment.deployed_by' "$manifest_file")
    local git_sha=$(jq -r '.current_deployment.git_sha' "$manifest_file")
    local backup=$(jq -r '.current_deployment.backup' "$manifest_file")

    echo "🕒 Deployed: $deployed_at"
    echo "👤 By: $deployed_by"
    echo "📝 Commit: $git_sha"
    echo "💾 Backup: $backup"
    echo ""
    echo "📦 Images:"
    jq -r '.current_deployment.images | to_entries[] | "   \(.key): \(.value)"' "$manifest_file"

    # Show deployment history count
    local history_count=$(jq -r '.deployment_history | length' "$manifest_file")
    echo ""
    echo "📜 History: $history_count previous deployment(s)"

    echo "======================================================================"
    return 0
}

# =============================================================================
# get_deployment_history
# Shows deployment history
# =============================================================================
get_deployment_history() {
    local project_name="$1"
    local environment="$2"
    local manifest_file="/opt/deployments/${project_name}/${environment}/manifest.json"

    if [ ! -f "$manifest_file" ]; then
        echo -e "${YELLOW}⚠️  No deployment history found${NC}"
        return 1
    fi

    echo "======================================================================"
    echo -e "${BLUE}📜 DEPLOYMENT HISTORY: ${project_name} (${environment})${NC}"
    echo "======================================================================"

    # Show current deployment
    echo ""
    echo -e "${GREEN}CURRENT:${NC}"
    jq -r '.current_deployment | "  🕒 \(.deployed_at)\n  👤 \(.deployed_by)\n  📝 \(.git_sha)\n  💾 \(.backup)"' "$manifest_file"

    # Show history
    local history_count=$(jq -r '.deployment_history | length' "$manifest_file")

    if [ "$history_count" -gt 0 ]; then
        echo ""
        echo -e "${YELLOW}HISTORY (last ${history_count} deployments):${NC}"
        jq -r '.deployment_history[] | "  🕒 \(.deployed_at)\n  👤 \(.deployed_by)\n  📝 \(.git_sha)\n  💾 \(.backup)\n"' "$manifest_file"
    fi

    echo "======================================================================"
    return 0
}

# =============================================================================
# get_rollback_info
# Gets information about available rollback options
# =============================================================================
get_rollback_info() {
    local project_name="$1"
    local environment="$2"
    local manifest_file="/opt/deployments/${project_name}/${environment}/manifest.json"

    if [ ! -f "$manifest_file" ]; then
        echo -e "${YELLOW}⚠️  No deployment manifest found${NC}"
        return 1
    fi

    echo "======================================================================"
    echo -e "${BLUE}🔄 ROLLBACK OPTIONS: ${project_name} (${environment})${NC}"
    echo "======================================================================"

    # Get current backup
    local current_backup=$(jq -r '.current_deployment.backup' "$manifest_file")
    echo -e "${GREEN}Current deployment backup:${NC} $current_backup"

    # Get previous deployment info
    local history_count=$(jq -r '.deployment_history | length' "$manifest_file")

    if [ "$history_count" -gt 0 ]; then
        echo ""
        echo -e "${YELLOW}Available rollback targets:${NC}"

        # Show last 3 deployments from history
        jq -r '.deployment_history[-3:] | reverse[] | "  💾 \(.backup) (deployed \(.deployed_at) by \(.deployed_by))"' "$manifest_file"
    else
        echo ""
        echo -e "${YELLOW}⚠️  No previous deployments in history${NC}"
    fi

    echo "======================================================================"
    return 0
}

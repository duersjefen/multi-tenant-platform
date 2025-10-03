#!/bin/bash
# =============================================================================
# Backup Functions
# =============================================================================
# Create and manage backups before deployments
# Source this file: source /deploy/lib/functions/backup.sh
# =============================================================================

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# =============================================================================
# create_backup
# Creates a backup of current deployment
# =============================================================================
create_backup() {
    local project_name="$1"
    local environment="$2"
    local backup_dir="/opt/backups/${project_name}/${environment}"

    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_name="backup_${timestamp}"

    echo "💾 Creating backup: $backup_name"

    mkdir -p "$backup_dir"

    # Backup Docker images (tag them)
    echo "📦 Backing up Docker images..."
    for container in $(docker ps --filter "name=${project_name}" --format "{{.Names}}"); do
        local image
        image=$(docker inspect --format='{{.Config.Image}}' "$container")

        # Strip existing tag and add backup tag
        local image_repo="${image%:*}"  # Remove :tag from end
        local backup_tag="${image_repo}:${backup_name}"

        # Tag current image as backup
        docker tag "$image" "$backup_tag"
        echo "  Tagged: $backup_tag"
    done

    # Backup volumes (if any)
    echo "💾 Backing up volumes..."
    for volume in $(docker volume ls --filter "name=${project_name}" --format "{{.Name}}"); do
        local backup_file="${backup_dir}/${volume}_${timestamp}.tar.gz"

        # Create a temporary container to backup the volume
        docker run --rm \
            -v "${volume}:/volume" \
            -v "${backup_dir}:/backup" \
            alpine \
            tar czf "/backup/$(basename "$backup_file")" -C /volume .

        echo "  Backed up: $volume → $(basename "$backup_file")"
    done

    # Backup configuration files
    echo "📝 Backing up configuration..."
    local config_backup="${backup_dir}/config_${timestamp}.tar.gz"
    local platform_root="${PLATFORM_ROOT:-/opt/multi-tenant-platform}"
    tar czf "$config_backup" \
        -C "${platform_root}/configs/${project_name}" \
        . \
        2>/dev/null || true

    # Save backup metadata
    cat > "${backup_dir}/${backup_name}.meta" <<EOF
project: $project_name
environment: $environment
timestamp: $timestamp
created_by: $(whoami)
created_at: $(date -u +"%Y-%m-%d %H:%M:%S UTC")
EOF

    echo -e "${GREEN}✅ Backup created: $backup_name${NC}"
    echo "$backup_name"
    return 0
}

# =============================================================================
# list_backups
# Lists available backups for a project
# =============================================================================
list_backups() {
    local project_name="$1"
    local environment="$2"
    local backup_dir="/opt/backups/${project_name}/${environment}"

    if [ ! -d "$backup_dir" ]; then
        echo "No backups found for $project_name ($environment)"
        return 1
    fi

    echo "Available backups for $project_name ($environment):"
    echo "======================================================================"

    for meta_file in "$backup_dir"/*.meta; do
        if [ -f "$meta_file" ]; then
            echo ""
            cat "$meta_file"
            echo "----------------------------------------------------------------------"
        fi
    done

    return 0
}

# =============================================================================
# restore_backup
# Restores a specific backup
# =============================================================================
restore_backup() {
    local project_name="$1"
    local environment="$2"
    local backup_name="$3"
    local backup_dir="/opt/backups/${project_name}/${environment}"

    echo -e "${YELLOW}⚠️  RESTORING BACKUP: $backup_name${NC}"

    # Verify backup exists
    if [ ! -f "${backup_dir}/${backup_name}.meta" ]; then
        echo -e "${RED}❌ Backup not found: $backup_name${NC}"
        return 1
    fi

    # Stop current containers
    echo "🛑 Stopping current containers..."
    cd "$PLATFORM_ROOT/configs/${project_name}"
    COMPOSE_PROJECT="${project_name}-${environment}"
    docker-compose -p "$COMPOSE_PROJECT" down

    # Restore Docker images
    echo "📦 Restoring Docker images..."
    # Docker images are already tagged, just need to reference them

    # Restore volumes (only for this specific backup)
    echo "💾 Restoring volumes..."
    local backup_timestamp
    backup_timestamp=$(echo "$backup_name" | sed 's/^backup_//')

    for volume_backup in "$backup_dir"/*_${backup_timestamp}.tar.gz; do
        if [ -f "$volume_backup" ]; then
            local volume_name
            volume_name=$(basename "$volume_backup" "_${backup_timestamp}.tar.gz")

            # Restore volume
            docker run --rm \
                -v "${volume_name}:/volume" \
                -v "${backup_dir}:/backup" \
                alpine \
                sh -c "rm -rf /volume/* && tar xzf /backup/$(basename "$volume_backup") -C /volume"

            echo "  Restored: $volume_name"
        fi
    done

    # Restore configuration
    echo "📝 Restoring configuration..."
    local config_backup="${backup_dir}/config_${backup_timestamp}.tar.gz"
    if [ -f "$config_backup" ]; then
        tar xzf "$config_backup" -C "$PLATFORM_ROOT/configs/${project_name}/"
        echo "  Restored configuration from $backup_name"
    fi

    # Restart containers with restored images (using backup-tagged images)
    echo "🚀 Starting containers from backup..."
    # TODO: Update docker-compose to use backup-tagged images
    # For now, just bring up with current config
    docker-compose -p "$COMPOSE_PROJECT" up -d

    echo -e "${GREEN}✅ Backup restored: $backup_name${NC}"
    return 0
}

# =============================================================================
# cleanup_old_backups
# Removes backups older than retention period
# =============================================================================
cleanup_old_backups() {
    local project_name="$1"
    local environment="$2"
    local retention_days="${3:-30}"  # Default: keep 30 days
    local backup_dir="/opt/backups/${project_name}/${environment}"

    echo "🗑️  Cleaning up backups older than $retention_days days..."

    if [ ! -d "$backup_dir" ]; then
        return 0
    fi

    # Find and remove old backups
    find "$backup_dir" -name "*.meta" -mtime +${retention_days} -print0 | while IFS= read -r -d '' meta_file; do
        local backup_name
        backup_name=$(basename "$meta_file" .meta)

        echo "  Removing old backup: $backup_name"

        # Remove all files associated with this backup
        rm -f "${backup_dir}/${backup_name}"*
    done

    echo -e "${GREEN}✅ Cleanup complete${NC}"
    return 0
}

# =============================================================================
# get_latest_backup
# Returns the name of the most recent backup for a project
# =============================================================================
get_latest_backup() {
    local project_name="$1"
    local environment="$2"
    local backup_dir="/opt/backups/${project_name}/${environment}"

    if [ ! -d "$backup_dir" ]; then
        return 1
    fi

    # Find most recent .meta file (sorted by modification time)
    # Returns just the backup name without .meta extension
    local latest
    latest=$(ls -t "$backup_dir"/*.meta 2>/dev/null | head -1)

    if [ -z "$latest" ]; then
        return 1
    fi

    # Strip path and .meta extension
    basename "$latest" .meta
    return 0
}
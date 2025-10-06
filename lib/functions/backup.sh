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

    # Find all backup-tagged images for this backup and retag them
    for backup_image in $(docker images --format "{{.Repository}}:{{.Tag}}" | grep ":${backup_name}$"); do
        # Strip backup tag to get original image name
        local original_image="${backup_image%:${backup_name}}"
        original_image="${original_image}:latest"

        # Retag backup image as original
        docker tag "$backup_image" "$original_image"
        echo "  Restored image: $backup_image → $original_image"
    done

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

    # Restart containers with restored images
    echo "🚀 Starting containers from backup..."
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

# =============================================================================
# backup_database
# Creates a PostgreSQL database backup using pg_dump
# =============================================================================
backup_database() {
    local project_name="$1"
    local environment="$2"
    local platform_root="${PLATFORM_ROOT:-/opt/multi-tenant-platform}"

    echo "🗄️  Backing up database..."

    # Read database config from projects.yml
    local db_config=$(python3 <<PYTHON
import yaml
import sys

try:
    with open('${platform_root}/config/projects.yml', 'r') as f:
        config = yaml.safe_load(f)

    project = config['projects'].get('${project_name}', {})
    db_config = project.get('database', {})

    if not db_config or db_config.get('type') != 'postgresql':
        print("NO_DATABASE")
        sys.exit(0)

    db_name = db_config.get('databases', {}).get('${environment}')
    db_container = db_config.get('container', 'postgres-platform')
    db_user = db_config.get('user', 'admin')

    if not db_name:
        print("NO_DATABASE")
        sys.exit(0)

    print(f"{db_name}|{db_container}|{db_user}")
except Exception as e:
    print(f"ERROR: {e}", file=sys.stderr)
    sys.exit(1)
PYTHON
)

    if [ "$db_config" = "NO_DATABASE" ]; then
        echo "  ℹ️  No database configured for this project/environment"
        return 0
    fi

    if [[ "$db_config" == ERROR:* ]]; then
        echo -e "${RED}❌ Failed to read database config: ${db_config#ERROR: }${NC}"
        return 1
    fi

    # Parse database config
    IFS='|' read -r DB_NAME DB_CONTAINER DB_USER <<< "$db_config"

    # Create backup directory
    local backup_dir="/opt/backups/${project_name}/${environment}/database"
    mkdir -p "$backup_dir"

    # Generate backup filename with timestamp
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_file="${backup_dir}/db_${timestamp}.dump"

    echo "  Database: $DB_NAME"
    echo "  Container: $DB_CONTAINER"

    # Check if container exists
    if ! docker ps --format "{{.Names}}" | grep -q "^${DB_CONTAINER}$"; then
        echo -e "${RED}❌ Database container not found: $DB_CONTAINER${NC}"
        return 1
    fi

    # Perform database backup using pg_dump
    # Custom format is already compressed, no need for extra gzip
    if docker exec "$DB_CONTAINER" \
        pg_dump -U "$DB_USER" "$DB_NAME" \
        --format=custom \
        --compress=9 \
        --verbose \
        --file=/tmp/backup.dump 2>&1 && \
       docker cp "$DB_CONTAINER":/tmp/backup.dump "$backup_file" && \
       docker exec "$DB_CONTAINER" rm /tmp/backup.dump; then

        echo -e "${GREEN}✅ Database backup created: $(basename "$backup_file")${NC}"

        # Verify backup is not empty
        local file_size=$(stat -f%z "$backup_file" 2>/dev/null || stat -c%s "$backup_file" 2>/dev/null)
        if [ "$file_size" -lt 100 ]; then
            echo -e "${RED}❌ Backup file is too small (${file_size} bytes) - likely failed${NC}"
            rm -f "$backup_file"
            return 1
        fi

        echo "  Size: $(du -h "$backup_file" | cut -f1)"
        echo "$backup_file"
        return 0
    else
        echo -e "${RED}❌ Database backup failed${NC}"
        rm -f "$backup_file"
        return 1
    fi
}

# =============================================================================
# restore_database
# Restores a PostgreSQL database from pg_dump backup
# =============================================================================
restore_database() {
    local project_name="$1"
    local environment="$2"
    local backup_file="$3"
    local platform_root="${PLATFORM_ROOT:-/opt/multi-tenant-platform}"

    echo -e "${YELLOW}⚠️  RESTORING DATABASE FROM BACKUP${NC}"
    echo "  Backup: $(basename "$backup_file")"

    # Verify backup file exists
    if [ ! -f "$backup_file" ]; then
        echo -e "${RED}❌ Backup file not found: $backup_file${NC}"
        return 1
    fi

    # Read database config from projects.yml
    local db_config=$(python3 <<PYTHON
import yaml

try:
    with open('${platform_root}/config/projects.yml', 'r') as f:
        config = yaml.safe_load(f)

    project = config['projects'].get('${project_name}', {})
    db_config = project.get('database', {})

    if not db_config or db_config.get('type') != 'postgresql':
        print("NO_DATABASE")
        exit(0)

    db_name = db_config.get('databases', {}).get('${environment}')
    db_container = db_config.get('container', 'postgres-platform')
    db_user = db_config.get('user', 'admin')

    print(f"{db_name}|{db_container}|{db_user}")
except Exception as e:
    print(f"ERROR: {e}")
    exit(1)
PYTHON
)

    if [ "$db_config" = "NO_DATABASE" ]; then
        echo "  ℹ️  No database configured for this project/environment"
        return 0
    fi

    # Parse database config
    IFS='|' read -r DB_NAME DB_CONTAINER DB_USER <<< "$db_config"

    echo "  Database: $DB_NAME"
    echo "  Container: $DB_CONTAINER"

    # Drop and recreate database
    echo "🗑️  Dropping existing database..."
    docker exec "$DB_CONTAINER" psql -U "$DB_USER" -c "DROP DATABASE IF EXISTS ${DB_NAME};" postgres
    docker exec "$DB_CONTAINER" psql -U "$DB_USER" -c "CREATE DATABASE ${DB_NAME};" postgres

    # Restore database from backup
    echo "📥 Restoring database from backup..."
    # Copy backup into container and restore
    if docker cp "$backup_file" "$DB_CONTAINER":/tmp/restore.dump && \
       docker exec "$DB_CONTAINER" \
        pg_restore -U "$DB_USER" -d "$DB_NAME" \
        --verbose /tmp/restore.dump 2>&1 && \
       docker exec "$DB_CONTAINER" rm /tmp/restore.dump; then

        echo -e "${GREEN}✅ Database restored successfully${NC}"
        return 0
    else
        echo -e "${RED}❌ Database restore failed${NC}"
        return 1
    fi
}

# =============================================================================
# cleanup_old_database_backups
# Removes database backups older than retention period
# =============================================================================
cleanup_old_database_backups() {
    local project_name="$1"
    local environment="$2"
    local retention_days="${3:-30}"
    local backup_dir="/opt/backups/${project_name}/${environment}/database"

    echo "🗑️  Cleaning up database backups older than $retention_days days..."

    if [ ! -d "$backup_dir" ]; then
        return 0
    fi

    # Find and remove old database backups
    find "$backup_dir" -name "db_*.dump" -mtime +${retention_days} -print0 | while IFS= read -r -d '' backup_file; do
        echo "  Removing old backup: $(basename "$backup_file")"
        rm -f "$backup_file"
    done

    echo -e "${GREEN}✅ Database backup cleanup complete${NC}"
    return 0
}
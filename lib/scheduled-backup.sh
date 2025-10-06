#!/bin/bash
# =============================================================================
# Scheduled Database Backup Script
# =============================================================================
# Runs daily (via cron) to backup all databases configured in projects.yml
#
# Installation:
#   # Add to cron (daily at 2 AM UTC)
#   0 2 * * * /opt/multi-tenant-platform/lib/scheduled-backup.sh
#
# Usage:
#   ./scheduled-backup.sh [--dry-run]
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

# Source function libraries
source "$SCRIPT_DIR/functions/backup.sh"
source "$SCRIPT_DIR/functions/notifications.sh"

# Settings
DRY_RUN=false

# Parse arguments
for arg in "$@"; do
    case $arg in
        --dry-run)
            DRY_RUN=true
            ;;
    esac
done

# =============================================================================
# Main backup function
# =============================================================================
backup_all_databases() {
    echo "========================================================================"
    echo "🗄️  SCHEDULED DATABASE BACKUP"
    echo "========================================================================"
    echo "Started at: $(date -u +"%Y-%m-%d %H:%M:%S UTC")"
    echo ""

    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}⚠️  DRY RUN MODE - No actual backups will be created${NC}"
        echo ""
    fi

    local total_backups=0
    local successful_backups=0
    local failed_backups=0

    # Get all projects with database configuration
    local projects=$(python3 <<'PYTHON'
import yaml
import sys

try:
    with open('config/projects.yml', 'r') as f:
        config = yaml.safe_load(f)

    projects_list = []
    for project_name, project_config in config.get('projects', {}).items():
        db_config = project_config.get('database', {})

        if not db_config or db_config.get('type') != 'postgresql':
            continue

        # Check if database backup is enabled
        backup_config = db_config.get('backup', {})
        if not backup_config.get('enabled', True):
            continue

        databases = db_config.get('databases', {})
        for environment, db_name in databases.items():
            projects_list.append(f"{project_name}:{environment}")

    for item in projects_list:
        print(item)

except Exception as e:
    print(f"ERROR: {e}", file=sys.stderr)
    sys.exit(1)
PYTHON
)

    if [ -z "$projects" ]; then
        echo "ℹ️  No databases configured for backup"
        return 0
    fi

    # Backup each database
    while IFS=':' read -r project environment; do
        echo "========================================================================"
        echo "📦 Backing up: $project ($environment)"
        echo "========================================================================"

        total_backups=$((total_backups + 1))

        if [ "$DRY_RUN" = true ]; then
            echo "  [DRY RUN] Would backup database"
            successful_backups=$((successful_backups + 1))
            echo ""
            continue
        fi

        if backup_file=$(backup_database "$project" "$environment"); then
            echo -e "${GREEN}✅ Backup successful${NC}"
            successful_backups=$((successful_backups + 1))

            # Cleanup old backups
            cleanup_old_database_backups "$project" "$environment" 30
        else
            echo -e "${RED}❌ Backup failed${NC}"
            failed_backups=$((failed_backups + 1))

            # Send notification about failure
            notify_backup_failure "$project" "$environment"
        fi

        echo ""
    done <<< "$projects"

    # Summary
    echo "========================================================================"
    echo "📊 BACKUP SUMMARY"
    echo "========================================================================"
    echo "Total databases: $total_backups"
    echo "Successful: $successful_backups"
    echo "Failed: $failed_backups"
    echo "Completed at: $(date -u +"%Y-%m-%d %H:%M:%S UTC")"
    echo "========================================================================"

    # Send summary notification if there were failures
    if [ $failed_backups -gt 0 ]; then
        echo -e "${RED}⚠️  Some backups failed - check logs${NC}"
        return 1
    else
        echo -e "${GREEN}✅ All backups completed successfully${NC}"
        return 0
    fi
}

# =============================================================================
# Notification helper
# =============================================================================
notify_backup_failure() {
    local project="$1"
    local environment="$2"

    # Send notification (if notification system is available)
    if type notify_deployment_failure >/dev/null 2>&1; then
        notify_deployment_failure "$project" "$environment" "Scheduled database backup failed"
    fi
}

# =============================================================================
# Run backup
# =============================================================================
cd "$PLATFORM_ROOT"

if backup_all_databases; then
    exit 0
else
    exit 1
fi

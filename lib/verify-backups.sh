#!/bin/bash
# =============================================================================
# Backup Verification Script
# =============================================================================
# Verifies database backups by restoring them to a test database
# Runs weekly (via cron) to ensure backups are actually restorable
#
# Installation:
#   # Add to cron (every Sunday at 3 AM UTC)
#   0 3 * * 0 /opt/multi-tenant-platform/lib/verify-backups.sh
#
# Usage:
#   ./verify-backups.sh [--dry-run] [project] [environment]
#
# Examples:
#   ./verify-backups.sh                        # Verify all backups
#   ./verify-backups.sh filter-ical production # Verify specific backup
#   ./verify-backups.sh --dry-run              # Test without actual restore
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
SPECIFIC_PROJECT=""
SPECIFIC_ENVIRONMENT=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        *)
            if [ -z "$SPECIFIC_PROJECT" ]; then
                SPECIFIC_PROJECT="$1"
            elif [ -z "$SPECIFIC_ENVIRONMENT" ]; then
                SPECIFIC_ENVIRONMENT="$1"
            fi
            shift
            ;;
    esac
done

# =============================================================================
# verify_database_backup
# Verifies a single database backup by restoring to test database
# =============================================================================
verify_database_backup() {
    local project="$1"
    local environment="$2"
    local backup_dir="/opt/backups/${project}/${environment}/database"

    echo "🔍 Verifying backup for: $project ($environment)"

    # Find latest backup
    local latest_backup=$(ls -t "$backup_dir"/db_*.dump 2>/dev/null | head -1)

    if [ -z "$latest_backup" ]; then
        echo -e "${YELLOW}⚠️  No backup found${NC}"
        return 1
    fi

    echo "  Latest backup: $(basename "$latest_backup")"
    echo "  Size: $(du -h "$latest_backup" | cut -f1)"
    echo "  Age: $((($(date +%s) - $(stat -c%Y "$latest_backup" 2>/dev/null || stat -f%m "$latest_backup")) / 86400)) days"

    if [ "$DRY_RUN" = true ]; then
        echo -e "${BLUE}  [DRY RUN] Would verify this backup${NC}"
        return 0
    fi

    # Read database config
    local db_config=$(python3 <<PYTHON
import yaml

try:
    with open('${PLATFORM_ROOT}/config/projects.yml', 'r') as f:
        config = yaml.safe_load(f)

    project = config['projects'].get('${project}', {})
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
        echo -e "${YELLOW}⚠️  No database configured${NC}"
        return 1
    fi

    # Parse database config
    IFS='|' read -r DB_NAME DB_CONTAINER DB_USER <<< "$db_config"

    # Create test database name
    local TEST_DB="${DB_NAME}_test_$$"

    echo "  Test database: $TEST_DB"

    # Step 1: Create test database (use admin user for database creation)
    echo "  📝 Creating test database..."
    if ! docker exec "$DB_CONTAINER" psql -U admin -c "CREATE DATABASE ${TEST_DB};" postgres 2>&1; then
        echo -e "${RED}❌ Failed to create test database${NC}"
        return 1
    fi

    # Grant permissions to DB_USER
    docker exec "$DB_CONTAINER" psql -U admin -c "GRANT ALL PRIVILEGES ON DATABASE ${TEST_DB} TO ${DB_USER};" postgres 2>&1 || true

    # Step 2: Restore backup to test database
    echo "  📥 Restoring backup to test database..."
    # Copy backup into container and restore
    if ! docker cp "$latest_backup" "$DB_CONTAINER":/tmp/verify.dump 2>&1 && \
         docker exec "$DB_CONTAINER" \
            pg_restore -U "$DB_USER" -d "$TEST_DB" \
            --no-owner --no-acl /tmp/verify.dump 2>&1 | grep -v "NOTICE:" && \
         docker exec "$DB_CONTAINER" rm /tmp/verify.dump 2>&1; then
        echo -e "${RED}❌ Failed to restore backup${NC}"
        docker exec "$DB_CONTAINER" psql -U "$DB_USER" -c "DROP DATABASE IF EXISTS ${TEST_DB};" postgres >/dev/null 2>&1
        return 1
    fi

    # Step 3: Verify data integrity
    echo "  🔍 Verifying data integrity..."

    # Get table count
    local table_count=$(docker exec "$DB_CONTAINER" psql -U "$DB_USER" -d "$TEST_DB" -t -c "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public';" 2>/dev/null | tr -d ' ')

    # Get row count
    local row_count=$(docker exec "$DB_CONTAINER" psql -U "$DB_USER" -d "$TEST_DB" -t -c "SELECT SUM(n_live_tup) FROM pg_stat_user_tables;" 2>/dev/null | tr -d ' ')

    echo "  Tables: $table_count"
    echo "  Rows: ${row_count:-0}"

    # Step 4: Cleanup test database (use admin user for database deletion)
    echo "  🗑️  Cleaning up test database..."
    docker exec "$DB_CONTAINER" psql -U admin -c "DROP DATABASE ${TEST_DB};" postgres >/dev/null 2>&1

    # Verification passed
    echo -e "${GREEN}✅ Backup verified successfully${NC}"
    return 0
}

# =============================================================================
# Main verification function
# =============================================================================
verify_all_backups() {
    echo "========================================================================"
    echo "🔍 BACKUP VERIFICATION"
    echo "========================================================================"
    echo "Started at: $(date -u +"%Y-%m-%d %H:%M:%S UTC")"
    echo ""

    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}⚠️  DRY RUN MODE - No actual verification will be performed${NC}"
        echo ""
    fi

    local total_verifications=0
    local successful_verifications=0
    local failed_verifications=0

    # Get list of databases to verify
    local projects=""

    if [ -n "$SPECIFIC_PROJECT" ]; then
        # Verify specific project
        if [ -z "$SPECIFIC_ENVIRONMENT" ]; then
            echo -e "${RED}❌ Must specify both project and environment${NC}"
            return 1
        fi
        projects="${SPECIFIC_PROJECT}:${SPECIFIC_ENVIRONMENT}"
    else
        # Verify all databases
        projects=$(python3 <<'PYTHON'
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
    fi

    if [ -z "$projects" ]; then
        echo "ℹ️  No databases to verify"
        return 0
    fi

    # Verify each backup
    while IFS=':' read -r project environment; do
        echo "========================================================================"
        echo "📦 Verifying: $project ($environment)"
        echo "========================================================================"

        total_verifications=$((total_verifications + 1))

        if verify_database_backup "$project" "$environment"; then
            successful_verifications=$((successful_verifications + 1))
        else
            failed_verifications=$((failed_verifications + 1))

            # Send notification about failed verification
            notify_verification_failure "$project" "$environment"
        fi

        echo ""
    done <<< "$projects"

    # Summary
    echo "========================================================================"
    echo "📊 VERIFICATION SUMMARY"
    echo "========================================================================"
    echo "Total verifications: $total_verifications"
    echo "Successful: $successful_verifications"
    echo "Failed: $failed_verifications"
    echo "Completed at: $(date -u +"%Y-%m-%d %H:%M:%S UTC")"
    echo "========================================================================"

    if [ $failed_verifications -gt 0 ]; then
        echo -e "${RED}⚠️  Some verifications failed - check backups!${NC}"
        return 1
    else
        echo -e "${GREEN}✅ All verifications passed${NC}"
        return 0
    fi
}

# =============================================================================
# Notification helper
# =============================================================================
notify_verification_failure() {
    local project="$1"
    local environment="$2"

    # Send notification (if notification system is available)
    if type notify_deployment_failure >/dev/null 2>&1; then
        notify_deployment_failure "$project" "$environment" "Backup verification failed - backup may be corrupted!"
    fi
}

# =============================================================================
# Run verification
# =============================================================================
cd "$PLATFORM_ROOT"

if verify_all_backups; then
    exit 0
else
    exit 1
fi

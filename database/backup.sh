#!/bin/bash
# =============================================================================
# Multi-Tenant Platform - Database Backup Script
# =============================================================================
# Backs up all databases to /opt/backups with timestamps
# Run via cron: 0 2 * * * /opt/platform/database/backup.sh
# =============================================================================

set -e

BACKUP_DIR="/opt/backups/postgres"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
CONTAINER_NAME="postgres-platform"

# Create backup directory
mkdir -p "$BACKUP_DIR"

# Databases to backup
DATABASES=(
    "filter_ical_production"
    "filter_ical_staging"
    "gabs_massage_production"
    "gabs_massage_staging"
)

echo "🗄️  Starting database backups..."

for db in "${DATABASES[@]}"; do
    echo "  Backing up: $db"
    docker exec "$CONTAINER_NAME" pg_dump -U platform_admin -d "$db" | \
        gzip > "$BACKUP_DIR/${db}_${TIMESTAMP}.sql.gz"
done

echo "✅ Backups complete: $BACKUP_DIR"

# Keep only last 7 days of backups
find "$BACKUP_DIR" -name "*.sql.gz" -mtime +7 -delete

echo "🧹 Old backups cleaned up"

#!/bin/bash
# =============================================================================
# Universal Rollback Script
# =============================================================================
# Rolls back to a previous deployment
#
# Usage:
#   ./rollback.sh <project-name> <environment> [backup-name]
#
# Examples:
#   ./rollback.sh filter-ical production
#   ./rollback.sh filter-ical production backup_20250930_143000
# =============================================================================

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source function libraries
source "$SCRIPT_DIR/functions/backup.sh"
source "$SCRIPT_DIR/functions/notifications.sh"

# =============================================================================
# Parse arguments
# =============================================================================
PROJECT_NAME="${1:-}"
ENVIRONMENT="${2:-}"
BACKUP_NAME="${3:-latest}"

if [ -z "$PROJECT_NAME" ] || [ -z "$ENVIRONMENT" ]; then
    echo "Usage: $0 <project-name> <environment> [backup-name]"
    exit 1
fi

# =============================================================================
# Main rollback function
# =============================================================================
rollback() {
    echo "======================================================================"
    echo -e "${RED}⚠️  ROLLING BACK: $PROJECT_NAME ($ENVIRONMENT)${NC}"
    echo "======================================================================"
    echo "Started at: $(date -u +"%Y-%m-%d %H:%M:%S UTC")"
    echo "Backup: $BACKUP_NAME"
    echo ""

    # Send notification
    notify_rollback "$PROJECT_NAME" "$ENVIRONMENT" "Manual rollback requested"

    # Resolve "latest" to actual backup name
    if [ "$BACKUP_NAME" = "latest" ]; then
        echo "Finding most recent backup..."
        BACKUP_NAME=$(get_latest_backup "$PROJECT_NAME" "$ENVIRONMENT")

        if [ -z "$BACKUP_NAME" ]; then
            echo -e "${RED}❌ No backups found for $PROJECT_NAME ($ENVIRONMENT)${NC}"
            list_backups "$PROJECT_NAME" "$ENVIRONMENT" || true
            return 1
        fi

        echo -e "${GREEN}✓ Using backup: $BACKUP_NAME${NC}"
    fi

    # Restore backup
    if restore_backup "$PROJECT_NAME" "$ENVIRONMENT" "$BACKUP_NAME"; then
        echo ""
        echo -e "${GREEN}✅ ROLLBACK SUCCESSFUL${NC}"
        echo "======================================================================"
        return 0
    else
        echo ""
        echo -e "${RED}❌ ROLLBACK FAILED${NC}"
        echo "======================================================================"
        return 1
    fi
}

# =============================================================================
# Run rollback
# =============================================================================
rollback
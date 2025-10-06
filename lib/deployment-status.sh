#!/bin/bash
# =============================================================================
# Deployment Status Viewer
# =============================================================================
# View deployment status and history
#
# Usage:
#   ./deployment-status.sh <project-name> <environment> [options]
#
# Options:
#   --history    Show deployment history
#   --rollback   Show rollback options
#
# Examples:
#   ./deployment-status.sh filter-ical production
#   ./deployment-status.sh filter-ical staging --history
#   ./deployment-status.sh filter-ical production --rollback
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
source "$SCRIPT_DIR/functions/manifest.sh"

# =============================================================================
# Parse arguments
# =============================================================================
PROJECT_NAME="${1:-}"
ENVIRONMENT="${2:-}"
SHOW_HISTORY=false
SHOW_ROLLBACK=false

shift 2 || true
while [[ $# -gt 0 ]]; do
    case "$1" in
        --history)
            SHOW_HISTORY=true
            shift
            ;;
        --rollback)
            SHOW_ROLLBACK=true
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
    echo "  --history    Show deployment history"
    echo "  --rollback   Show rollback options"
    echo ""
    echo "Examples:"
    echo "  $0 filter-ical production"
    echo "  $0 filter-ical staging --history"
    echo "  $0 filter-ical production --rollback"
    exit 1
fi

# =============================================================================
# Display deployment information
# =============================================================================

if [ "$SHOW_HISTORY" = true ]; then
    get_deployment_history "$PROJECT_NAME" "$ENVIRONMENT"
elif [ "$SHOW_ROLLBACK" = true ]; then
    get_rollback_info "$PROJECT_NAME" "$ENVIRONMENT"
else
    get_deployment_status "$PROJECT_NAME" "$ENVIRONMENT"
fi

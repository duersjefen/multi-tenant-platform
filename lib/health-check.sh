#!/bin/bash
# =============================================================================
# Universal Health Check Script
# =============================================================================
# Checks health of all services for a project
#
# Usage:
#   ./health-check.sh <project-name> <environment>
#
# Examples:
#   ./health-check.sh filter-ical production
#   ./health-check.sh filter-ical staging
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
source "$SCRIPT_DIR/functions/validation.sh"

# =============================================================================
# Parse arguments
# =============================================================================
PROJECT_NAME="${1:-}"
ENVIRONMENT="${2:-}"

if [ -z "$PROJECT_NAME" ] || [ -z "$ENVIRONMENT" ]; then
    echo "Usage: $0 <project-name> <environment>"
    exit 1
fi

# =============================================================================
# Main health check function
# =============================================================================
health_check() {
    echo "======================================================================"
    echo "🏥 HEALTH CHECK: $PROJECT_NAME ($ENVIRONMENT)"
    echo "======================================================================"
    echo ""

    local all_healthy=true

    # Check container health
    echo "🔍 Checking containers..."
    for container in $(docker ps --filter "name=${PROJECT_NAME}" --format "{{.Names}}"); do
        if docker inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null | grep -q "healthy\|none"; then
            echo -e "  ${GREEN}✅ $container${NC}"
        else
            echo -e "  ${RED}❌ $container${NC}"
            all_healthy=false
        fi
    done

    # Check HTTP endpoints (configure these per project)
    echo ""
    echo "🔍 Checking HTTP endpoints..."

    # Production
    if [ "$ENVIRONMENT" = "production" ]; then
        if validate_health_endpoint "https://filter-ical.de/health" 200 10 1; then
            echo -e "  ${GREEN}✅ https://filter-ical.de/health${NC}"
        else
            echo -e "  ${RED}❌ https://filter-ical.de/health${NC}"
            all_healthy=false
        fi
    fi

    # Staging
    if [ "$ENVIRONMENT" = "staging" ]; then
        if validate_health_endpoint "https://staging.filter-ical.de/health" 200 10 1; then
            echo -e "  ${GREEN}✅ https://staging.filter-ical.de/health${NC}"
        else
            echo -e "  ${RED}❌ https://staging.filter-ical.de/health${NC}"
            all_healthy=false
        fi
    fi

    # Summary
    echo ""
    echo "======================================================================"
    if [ "$all_healthy" = true ]; then
        echo -e "${GREEN}✅ ALL CHECKS PASSED${NC}"
        echo "======================================================================"
        return 0
    else
        echo -e "${RED}❌ SOME CHECKS FAILED${NC}"
        echo "======================================================================"
        return 1
    fi
}

# =============================================================================
# Run health check
# =============================================================================
health_check
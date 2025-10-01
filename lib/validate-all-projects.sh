#!/bin/bash
# =============================================================================
# Validate All Projects Script
# =============================================================================
# Tests that all hosted projects are accessible
# Used after platform changes to ensure no projects were broken
#
# Usage:
#   ./lib/validate-all-projects.sh [options]
#
# Options:
#   --staging-only    Only test staging environments
#   --prod-only       Only test production environments
#   --timeout N       HTTP timeout in seconds (default: 10)
#   --verbose         Show detailed output
#
# Exit codes:
#   0 - All projects accessible
#   1 - One or more projects failed
# =============================================================================

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# =============================================================================
# Configuration
# =============================================================================
TEST_STAGING=true
TEST_PRODUCTION=true
TIMEOUT=10
VERBOSE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --staging-only)
            TEST_PRODUCTION=false
            shift
            ;;
        --prod-only)
            TEST_STAGING=false
            shift
            ;;
        --timeout)
            TIMEOUT="$2"
            shift 2
            ;;
        --verbose)
            VERBOSE=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# =============================================================================
# Project Definitions (from projects.yml)
# =============================================================================
# TODO: In future, parse projects.yml with yq
# For now, hardcode based on current projects.yml

declare -A PROJECTS

# filter-ical
PROJECTS[filter-ical-prod]="https://filter-ical.de"
PROJECTS[filter-ical-staging]="https://staging.filter-ical.de"

# paiss
PROJECTS[paiss-prod]="https://paiss.me"
PROJECTS[paiss-staging]="https://staging.paiss.me"

# monitoring
PROJECTS[monitoring-prod]="https://monitoring.paiss.me"

# =============================================================================
# Test Functions
# =============================================================================

test_url() {
    local name="$1"
    local url="$2"
    local expected_status="${3:-200}"

    if [ "$VERBOSE" = true ]; then
        echo -n "  Testing $url ... "
    fi

    # Make HTTP request with timeout
    local status_code
    status_code=$(curl -s -o /dev/null -w "%{http_code}" \
        --max-time "$TIMEOUT" \
        --connect-timeout "$TIMEOUT" \
        --insecure \
        "$url" 2>/dev/null || echo "000")

    # Check status
    if [ "$status_code" = "$expected_status" ] || [ "$status_code" = "200" ]; then
        if [ "$VERBOSE" = true ]; then
            echo -e "${GREEN}✅ OK (HTTP $status_code)${NC}"
        fi
        return 0
    else
        echo -e "${RED}❌ FAILED: $name${NC}"
        echo -e "   URL: $url"
        echo -e "   Expected: $expected_status, Got: $status_code"
        return 1
    fi
}

# =============================================================================
# Main Validation
# =============================================================================

main() {
    echo "======================================================================"
    echo "🧪 VALIDATING ALL HOSTED PROJECTS"
    echo "======================================================================"
    echo "Timeout: ${TIMEOUT}s per request"

    if [ "$TEST_PRODUCTION" = false ]; then
        echo "Scope: Staging environments only"
    elif [ "$TEST_STAGING" = false ]; then
        echo "Scope: Production environments only"
    else
        echo "Scope: All environments"
    fi

    echo ""

    local failed_projects=()
    local tested_count=0
    local passed_count=0

    # Test each project
    for project_key in "${!PROJECTS[@]}"; do
        local url="${PROJECTS[$project_key]}"

        # Filter by environment
        if [[ "$project_key" == *-staging ]] && [ "$TEST_STAGING" = false ]; then
            continue
        fi
        if [[ "$project_key" == *-prod ]] && [ "$TEST_PRODUCTION" = false ]; then
            continue
        fi

        tested_count=$((tested_count + 1))

        # Display project being tested
        if [ "$VERBOSE" = false ]; then
            echo -n "Testing $project_key ... "
        else
            echo ""
            echo "Testing: $project_key"
        fi

        # Run test
        if test_url "$project_key" "$url"; then
            if [ "$VERBOSE" = false ]; then
                echo -e "${GREEN}✅${NC}"
            fi
            passed_count=$((passed_count + 1))
        else
            failed_projects+=("$project_key")
            # Error already printed by test_url
        fi
    done

    # Summary
    echo ""
    echo "======================================================================"
    echo "VALIDATION SUMMARY"
    echo "======================================================================"
    echo "Tested: $tested_count projects"
    echo "Passed: $passed_count projects"
    echo "Failed: ${#failed_projects[@]} projects"
    echo ""

    if [ ${#failed_projects[@]} -eq 0 ]; then
        echo -e "${GREEN}✅ ALL PROJECTS ACCESSIBLE${NC}"
        echo "======================================================================"
        return 0
    else
        echo -e "${RED}❌ SOME PROJECTS FAILED${NC}"
        echo ""
        echo "Failed projects:"
        for project in "${failed_projects[@]}"; do
            echo "  - $project: ${PROJECTS[$project]}"
        done
        echo "======================================================================"
        return 1
    fi
}

# Run validation
main

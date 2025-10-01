#!/bin/bash
# =============================================================================
# Platform Testing Script
# =============================================================================
# Tests platform configuration before deployment
# Run this BEFORE deploying platform changes to catch errors early
#
# Usage:
#   ./lib/test-platform.sh [component]
#
# Components:
#   nginx         - Test nginx configuration
#   monitoring    - Test monitoring configuration
#   all           - Test all components (default)
#
# Examples:
#   ./lib/test-platform.sh           # Test everything
#   ./lib/test-platform.sh nginx     # Test only nginx
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

# Component to test
COMPONENT="${1:-all}"

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# =============================================================================
# Test Helper Functions
# =============================================================================

test_start() {
    local test_name="$1"
    echo -n "  Testing: $test_name ... "
    TESTS_RUN=$((TESTS_RUN + 1))
}

test_pass() {
    echo -e "${GREEN}✅ PASS${NC}"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

test_fail() {
    local reason="$1"
    echo -e "${RED}❌ FAIL${NC}"
    echo -e "    Reason: $reason"
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

# =============================================================================
# Nginx Tests
# =============================================================================

test_nginx() {
    echo ""
    echo "======================================================================"
    echo "🧪 TESTING NGINX CONFIGURATION"
    echo "======================================================================"

    # Test 1: Nginx config files exist
    test_start "Nginx config files exist"
    if [ -f "$PLATFORM_ROOT/platform/nginx/nginx.conf" ] && \
       [ -d "$PLATFORM_ROOT/platform/nginx/conf.d" ] && \
       [ -d "$PLATFORM_ROOT/platform/nginx/includes" ]; then
        test_pass
    else
        test_fail "Missing nginx config files or directories"
    fi

    # Test 2: Nginx syntax validation (if nginx container is running)
    test_start "Nginx config syntax (in container)"
    if docker ps --format '{{.Names}}' | grep -q "platform-nginx"; then
        if docker exec platform-nginx nginx -t 2>&1 | grep -q "syntax is ok"; then
            test_pass
        else
            test_fail "Nginx config syntax errors"
        fi
    else
        echo -e "${YELLOW}⚠️  SKIP (container not running)${NC}"
    fi

    # Test 3: Check for HTTP/3 listeners
    test_start "HTTP/3 listeners configured"
    if grep -r "listen 443 quic" "$PLATFORM_ROOT/platform/nginx/conf.d/" > /dev/null 2>&1; then
        test_pass
    else
        test_fail "No HTTP/3 (QUIC) listeners found in server blocks"
    fi

    # Test 4: Check for Alt-Svc header
    test_start "Alt-Svc header configured"
    if grep -q "Alt-Svc.*h3=" "$PLATFORM_ROOT/platform/nginx/nginx.conf"; then
        test_pass
    else
        test_fail "Alt-Svc header not found (needed for HTTP/3 discovery)"
    fi

    # Test 5: Check for security headers include
    test_start "Security headers included in configs"
    if grep -r "include.*security-headers.conf" "$PLATFORM_ROOT/platform/nginx/conf.d/" > /dev/null 2>&1; then
        test_pass
    else
        test_fail "Security headers not included in project configs"
    fi

    # Test 6: Check for dynamic resolution pattern
    test_start "Dynamic DNS resolution pattern"
    if grep -r "set \$.*_host" "$PLATFORM_ROOT/platform/nginx/conf.d/" > /dev/null 2>&1; then
        test_pass
    else
        test_fail "Dynamic DNS resolution not used (containers may fail to start)"
    fi

    # Test 7: Check no hardcoded proxy_pass URLs
    test_start "No hardcoded proxy_pass (should use variables)"
    if grep -r "proxy_pass http://" "$PLATFORM_ROOT/platform/nginx/conf.d/" | grep -v '\$' > /dev/null 2>&1; then
        test_fail "Found hardcoded proxy_pass URLs (should use variables)"
    else
        test_pass
    fi

    # Test 8: Check nginx includes directory
    test_start "Nginx includes directory has required files"
    if [ -f "$PLATFORM_ROOT/platform/nginx/includes/security-headers.conf" ] && \
       [ -f "$PLATFORM_ROOT/platform/nginx/includes/proxy-headers.conf" ]; then
        test_pass
    else
        test_fail "Missing required include files"
    fi

    # Test 9: Check for SSL certificate paths
    test_start "SSL certificate paths configured"
    if grep -r "ssl_certificate.*letsencrypt" "$PLATFORM_ROOT/platform/nginx/conf.d/" > /dev/null 2>&1; then
        test_pass
    else
        test_fail "SSL certificates not configured"
    fi

    # Test 10: Check rate limiting configured
    test_start "Rate limiting zones defined"
    if grep -q "limit_req_zone" "$PLATFORM_ROOT/platform/nginx/nginx.conf"; then
        test_pass
    else
        test_fail "Rate limiting not configured"
    fi
}

# =============================================================================
# Docker Compose Tests
# =============================================================================

test_docker_compose() {
    echo ""
    echo "======================================================================"
    echo "🧪 TESTING DOCKER COMPOSE CONFIGURATION"
    echo "======================================================================"

    # Test 1: docker-compose.platform.yml exists
    test_start "docker-compose.platform.yml exists"
    if [ -f "$PLATFORM_ROOT/platform/docker-compose.platform.yml" ]; then
        test_pass
    else
        test_fail "docker-compose.platform.yml not found"
    fi

    # Test 2: Validate docker-compose syntax
    test_start "docker-compose.platform.yml syntax"
    if docker compose -f "$PLATFORM_ROOT/platform/docker-compose.platform.yml" config > /dev/null 2>&1; then
        test_pass
    else
        test_fail "docker-compose.platform.yml has syntax errors"
    fi

    # Test 3: Check for HTTP/3 nginx image
    test_start "HTTP/3-capable nginx image configured"
    if grep -q "image:.*nginx-http3" "$PLATFORM_ROOT/platform/docker-compose.platform.yml"; then
        test_pass
    else
        test_fail "Not using HTTP/3-capable nginx image"
    fi

    # Test 4: Check UDP port 443 exposed
    test_start "UDP port 443 exposed for HTTP/3"
    if grep -q "443:443/udp" "$PLATFORM_ROOT/platform/docker-compose.platform.yml"; then
        test_pass
    else
        test_fail "UDP port 443 not exposed (required for HTTP/3/QUIC)"
    fi

    # Test 5: Check platform network exists
    test_start "Platform network configured"
    if grep -q "platform:" "$PLATFORM_ROOT/platform/docker-compose.platform.yml"; then
        test_pass
    else
        test_fail "Platform network not configured"
    fi
}

# =============================================================================
# Monitoring Tests
# =============================================================================

test_monitoring() {
    echo ""
    echo "======================================================================"
    echo "🧪 TESTING MONITORING CONFIGURATION"
    echo "======================================================================"

    # Test 1: Prometheus config exists
    test_start "Prometheus configuration exists"
    if [ -f "$PLATFORM_ROOT/platform/monitoring/prometheus/prometheus.yml" ]; then
        test_pass
    else
        test_fail "prometheus.yml not found"
    fi

    # Test 2: Grafana provisioning exists
    test_start "Grafana provisioning configured"
    if [ -d "$PLATFORM_ROOT/platform/monitoring/grafana/provisioning" ]; then
        test_pass
    else
        test_fail "Grafana provisioning directory not found"
    fi

    # Test 3: Alertmanager config exists
    test_start "Alertmanager configuration exists"
    if [ -f "$PLATFORM_ROOT/platform/monitoring/alertmanager/alertmanager.yml" ]; then
        test_pass
    else
        test_fail "alertmanager.yml not found"
    fi
}

# =============================================================================
# Projects Configuration Tests
# =============================================================================

test_projects_config() {
    echo ""
    echo "======================================================================"
    echo "🧪 TESTING PROJECTS CONFIGURATION"
    echo "======================================================================"

    # Test 1: projects.yml exists
    test_start "projects.yml exists"
    if [ -f "$PLATFORM_ROOT/config/projects.yml" ]; then
        test_pass
    else
        test_fail "config/projects.yml not found"
    fi

    # Test 2: Project configs exist
    test_start "Project deployment configs exist"
    local missing_configs=()

    # Check filter-ical
    if [ ! -d "$PLATFORM_ROOT/configs/filter-ical" ]; then
        missing_configs+=("filter-ical")
    fi

    # Check paiss
    if [ ! -d "$PLATFORM_ROOT/configs/paiss" ]; then
        missing_configs+=("paiss")
    fi

    if [ ${#missing_configs[@]} -eq 0 ]; then
        test_pass
    else
        test_fail "Missing configs: ${missing_configs[*]}"
    fi

    # Test 3: Nginx configs match projects
    test_start "Nginx configs exist for all projects"
    local missing_nginx=()

    if [ ! -f "$PLATFORM_ROOT/platform/nginx/conf.d/filter-ical.conf" ]; then
        missing_nginx+=("filter-ical")
    fi

    if [ ! -f "$PLATFORM_ROOT/platform/nginx/conf.d/paiss.me.conf" ]; then
        missing_nginx+=("paiss")
    fi

    if [ ${#missing_nginx[@]} -eq 0 ]; then
        test_pass
    else
        test_fail "Missing nginx configs: ${missing_nginx[*]}"
    fi
}

# =============================================================================
# Main Test Runner
# =============================================================================

main() {
    echo "======================================================================"
    echo "🧪 PLATFORM CONFIGURATION TESTS"
    echo "======================================================================"
    echo "Testing component: $COMPONENT"
    echo ""

    case "$COMPONENT" in
        nginx)
            test_nginx
            test_docker_compose
            ;;
        monitoring)
            test_monitoring
            test_docker_compose
            ;;
        all)
            test_nginx
            test_docker_compose
            test_monitoring
            test_projects_config
            ;;
        *)
            echo -e "${RED}❌ Unknown component: $COMPONENT${NC}"
            echo "Valid components: nginx, monitoring, all"
            exit 1
            ;;
    esac

    # Summary
    echo ""
    echo "======================================================================"
    echo "TEST SUMMARY"
    echo "======================================================================"
    echo "Tests run:    $TESTS_RUN"
    echo "Tests passed: $TESTS_PASSED"
    echo "Tests failed: $TESTS_FAILED"
    echo ""

    if [ $TESTS_FAILED -eq 0 ]; then
        echo -e "${GREEN}✅ ALL TESTS PASSED${NC}"
        echo "======================================================================"
        return 0
    else
        echo -e "${RED}❌ SOME TESTS FAILED${NC}"
        echo "======================================================================"
        return 1
    fi
}

# Run tests
main

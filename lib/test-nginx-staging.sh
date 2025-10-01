#!/bin/bash
# =============================================================================
# Nginx Staging Test Script
# =============================================================================
# Tests nginx changes on port 8443 before deploying to production port 443
# This creates a staging nginx container that runs alongside production
#
# Usage:
#   ./lib/test-nginx-staging.sh start    # Start staging nginx on port 8443
#   ./lib/test-nginx-staging.sh test     # Test staging nginx
#   ./lib/test-nginx-staging.sh stop     # Stop staging nginx
#   ./lib/test-nginx-staging.sh promote  # Promote staging to production
#
# Workflow:
#   1. Make nginx config changes
#   2. ./lib/test-nginx-staging.sh start
#   3. Test at https://SERVER_IP:8443
#   4. ./lib/test-nginx-staging.sh test
#   5. If good: ./lib/test-nginx-staging.sh promote
#   6. If bad: ./lib/test-nginx-staging.sh stop (and fix issues)
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

# Action
ACTION="${1:-}"

# Staging container name
STAGING_CONTAINER="platform-nginx-staging"

# =============================================================================
# Helper Functions
# =============================================================================

start_staging() {
    echo "======================================================================"
    echo "🚀 STARTING NGINX STAGING CONTAINER"
    echo "======================================================================"
    echo ""

    # Check if staging already running
    if docker ps --format '{{.Names}}' | grep -q "^${STAGING_CONTAINER}$"; then
        echo -e "${YELLOW}⚠️  Staging nginx already running${NC}"
        echo "   To restart: ./lib/test-nginx-staging.sh stop && ./lib/test-nginx-staging.sh start"
        return 1
    fi

    # Create staging docker-compose override
    cat > "$PLATFORM_ROOT/docker-compose.staging.yml" <<EOF
version: '3.8'

networks:
  platform:
    external: true
    name: platform

services:
  nginx-staging:
    image: macbre/nginx-http3:latest
    container_name: ${STAGING_CONTAINER}
    restart: "no"
    ports:
      - "8443:443/tcp"
      - "8443:443/udp"  # HTTP/3 support
    volumes:
      # Use same configs as production
      - ${PLATFORM_ROOT}/platform/nginx/nginx.conf:/etc/nginx/nginx.conf:ro
      - ${PLATFORM_ROOT}/platform/nginx/includes:/etc/nginx/includes:ro
      - ${PLATFORM_ROOT}/platform/nginx/conf.d:/etc/nginx/conf.d:ro

      # Use same SSL certificates
      - certbot-certs:/etc/letsencrypt:ro
      - certbot-www:/var/www/certbot:ro

      # Separate logs
      - nginx-staging-logs:/var/log/nginx
    networks:
      - platform
    healthcheck:
      test: ["CMD", "nginx", "-t"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 10s

volumes:
  certbot-certs:
    external: true
    name: platform-certbot-certs
  certbot-www:
    external: true
    name: platform-certbot-www
  nginx-staging-logs:
    name: platform-nginx-staging-logs
EOF

    echo "📦 Starting staging nginx on port 8443..."
    docker compose -f "$PLATFORM_ROOT/docker-compose.staging.yml" up -d nginx-staging

    # Wait for startup
    echo "⏳ Waiting for nginx to start..."
    sleep 5

    # Check health
    if docker ps --filter "name=${STAGING_CONTAINER}" --filter "status=running" --format "{{.Names}}" | grep -q "^${STAGING_CONTAINER}$"; then
        echo -e "${GREEN}✅ Staging nginx started successfully${NC}"
        echo ""
        echo "Test URLs:"
        echo "  - https://$(hostname -I | awk '{print $1}'):8443"
        echo ""
        echo "Next steps:"
        echo "  1. Test manually: curl -k https://localhost:8443"
        echo "  2. Run tests: ./lib/test-nginx-staging.sh test"
        echo "  3. If good: ./lib/test-nginx-staging.sh promote"
        echo "  4. If bad: ./lib/test-nginx-staging.sh stop"
    else
        echo -e "${RED}❌ Failed to start staging nginx${NC}"
        docker logs "${STAGING_CONTAINER}"
        return 1
    fi
}

test_staging() {
    echo "======================================================================"
    echo "🧪 TESTING STAGING NGINX"
    echo "======================================================================"
    echo ""

    # Check if staging is running
    if ! docker ps --format '{{.Names}}' | grep -q "^${STAGING_CONTAINER}$"; then
        echo -e "${RED}❌ Staging nginx not running${NC}"
        echo "   Start it first: ./lib/test-nginx-staging.sh start"
        return 1
    fi

    # Test nginx config syntax
    echo "Testing nginx config syntax..."
    if docker exec "${STAGING_CONTAINER}" nginx -t 2>&1 | grep -q "syntax is ok"; then
        echo -e "${GREEN}✅ Nginx config valid${NC}"
    else
        echo -e "${RED}❌ Nginx config invalid${NC}"
        docker exec "${STAGING_CONTAINER}" nginx -t
        return 1
    fi

    # Test HTTP/3 configuration
    echo ""
    echo "Testing HTTP/3 configuration..."
    if docker exec "${STAGING_CONTAINER}" nginx -T 2>/dev/null | grep -q "listen 443 quic"; then
        echo -e "${GREEN}✅ HTTP/3 configured${NC}"
    else
        echo -e "${YELLOW}⚠️  HTTP/3 not configured${NC}"
    fi

    # Test container health
    echo ""
    echo "Testing container health..."
    health_status=$(docker inspect --format='{{.State.Health.Status}}' "${STAGING_CONTAINER}" 2>/dev/null || echo "none")

    if [ "$health_status" = "healthy" ] || [ "$health_status" = "none" ]; then
        echo -e "${GREEN}✅ Container healthy${NC}"
    else
        echo -e "${RED}❌ Container unhealthy: $health_status${NC}"
        return 1
    fi

    # Test HTTPS response
    echo ""
    echo "Testing HTTPS response on port 8443..."
    if docker exec "${STAGING_CONTAINER}" curl -k -s -o /dev/null -w "%{http_code}" https://localhost:443 | grep -q "200\|301\|302"; then
        echo -e "${GREEN}✅ HTTPS responding${NC}"
    else
        echo -e "${RED}❌ HTTPS not responding${NC}"
        return 1
    fi

    echo ""
    echo "======================================================================"
    echo -e "${GREEN}✅ ALL STAGING TESTS PASSED${NC}"
    echo "======================================================================"
    echo ""
    echo "Staging nginx is ready for promotion!"
    echo "  Promote: ./lib/test-nginx-staging.sh promote"
}

stop_staging() {
    echo "======================================================================"
    echo "🛑 STOPPING STAGING NGINX"
    echo "======================================================================"
    echo ""

    if docker ps --format '{{.Names}}' | grep -q "^${STAGING_CONTAINER}$"; then
        docker compose -f "$PLATFORM_ROOT/docker-compose.staging.yml" down nginx-staging
        echo -e "${GREEN}✅ Staging nginx stopped${NC}"
    else
        echo -e "${YELLOW}⚠️  Staging nginx not running${NC}"
    fi

    # Cleanup staging compose file
    if [ -f "$PLATFORM_ROOT/docker-compose.staging.yml" ]; then
        rm "$PLATFORM_ROOT/docker-compose.staging.yml"
        echo "   Removed docker-compose.staging.yml"
    fi
}

promote_staging() {
    echo "======================================================================"
    echo "🚀 PROMOTING STAGING TO PRODUCTION"
    echo "======================================================================"
    echo ""

    # Verify staging is running and healthy
    if ! docker ps --format '{{.Names}}' | grep -q "^${STAGING_CONTAINER}$"; then
        echo -e "${RED}❌ Staging nginx not running${NC}"
        return 1
    fi

    # Run tests first
    echo "Running final validation..."
    if ! test_staging; then
        echo -e "${RED}❌ Staging tests failed - aborting promotion${NC}"
        return 1
    fi

    echo ""
    echo -e "${YELLOW}⚠️  This will deploy staging config to production!${NC}"
    echo -n "Continue? [y/N] "
    read -r response

    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        echo "Promotion cancelled"
        return 0
    fi

    echo ""
    echo "Promoting to production..."

    # Stop staging
    stop_staging

    # Deploy to production
    "$SCRIPT_DIR/deploy-platform.sh" nginx

    echo ""
    echo -e "${GREEN}✅ PROMOTION COMPLETE${NC}"
    echo ""
    echo "Verify production:"
    echo "  ./lib/validate-all-projects.sh"
}

# =============================================================================
# Main
# =============================================================================

case "$ACTION" in
    start)
        start_staging
        ;;
    test)
        test_staging
        ;;
    stop)
        stop_staging
        ;;
    promote)
        promote_staging
        ;;
    *)
        echo "Usage: $0 {start|test|stop|promote}"
        echo ""
        echo "Commands:"
        echo "  start    - Start staging nginx on port 8443"
        echo "  test     - Run tests on staging nginx"
        echo "  stop     - Stop staging nginx"
        echo "  promote  - Promote staging to production"
        echo ""
        echo "Example workflow:"
        echo "  1. ./lib/test-nginx-staging.sh start"
        echo "  2. ./lib/test-nginx-staging.sh test"
        echo "  3. ./lib/test-nginx-staging.sh promote"
        exit 1
        ;;
esac

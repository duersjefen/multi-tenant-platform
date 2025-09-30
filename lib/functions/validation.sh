#!/bin/bash
# =============================================================================
# Validation Functions
# =============================================================================
# Pre-flight checks before deployment
# Source this file: source /deploy/lib/functions/validation.sh
# =============================================================================

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# =============================================================================
# validate_environment
# Validates that required environment variables are set
# =============================================================================
validate_environment() {
    local required_vars=("$@")
    local missing_vars=()

    for var in "${required_vars[@]}"; do
        if [ -z "${!var:-}" ]; then
            missing_vars+=("$var")
        fi
    done

    if [ ${#missing_vars[@]} -gt 0 ]; then
        echo -e "${RED}❌ Missing required environment variables:${NC}"
        printf '%s\n' "${missing_vars[@]}"
        return 1
    fi

    echo -e "${GREEN}✅ All required environment variables are set${NC}"
    return 0
}

# =============================================================================
# validate_docker_images
# Validates that required Docker images exist
# =============================================================================
validate_docker_images() {
    local images=("$@")
    local missing_images=()

    echo "🔍 Validating Docker images..."

    for image in "${images[@]}"; do
        if ! docker image inspect "$image" &> /dev/null; then
            missing_images+=("$image")
        fi
    done

    if [ ${#missing_images[@]} -gt 0 ]; then
        echo -e "${RED}❌ Missing Docker images:${NC}"
        printf '%s\n' "${missing_images[@]}"
        return 1
    fi

    echo -e "${GREEN}✅ All Docker images exist${NC}"
    return 0
}

# =============================================================================
# validate_health_endpoint
# Validates that a health endpoint returns expected status
# =============================================================================
validate_health_endpoint() {
    local url="$1"
    local expected_status="${2:-200}"
    local timeout="${3:-10}"
    local max_retries="${4:-3}"

    echo "🔍 Validating health endpoint: $url"

    for i in $(seq 1 $max_retries); do
        local status_code
        status_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time "$timeout" "$url" 2>/dev/null || echo "000")

        if [ "$status_code" = "$expected_status" ]; then
            echo -e "${GREEN}✅ Health check passed: $url (HTTP $status_code)${NC}"
            return 0
        fi

        if [ $i -lt $max_retries ]; then
            echo -e "${YELLOW}⏳ Health check attempt $i/$max_retries failed (HTTP $status_code). Retrying...${NC}"
            sleep 5
        fi
    done

    echo -e "${RED}❌ Health check failed: $url (HTTP $status_code after $max_retries attempts)${NC}"
    return 1
}

# =============================================================================
# validate_container_health
# Validates that a Docker container is healthy
# =============================================================================
validate_container_health() {
    local container_name="$1"
    local timeout="${2:-60}"
    local interval="${3:-5}"

    echo "🔍 Validating container health: $container_name"

    local elapsed=0
    while [ $elapsed -lt $timeout ]; do
        if ! docker ps --filter "name=$container_name" --format "{{.Names}}" | grep -q "^${container_name}$"; then
            echo -e "${RED}❌ Container not running: $container_name${NC}"
            return 1
        fi

        local health_status
        health_status=$(docker inspect --format='{{.State.Health.Status}}' "$container_name" 2>/dev/null || echo "none")

        case "$health_status" in
            "healthy")
                echo -e "${GREEN}✅ Container healthy: $container_name${NC}"
                return 0
                ;;
            "none")
                # Container has no health check - just verify it's running
                if docker ps --filter "name=$container_name" --filter "status=running" --format "{{.Names}}" | grep -q "^${container_name}$"; then
                    echo -e "${GREEN}✅ Container running: $container_name (no health check)${NC}"
                    return 0
                fi
                ;;
            "starting")
                echo -e "${YELLOW}⏳ Container starting: $container_name (${elapsed}s/${timeout}s)${NC}"
                ;;
            "unhealthy")
                echo -e "${RED}❌ Container unhealthy: $container_name${NC}"
                return 1
                ;;
        esac

        sleep $interval
        elapsed=$((elapsed + interval))
    done

    echo -e "${RED}❌ Container health check timeout: $container_name (${timeout}s)${NC}"
    return 1
}

# =============================================================================
# validate_nginx_config
# Validates nginx configuration syntax
# =============================================================================
validate_nginx_config() {
    echo "🔍 Validating nginx configuration..."

    if docker exec platform-nginx nginx -t 2>&1 | grep -q "syntax is ok"; then
        echo -e "${GREEN}✅ Nginx configuration is valid${NC}"
        return 0
    else
        echo -e "${RED}❌ Nginx configuration is invalid${NC}"
        docker exec platform-nginx nginx -t
        return 1
    fi
}

# =============================================================================
# validate_disk_space
# Validates that sufficient disk space is available
# =============================================================================
validate_disk_space() {
    local required_gb="${1:-5}"  # Default: 5GB required

    echo "🔍 Validating disk space..."

    local available_gb
    available_gb=$(df -BG / | tail -1 | awk '{print $4}' | sed 's/G//')

    if [ "$available_gb" -lt "$required_gb" ]; then
        echo -e "${RED}❌ Insufficient disk space: ${available_gb}GB available, ${required_gb}GB required${NC}"
        return 1
    fi

    echo -e "${GREEN}✅ Sufficient disk space: ${available_gb}GB available${NC}"
    return 0
}

# =============================================================================
# validate_ports_available
# Validates that required ports are available
# =============================================================================
validate_ports_available() {
    local ports=("$@")
    local occupied_ports=()

    echo "🔍 Validating port availability..."

    for port in "${ports[@]}"; do
        if netstat -tuln 2>/dev/null | grep -q ":$port "; then
            occupied_ports+=("$port")
        fi
    done

    if [ ${#occupied_ports[@]} -gt 0 ]; then
        echo -e "${RED}❌ Ports already in use:${NC}"
        printf '%s\n' "${occupied_ports[@]}"
        return 1
    fi

    echo -e "${GREEN}✅ All ports available${NC}"
    return 0
}

# =============================================================================
# validate_all
# Runs all validation checks
# =============================================================================
validate_all() {
    local project_name="$1"
    local environment="$2"

    echo "======================================================================"
    echo "🔍 PRE-FLIGHT VALIDATION: $project_name ($environment)"
    echo "======================================================================"

    local validation_failed=false

    # Add all your validation checks here
    validate_disk_space 5 || validation_failed=true
    # Add more checks as needed

    if [ "$validation_failed" = true ]; then
        echo -e "\n${RED}❌ VALIDATION FAILED - Deployment aborted${NC}"
        return 1
    fi

    echo -e "\n${GREEN}✅ ALL VALIDATIONS PASSED - Proceeding with deployment${NC}"
    return 0
}
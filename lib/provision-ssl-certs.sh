#!/bin/bash
# =============================================================================
# Auto-Provision SSL Certificates from projects.yml
# =============================================================================
# This script automatically provisions SSL certificates for all domains
# defined in projects.yml that don't already have certificates.
#
# Features:
# - Idempotent: Safe to run multiple times
# - Smart: Only requests certs that don't exist
# - Automatic: Reads domain list from projects.yml
# - Integrated: Can be called from deployment scripts
#
# Usage:
#   ./lib/provision-ssl-certs.sh [--dry-run] [--force]
#
# Options:
#   --dry-run    Show what would be done without making changes
#   --force      Request certificates even if they already exist (renewal)
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

# Settings
DRY_RUN=false
FORCE=false
SSL_EMAIL="info@paiss.me"

# Parse arguments
for arg in "$@"; do
    case $arg in
        --dry-run) DRY_RUN=true ;;
        --force) FORCE=true ;;
    esac
done

# Functions
log_info() {
    echo -e "${BLUE}ℹ${NC}  $1"
}

log_success() {
    echo -e "${GREEN}✅${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}⚠️${NC}  $1"
}

log_error() {
    echo -e "${RED}❌${NC} $1"
}

separator() {
    echo ""
    echo "========================================================================"
    echo "$1"
    echo "========================================================================"
}

# Check if we're on production server
if [ ! -d "/opt/multi-tenant-platform" ]; then
    log_error "This script must run on the production server"
    log_info "Run this via: make provision-ssl"
    exit 1
fi

cd "$PLATFORM_ROOT"

separator "🔐 SSL CERTIFICATE AUTO-PROVISIONING"

if [ "$DRY_RUN" = true ]; then
    log_warning "DRY RUN MODE - No actual changes will be made"
fi

echo "Reading projects.yml..."
echo ""

# Extract all domains from projects.yml using Python
DOMAINS=$(python3 <<'PYTHON'
import yaml
import sys

try:
    with open('config/projects.yml', 'r') as f:
        config = yaml.safe_load(f)

    projects = config.get('projects', {})
    all_domains = []

    for project_name, project in projects.items():
        domains_config = project.get('domains', {})

        # Production domains
        if 'production' in domains_config:
            prod_domains = domains_config['production']
            if isinstance(prod_domains, list):
                all_domains.extend(prod_domains)
            else:
                all_domains.append(prod_domains)

        # Staging domains
        if 'staging' in domains_config:
            staging_domains = domains_config['staging'].get('domains', [])
            if isinstance(staging_domains, list):
                all_domains.extend(staging_domains)
            else:
                all_domains.append(staging_domains)

    # Print unique domains, one per line
    for domain in sorted(set(all_domains)):
        print(domain)

except Exception as e:
    print(f"Error: {e}", file=sys.stderr)
    sys.exit(1)
PYTHON
)

if [ -z "$DOMAINS" ]; then
    log_error "No domains found in projects.yml"
    exit 1
fi

log_info "Found domains in projects.yml:"
echo "$DOMAINS" | while read domain; do
    echo "  - $domain"
done
echo ""

# Check which certificates already exist
log_info "Checking existing SSL certificates..."
MISSING_DOMAINS=()
EXISTING_DOMAINS=()

while IFS= read -r domain; do
    CERT_PATH="/etc/letsencrypt/live/$domain/fullchain.pem"

    if [ -f "$CERT_PATH" ]; then
        EXISTING_DOMAINS+=("$domain")
        echo "  ✓ $domain (already exists)"
    else
        MISSING_DOMAINS+=("$domain")
        echo "  ✗ $domain (missing)"
    fi
done <<< "$DOMAINS"

echo ""

# Report status
if [ ${#EXISTING_DOMAINS[@]} -gt 0 ]; then
    log_success "${#EXISTING_DOMAINS[@]} certificate(s) already exist"
fi

if [ ${#MISSING_DOMAINS[@]} -eq 0 ] && [ "$FORCE" = false ]; then
    log_success "All SSL certificates are already provisioned!"
    log_info "Use --force to renew existing certificates"
    exit 0
fi

# Provision missing certificates
if [ "$FORCE" = true ]; then
    log_warning "Force mode enabled - will request all certificates"
    DOMAINS_TO_PROVISION=($(echo "$DOMAINS"))
else
    DOMAINS_TO_PROVISION=("${MISSING_DOMAINS[@]}")
fi

separator "📜 PROVISIONING ${#DOMAINS_TO_PROVISION[@]} SSL CERTIFICATE(S)"

for domain in "${DOMAINS_TO_PROVISION[@]}"; do
    echo ""
    log_info "Provisioning SSL certificate for: $domain"

    if [ "$DRY_RUN" = true ]; then
        log_warning "DRY RUN: Would run certbot for $domain"
        continue
    fi

    # Run certbot for this domain
    if docker compose -f platform/docker-compose.platform.yml run --rm certbot \
        certonly --webroot -w /var/www/certbot \
        -d "$domain" \
        --email "$SSL_EMAIL" \
        --agree-tos \
        --no-eff-email \
        --non-interactive; then
        log_success "Certificate provisioned: $domain"
    else
        log_error "Failed to provision certificate for: $domain"
        log_warning "This may be due to:"
        log_warning "  - DNS not pointing to this server yet"
        log_warning "  - Port 80 not accessible"
        log_warning "  - Rate limiting from Let's Encrypt"
        echo ""

        # Continue with other domains instead of failing completely
        continue
    fi
done

separator "✅ SSL PROVISIONING COMPLETE"

if [ "$DRY_RUN" = false ]; then
    echo ""
    log_success "SSL certificates have been provisioned"
    log_info "Certificates will auto-renew via certbot cron job"
    echo ""
    log_info "Next step: Deploy nginx to use the new certificates"
    log_info "  Run: ./lib/deploy-platform-safe.sh nginx"
else
    echo ""
    log_info "Dry run complete. Run without --dry-run to provision certificates."
fi

echo ""

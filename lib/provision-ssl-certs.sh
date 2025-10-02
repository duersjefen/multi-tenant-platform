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

# Detect if we're on production server or local
if [ -d "/opt/multi-tenant-platform" ]; then
    ON_SERVER=true
    CERT_BASE_PATH="/etc/letsencrypt/live"
else
    ON_SERVER=false
    CERT_BASE_PATH="$PLATFORM_ROOT/platform/certbot/conf/live"
    log_warning "Running locally - will create placeholder certificates"
fi

cd "$PLATFORM_ROOT"

separator "🔐 SSL CERTIFICATE AUTO-PROVISIONING"

if [ "$DRY_RUN" = true ]; then
    log_warning "DRY RUN MODE - No actual changes will be made"
fi

echo "Reading projects.yml..."
echo ""

# Extract domain groups from projects.yml using Python
# Groups production domains together for multi-domain certificates
DOMAIN_GROUPS=$(python3 <<'PYTHON'
import yaml
import sys

try:
    with open('config/projects.yml', 'r') as f:
        config = yaml.safe_load(f)

    projects = config.get('projects', {})
    domain_groups = []

    for project_name, project in projects.items():
        domains_config = project.get('domains', {})

        # Production domains - group together for one certificate
        if 'production' in domains_config:
            prod_domains = domains_config['production']
            if isinstance(prod_domains, list):
                # Multiple production domains → one multi-domain certificate
                domain_groups.append(','.join(sorted(prod_domains)))
            else:
                # Single production domain
                domain_groups.append(prod_domains)

        # Staging domains - separate certificate for each
        if 'staging' in domains_config:
            staging_domains = domains_config['staging'].get('domains', [])
            if isinstance(staging_domains, list):
                domain_groups.extend(staging_domains)
            else:
                domain_groups.append(staging_domains)

    # Print unique domain groups, one per line
    for group in sorted(set(domain_groups)):
        print(group)

except Exception as e:
    print(f"Error: {e}", file=sys.stderr)
    sys.exit(1)
PYTHON
)

if [ -z "$DOMAIN_GROUPS" ]; then
    log_error "No domain groups found in projects.yml"
    exit 1
fi

log_info "Found domain groups in projects.yml:"
echo "$DOMAIN_GROUPS" | while read domain_group; do
    echo "  - $domain_group"
done
echo ""

# Check which certificates already exist
log_info "Checking existing SSL certificates..."
MISSING_GROUPS=()
EXISTING_GROUPS=()

while IFS= read -r domain_group; do
    # Extract first domain from group (certificate is stored under first domain)
    PRIMARY_DOMAIN="${domain_group%%,*}"
    CERT_PATH="$CERT_BASE_PATH/$PRIMARY_DOMAIN/fullchain.pem"

    # Check certificate existence via Docker if on server
    if [ "$ON_SERVER" = true ]; then
        if docker exec platform-certbot test -f "$CERT_PATH" 2>/dev/null; then
            # Check if it's a placeholder
            if docker exec platform-certbot test -f "$CERT_BASE_PATH/$PRIMARY_DOMAIN/.placeholder" 2>/dev/null; then
                echo "  ⚠ $domain_group (placeholder certificate)"
                MISSING_GROUPS+=("$domain_group")
            else
                EXISTING_GROUPS+=("$domain_group")
                echo "  ✓ $domain_group (real certificate)"
            fi
        else
            MISSING_GROUPS+=("$domain_group")
            echo "  ✗ $domain_group (missing)"
        fi
    else
        # Local check (direct filesystem access)
        if [ -f "$CERT_PATH" ]; then
            # Check if it's a placeholder
            if [ -f "$CERT_BASE_PATH/$PRIMARY_DOMAIN/.placeholder" ]; then
                echo "  ⚠ $domain_group (placeholder certificate)"
                MISSING_GROUPS+=("$domain_group")
            else
                EXISTING_GROUPS+=("$domain_group")
                echo "  ✓ $domain_group (real certificate)"
            fi
        else
            MISSING_GROUPS+=("$domain_group")
            echo "  ✗ $domain_group (missing)"
        fi
    fi
done <<< "$DOMAIN_GROUPS"

echo ""

# Report status
if [ ${#EXISTING_GROUPS[@]} -gt 0 ]; then
    log_success "${#EXISTING_GROUPS[@]} certificate(s) already exist"
fi

if [ ${#MISSING_GROUPS[@]} -eq 0 ] && [ "$FORCE" = false ]; then
    log_success "All SSL certificates are already provisioned!"
    log_info "Use --force to renew existing certificates"
    exit 0
fi

# Provision missing certificates
if [ "$FORCE" = true ]; then
    log_warning "Force mode enabled - will request all certificates"
    mapfile -t GROUPS_TO_PROVISION <<< "$DOMAIN_GROUPS"
else
    GROUPS_TO_PROVISION=("${MISSING_GROUPS[@]}")
fi

separator "📜 PROVISIONING ${#GROUPS_TO_PROVISION[@]} SSL CERTIFICATE(S)"

for domain_group in "${GROUPS_TO_PROVISION[@]}"; do
    echo ""
    log_info "Provisioning SSL certificate for: $domain_group"

    # Split domain group into array
    IFS=',' read -ra DOMAINS <<< "$domain_group"
    PRIMARY_DOMAIN="${DOMAINS[0]}"

    if [ "$DRY_RUN" = true ]; then
        log_warning "DRY RUN: Would run certbot for $domain_group"
        continue
    fi

    # Try to get real Let's Encrypt certificate
    CERTBOT_SUCCESS=false
    if [ "$ON_SERVER" = true ]; then
        # Build certbot command with multiple -d flags
        CERTBOT_DOMAINS=""
        for domain in "${DOMAINS[@]}"; do
            CERTBOT_DOMAINS="$CERTBOT_DOMAINS -d $domain"
        done

        if docker compose -f platform/docker-compose.platform.yml run --rm \
            --entrypoint certbot certbot \
            certonly --webroot -w /var/www/certbot \
            $CERTBOT_DOMAINS \
            --email "$SSL_EMAIL" \
            --agree-tos \
            --no-eff-email \
            --non-interactive 2>/dev/null; then
            CERTBOT_SUCCESS=true
            log_success "Real Let's Encrypt certificate obtained: $domain_group"

            # Remove placeholder marker if it exists
            rm -f "$CERT_BASE_PATH/$PRIMARY_DOMAIN/.placeholder"
        fi
    fi

    # If certbot failed or we're running locally, create placeholder certificate
    if [ "$CERTBOT_SUCCESS" = false ]; then
        log_warning "Let's Encrypt failed for $domain_group - creating placeholder certificate"
        log_info "Reasons for failure:"
        log_info "  - DNS not pointing to this server yet"
        log_info "  - Port 80 not accessible"
        log_info "  - Rate limiting from Let's Encrypt"
        log_info "  - Running locally (not on production server)"
        echo ""

        # Create directory for primary domain
        CERT_DIR="$CERT_BASE_PATH/$PRIMARY_DOMAIN"
        mkdir -p "$CERT_DIR"

        # Generate self-signed certificate with all domains as SANs
        log_info "Generating self-signed placeholder..."

        # Build subjectAltName list
        SAN_LIST=""
        for i in "${!DOMAINS[@]}"; do
            if [ $i -eq 0 ]; then
                SAN_LIST="DNS:${DOMAINS[$i]}"
            else
                SAN_LIST="$SAN_LIST,DNS:${DOMAINS[$i]}"
            fi
        done

        # Create OpenSSL config for multi-domain cert
        cat > /tmp/openssl-san.cnf <<EOF
[req]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn
req_extensions = v3_req

[dn]
CN = $PRIMARY_DOMAIN

[v3_req]
subjectAltName = $SAN_LIST
EOF

        openssl req -x509 -nodes -newkey rsa:2048 \
            -days 90 \
            -keyout "$CERT_DIR/privkey.pem" \
            -out "$CERT_DIR/fullchain.pem" \
            -config /tmp/openssl-san.cnf \
            -extensions v3_req \
            2>/dev/null

        rm /tmp/openssl-san.cnf

        # Create chain.pem (required by nginx)
        cp "$CERT_DIR/fullchain.pem" "$CERT_DIR/chain.pem"

        # Mark as placeholder
        touch "$CERT_DIR/.placeholder"

        log_success "Placeholder certificate created: $domain_group"
        log_warning "→ Nginx will start, but browsers will show security warning"
        log_info "→ Replace with real cert later: ./lib/provision-ssl-certs.sh"
        echo ""
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

#!/bin/bash
# =============================================================================
# SSL Certificate Renewal Script
# =============================================================================
# Automatically renews SSL certificates and reloads nginx
# Should be run via cron: 0 0,12 * * * /deploy/platform/scripts/certbot-renew.sh
# =============================================================================

set -euo pipefail

echo "🔄 Checking for SSL certificates that need renewal..."

# Renew certificates (dry-run in staging, real in production)
certbot renew --webroot --webroot-path=/var/www/certbot --quiet

# Reload nginx if any certificates were renewed
if [ $? -eq 0 ]; then
    echo "✅ Certificate renewal check complete"

    # Reload nginx to pick up new certificates
    docker exec platform-nginx nginx -s reload
    echo "🔄 Nginx reloaded with new certificates"
else
    echo "⚠️ Certificate renewal failed"
    exit 1
fi
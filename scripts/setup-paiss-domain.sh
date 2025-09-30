#!/bin/bash
# =============================================================================
# Setup Script: Configure paiss.me and monitoring.paiss.me
# =============================================================================
# This script:
# 1. Requests SSL certificates for paiss.me and monitoring.paiss.me
# 2. Deploys the PAISS website
# 3. Configures Grafana with monitoring.paiss.me
# 4. Reloads nginx
# =============================================================================

set -e  # Exit on error

PLATFORM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PLATFORM_DIR"

echo "=================================================="
echo "🚀 Setting up PAISS domains"
echo "=================================================="
echo ""

# Step 1: Verify DNS
echo "📡 Step 1: Verifying DNS configuration..."
PAISS_IP=$(dig +short paiss.me @8.8.8.8 | tail -n1)
MONITORING_IP=$(dig +short monitoring.paiss.me @8.8.8.8 | tail -n1)

echo "   paiss.me → $PAISS_IP"
echo "   monitoring.paiss.me → $MONITORING_IP"

if [ -z "$PAISS_IP" ] || [ -z "$MONITORING_IP" ]; then
    echo "❌ ERROR: DNS not configured properly!"
    echo "   Please set up DNS A records first."
    exit 1
fi

echo "✅ DNS looks good!"
echo ""

# Step 2: Test nginx config
echo "🔧 Step 2: Testing nginx configuration..."
if ! docker exec platform-nginx nginx -t; then
    echo "❌ ERROR: Nginx config test failed!"
    exit 1
fi
echo "✅ Nginx config is valid"
echo ""

# Step 3: Reload nginx to pick up new configs
echo "🔄 Step 3: Reloading nginx..."
docker exec platform-nginx nginx -s reload
echo "✅ Nginx reloaded"
echo ""

# Step 4: Request SSL certificate for paiss.me
echo "🔐 Step 4: Requesting SSL certificate for paiss.me..."
if [ -d "/var/lib/docker/volumes/platform-certbot-certs/_data/live/paiss.me" ]; then
    echo "⚠️  Certificate already exists for paiss.me, skipping..."
else
    docker-compose -f platform/docker-compose.platform.yml run --rm certbot \
      certonly --webroot --webroot-path=/var/www/certbot \
      --email info@paiss.me \
      --agree-tos --no-eff-email \
      -d paiss.me -d www.paiss.me
    echo "✅ SSL certificate obtained for paiss.me"
fi
echo ""

# Step 5: Request SSL certificate for monitoring.paiss.me
echo "🔐 Step 5: Requesting SSL certificate for monitoring.paiss.me..."
if [ -d "/var/lib/docker/volumes/platform-certbot-certs/_data/live/monitoring.paiss.me" ]; then
    echo "⚠️  Certificate already exists for monitoring.paiss.me, skipping..."
else
    docker-compose -f platform/docker-compose.platform.yml run --rm certbot \
      certonly --webroot --webroot-path=/var/www/certbot \
      --email info@paiss.me \
      --agree-tos --no-eff-email \
      -d monitoring.paiss.me
    echo "✅ SSL certificate obtained for monitoring.paiss.me"
fi
echo ""

# Step 6: Restart Grafana with new domain
echo "📊 Step 6: Restarting Grafana..."
docker-compose -f platform/docker-compose.platform.yml restart grafana
echo "✅ Grafana restarted"
echo ""

# Step 7: Reload nginx to use SSL certificates
echo "🔄 Step 7: Reloading nginx with SSL certificates..."
docker exec platform-nginx nginx -s reload
echo "✅ Nginx reloaded with SSL"
echo ""

# Step 8: Wait for GitHub Actions to build image
echo "⏳ Step 8: Checking if PAISS Docker image is available..."
if docker pull ghcr.io/duersjefen/paiss:latest 2>/dev/null; then
    echo "✅ Docker image available"
    echo ""

    # Step 9: Deploy PAISS
    echo "🚀 Step 9: Deploying PAISS website..."
    ./lib/deploy.sh paiss production
    echo "✅ PAISS deployed"
else
    echo "⚠️  Docker image not yet available"
    echo "   GitHub Actions is probably still building it."
    echo "   Check: https://github.com/duersjefen/paiss/actions"
    echo ""
    echo "   Once the build completes, run:"
    echo "   ./lib/deploy.sh paiss production"
fi
echo ""

# Final summary
echo "=================================================="
echo "✅ Setup Complete!"
echo "=================================================="
echo ""
echo "🌐 Your sites should now be accessible:"
echo "   • https://paiss.me"
echo "   • https://www.paiss.me"
echo "   • https://monitoring.paiss.me"
echo ""
echo "📊 Grafana credentials:"
echo "   Username: admin"
echo "   Password: Check GRAFANA_ADMIN_PASSWORD in .env"
echo ""
echo "🔍 Check status:"
echo "   docker ps | grep paiss"
echo "   curl -I https://paiss.me"
echo "   curl -I https://monitoring.paiss.me"
echo ""

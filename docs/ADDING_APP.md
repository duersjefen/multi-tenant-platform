# Adding a New App to the Platform

Guide for adding a new application to the multi-tenant platform.

## Overview

Adding a new app involves:
1. Creating nginx configuration
2. Adding database (if needed)
3. Adding SSM deployment to app repo
4. Generating SSL certificates
5. Updating DNS

---

## Step 1: Create Nginx Configuration

Create a new file in `platform/nginx/sites/your-app.conf`:

```nginx
# =============================================================================
# Your App - Description
# =============================================================================
# Production: your-app.com
# Staging: staging.your-app.com
# =============================================================================

# HTTP → HTTPS REDIRECT (Production)
server {
    listen 80;
    server_name your-app.com www.your-app.com;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 301 https://$host$request_uri;
    }
}

# PRODUCTION
server {
    listen 443 ssl;
    listen 443 quic;
    http2 on;
    server_name your-app.com www.your-app.com;

    ssl_certificate /etc/letsencrypt/live/your-app.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/your-app.com/privkey.pem;

    include /etc/nginx/includes/security-headers.conf;

    access_log /var/log/nginx/your-app-production.access.log detailed;
    error_log /var/log/nginx/your-app-production.error.log warn;

    # For single container app
    location / {
        limit_req zone=general burst=50 nodelay;
        proxy_pass http://your-app-web:PORT;
        include /etc/nginx/includes/proxy-headers.conf;
    }

    # For separate backend/frontend
    # Backend routes
    location /api {
        limit_req zone=api burst=20 nodelay;
        proxy_pass http://your-app-backend:PORT;
        include /etc/nginx/includes/proxy-headers.conf;
    }

    # Frontend routes
    location / {
        limit_req zone=general burst=50 nodelay;
        proxy_pass http://your-app-frontend:PORT;
        include /etc/nginx/includes/proxy-headers.conf;
    }
}

# STAGING (repeat above for staging.your-app.com)
server {
    listen 80;
    server_name staging.your-app.com;
    # ... same pattern for staging
}

server {
    listen 443 ssl;
    listen 443 quic;
    http2 on;
    server_name staging.your-app.com;
    # ... proxy to your-app-web-staging or your-app-frontend-staging
}
```

**Commit and push** to GitHub:
```bash
git add platform/nginx/sites/your-app.conf
git commit -m "Add nginx config for your-app"
git push
```

---

## Step 2: Add Database (If Needed)

If your app needs a database:

### Update `database/init.sql`

```sql
-- Add these lines
CREATE DATABASE your_app_production;
CREATE DATABASE your_app_staging;

GRANT ALL PRIVILEGES ON DATABASE your_app_production TO platform_admin;
GRANT ALL PRIVILEGES ON DATABASE your_app_staging TO platform_admin;
```

### Apply to existing server

```bash
# Connect via SSM
aws ssm start-session --target i-YOUR-INSTANCE-ID --region eu-north-1

# Create databases manually
docker exec -it postgres-platform psql -U platform_admin -d postgres

# In psql:
CREATE DATABASE your_app_production;
CREATE DATABASE your_app_staging;
GRANT ALL PRIVILEGES ON DATABASE your_app_production TO platform_admin;
GRANT ALL PRIVILEGES ON DATABASE your_app_staging TO platform_admin;
\q
```

### Update backup script

Edit `database/backup.sh`:

```bash
DATABASES=(
    "filter_ical_production"
    "filter_ical_staging"
    "gabs_massage_production"
    "gabs_massage_staging"
    "your_app_production"        # Add
    "your_app_staging"            # Add
)
```

---

## Step 3: Create App Deployment Script

In your app repository, create `deploy.sh`:

```bash
#!/bin/bash
# =============================================================================
# Your App - SSM Deployment Script
# =============================================================================

set -e

ENVIRONMENT="${1:-staging}"
REGION="eu-north-1"
INSTANCE_ID="i-YOUR-INSTANCE-ID"  # Get from .env or AWS

if [ "$ENVIRONMENT" != "staging" ] && [ "$ENVIRONMENT" != "production" ]; then
    echo "❌ Invalid environment. Use: staging or production"
    exit 1
fi

echo "🚀 Deploying Your App to $ENVIRONMENT"
echo "========================================"

# Deploy via SSM - builds on server
aws ssm send-command \
    --region "$REGION" \
    --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --comment "Deploy your-app $ENVIRONMENT" \
    --parameters "commands=[
        'set -e',
        'echo \"📥 Deploying your-app ($ENVIRONMENT)...\"',
        'cd /opt/apps/your-app || exit 1',
        'if [ ! -d .git ]; then',
        '  cd /opt/apps',
        '  git clone https://github.com/YOUR_USERNAME/your-app.git',
        '  cd your-app',
        'fi',
        'echo \"📥 Pulling latest code...\"',
        'git pull origin main',
        'echo \"🔨 Building Docker image...\"',
        'CONTAINER_NAME=$CONTAINER_NAME ENVIRONMENT=$ENVIRONMENT docker-compose build',
        'echo \"🚀 Starting container...\"',
        'CONTAINER_NAME=$CONTAINER_NAME ENVIRONMENT=$ENVIRONMENT docker-compose up -d',
        'echo \"⏳ Waiting for container...\"',
        'sleep 5',
        'docker ps | grep your-app',
        'echo \"✅ Deployment complete!\"'
    ]" \
    --output text

echo "✅ Deployment command sent!"
```

### Create `docker-compose.yml` in app repo

```yaml
version: '3.8'

networks:
  platform:
    external: true
    name: platform

services:
  your-app-web:
    build:
      context: .
      dockerfile: Dockerfile
    container_name: ${CONTAINER_NAME:-your-app-web}
    restart: unless-stopped
    networks:
      - platform
    environment:
      DATABASE_URL: postgresql://platform_admin:PASSWORD@postgres-platform:5432/your_app_${ENVIRONMENT}
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:PORT/health"]
      interval: 30s
      timeout: 5s
      retries: 3
```

**Note**: Uses `build` instead of `image` - builds from Dockerfile on server

### Update Makefile

```makefile
deploy-staging:
    @./deploy.sh staging

deploy-prod:
    @./deploy.sh production
```

---

## Step 4: Deploy Platform Update

Deploy updated nginx configuration:

```bash
# From local machine
cd ~/Documents/Projects/multi-tenant-platform
./scripts/deploy-platform.sh i-YOUR-INSTANCE-ID
```

This will:
- Pull latest code (with new nginx config)
- Restart nginx to load new config

---

## Step 5: Generate SSL Certificates

```bash
# Connect via SSM
aws ssm start-session --target i-YOUR-INSTANCE-ID --region eu-north-1

# Generate certificates
docker run --rm -v certbot-etc:/etc/letsencrypt -v certbot-var:/var/www/certbot \
    certbot/certbot certonly --webroot --webroot-path=/var/www/certbot \
    --email your@email.com --agree-tos --no-eff-email \
    -d your-app.com -d www.your-app.com

docker run --rm -v certbot-etc:/etc/letsencrypt -v certbot-var:/var/www/certbot \
    certbot/certbot certonly --webroot --webroot-path=/var/www/certbot \
    --email your@email.com --agree-tos --no-eff-email \
    -d staging.your-app.com

# Reload nginx
cd /opt/platform/platform
docker-compose restart nginx
```

---

## Step 6: Deploy App

From your app repository:

```bash
cd ~/Documents/Projects/your-app
make deploy-staging
```

---

## Step 7: Update DNS

Add DNS A records pointing to EC2 public IP:
- `your-app.com` → EC2 IP
- `www.your-app.com` → EC2 IP
- `staging.your-app.com` → EC2 IP

Wait for DNS propagation (5-30 minutes).

---

## Step 8: Test

```bash
# Test production
curl https://your-app.com

# Test staging
curl https://staging.your-app.com

# Check SSL
curl -vI https://your-app.com 2>&1 | grep "SSL certificate verify"
```

---

## Checklist

- [ ] Created nginx config in `platform/nginx/sites/your-app.conf`
- [ ] Added database to `database/init.sql` (if needed)
- [ ] Updated `database/backup.sh` (if database added)
- [ ] Created `deploy.sh` in app repo
- [ ] Created `docker-compose.yml` in app repo
- [ ] Updated app `Makefile`
- [ ] Deployed platform update (nginx config)
- [ ] Generated SSL certificates
- [ ] Deployed app
- [ ] Updated DNS records
- [ ] Tested production and staging URLs
- [ ] Verified SSL certificates

---

## Common Issues

### Nginx Won't Reload

Check config syntax:
```bash
docker exec nginx-platform nginx -t
```

### SSL Certificate Failed

- Ensure DNS is pointing to EC2 IP
- Check port 80 is accessible
- Verify nginx is running

### App Container Can't Reach Postgres

- Ensure container is on `platform` network
- Check database exists: `docker exec -it postgres-platform psql -U platform_admin -l`

---

**Done!** Your app is now part of the multi-tenant platform.

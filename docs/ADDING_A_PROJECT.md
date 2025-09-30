# Adding a New Project to the Platform

> Step-by-step guide to add a new application to the multi-tenant platform

## 🎯 Overview

Adding a new project takes **~15 minutes** and involves:

1. Register project in `projects.yml`
2. Create Docker Compose configuration
3. Create nginx configuration
4. Deploy!

Let's walk through adding a hypothetical "TaskManager" application.

## 📋 Prerequisites

- Application has **Docker images** published (e.g., GitHub Container Registry)
- Application has **health check endpoint** (e.g., `/health`)
- **Domain name** configured (DNS pointing to server)

## 🚀 Step-by-Step Guide

### Step 1: Register in projects.yml

Edit `/deploy/config/projects.yml` and add your project:

```bash
vim /deploy/config/projects.yml
```

Add this section (copy from filter-ical template):

```yaml
projects:
  # ... existing projects ...

  # =============================================================================
  # PROJECT: task-manager
  # =============================================================================
  task-manager:
    # Basic information
    name: "Task Manager Application"
    repository: "https://github.com/myuser/task-manager"

    # Domains
    domains:
      production:
        - tasks.mycompany.com
        - www.tasks.mycompany.com
      staging:
        subdomain: staging
        domains:
          - staging.tasks.mycompany.com

    # Container configuration
    containers:
      backend:
        name: task-manager-backend
        port: 8080
        health_check:
          path: /api/health
          expected_status: 200
          timeout: 30
          retries: 10
          start_period: 60

      frontend:
        name: task-manager-frontend
        port: 3000
        health_check:
          path: /
          expected_status: 200
          timeout: 30
          retries: 10
          start_period: 30

    # Environments
    environments:
      production:
        containers:
          - task-manager-backend
          - task-manager-frontend
        deployment_strategy: blue-green  # or 'direct' for simpler apps
        auto_rollback: true
        health_check_timeout: 120

      staging:
        containers:
          - task-manager-backend-staging
          - task-manager-frontend-staging
        deployment_strategy: direct
        auto_rollback: true
        health_check_timeout: 60

    # Nginx configuration
    nginx:
      # API routes (backend)
      api_locations:
        - /api
        - /graphql
        - /auth

      # Rate limiting
      rate_limit:
        zone: api
        rate: 20r/s  # Adjust based on your needs
        burst: 50

      # Timeouts
      proxy_timeout: 60s
      proxy_connect_timeout: 60s

    # Monitoring & Alerts
    monitoring:
      enabled: true
      alerts:
        - name: production_down
          condition: "up == 0"
          duration: 1m
          severity: critical

        - name: high_error_rate
          condition: "rate(http_5xx[5m]) > 0.05"
          duration: 2m
          severity: warning

        - name: slow_responses
          condition: "p95_latency > 2s"
          duration: 5m
          severity: warning

    # Backup configuration
    backup:
      enabled: true
      pre_deployment: true
      retention: 5  # Keep last 5 backups
```

**Key Configuration Points**:

- **`start_period`**: CRITICAL! Set this to how long your app takes to start (usually 60s for backends, 30s for frontends)
- **`api_locations`**: List all backend routes (anything that should go to backend container)
- **`rate_limit`**: Protect your API from abuse
- **`deployment_strategy`**: Use `blue-green` for zero-downtime, `direct` for simple apps

### Step 2: Create Docker Compose File

Create `/deploy/apps/task-manager/docker-compose.yml`:

```bash
mkdir -p /deploy/apps/task-manager
vim /deploy/apps/task-manager/docker-compose.yml
```

```yaml
version: '3.8'

# =============================================================================
# Task Manager Application Services
# =============================================================================

networks:
  platform:
    external: true
    name: platform

services:
  # ===========================================================================
  # BACKEND
  # ===========================================================================
  backend:
    container_name: task-manager-backend
    image: ${DOCKER_REGISTRY:-ghcr.io}/myuser/task-manager-backend:${VERSION:-latest}
    restart: unless-stopped
    networks:
      - platform
    environment:
      - NODE_ENV=production
      - DATABASE_URL=${DATABASE_URL}
      - JWT_SECRET=${JWT_SECRET}
      # Add your app's environment variables
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/api/health"]
      interval: 30s
      timeout: 10s
      retries: 10
      start_period: 60s  # Must match projects.yml!
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"

  # ===========================================================================
  # FRONTEND
  # ===========================================================================
  frontend:
    container_name: task-manager-frontend
    image: ${DOCKER_REGISTRY:-ghcr.io}/myuser/task-manager-frontend:${VERSION:-latest}
    restart: unless-stopped
    networks:
      - platform
    environment:
      - NEXT_PUBLIC_API_URL=${API_URL}
      # Add your frontend's environment variables
    healthcheck:
      test: ["CMD", "wget", "--spider", "-q", "http://localhost:3000/"]
      interval: 30s
      timeout: 10s
      retries: 10
      start_period: 30s  # Must match projects.yml!
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
```

**Important Notes**:

- **Health checks must match** `projects.yml` exactly
- **Use environment variables** for configuration (set in `.env` files)
- **Connect to `platform` network** to communicate with nginx/monitoring

### Step 3: Create Environment Files

Create production environment file:

```bash
vim /deploy/apps/task-manager/.env.production
```

```bash
# Version (set by CI/CD)
VERSION=latest

# Docker Registry
DOCKER_REGISTRY=ghcr.io

# Database
DATABASE_URL=postgresql://user:password@postgres:5432/taskmanager

# Security
JWT_SECRET=your-production-secret-here-change-this

# API
API_URL=https://tasks.mycompany.com
```

Create staging environment file:

```bash
vim /deploy/apps/task-manager/.env.staging
```

```bash
# Version (set by CI/CD)
VERSION=staging

# Docker Registry
DOCKER_REGISTRY=ghcr.io

# Database
DATABASE_URL=postgresql://user:password@postgres:5432/taskmanager_staging

# Security
JWT_SECRET=your-staging-secret-here-change-this

# API
API_URL=https://staging.tasks.mycompany.com
```

### Step 4: Create Nginx Configuration

Create `/deploy/platform/nginx/conf.d/task-manager.conf`:

```bash
vim /deploy/platform/nginx/conf.d/task-manager.conf
```

```nginx
# =============================================================================
# Task Manager - Nginx Configuration
# =============================================================================

# =============================================================================
# PRODUCTION: tasks.mycompany.com
# =============================================================================
server {
    listen 443 ssl http2;
    server_name tasks.mycompany.com www.tasks.mycompany.com;

    # SSL certificates (will be created by certbot)
    ssl_certificate /etc/letsencrypt/live/tasks.mycompany.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/tasks.mycompany.com/privkey.pem;

    # Include security headers
    include /etc/nginx/includes/security-headers.conf;

    # Logs
    access_log /var/log/nginx/task-manager.access.log detailed;
    error_log /var/log/nginx/task-manager.error.log warn;

    # ==========================================================================
    # BACKEND ROUTES (API, GraphQL, Auth)
    # ==========================================================================
    location ~ ^/(api|graphql|auth) {
        # Rate limiting for API
        limit_req zone=api burst=50 nodelay;

        # Proxy to backend
        proxy_pass http://task-manager-backend;

        # Include standard proxy headers
        include /etc/nginx/includes/proxy-headers.conf;

        # API-specific timeouts
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }

    # ==========================================================================
    # FRONTEND ROUTES (Next.js App)
    # ==========================================================================
    location / {
        # Rate limiting for general traffic
        limit_req zone=general burst=100 nodelay;

        # Proxy to frontend
        proxy_pass http://task-manager-frontend;

        # Include standard proxy headers
        include /etc/nginx/includes/proxy-headers.conf;
    }

    # ==========================================================================
    # STATIC ASSETS (with caching)
    # ==========================================================================
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)$ {
        proxy_pass http://task-manager-frontend;
        include /etc/nginx/includes/proxy-headers.conf;

        # Cache static assets
        proxy_cache_valid 200 7d;
        add_header Cache-Control "public, max-age=604800, immutable";
    }
}

# =============================================================================
# STAGING: staging.tasks.mycompany.com
# =============================================================================
server {
    listen 443 ssl http2;
    server_name staging.tasks.mycompany.com;

    # SSL certificates
    ssl_certificate /etc/letsencrypt/live/staging.tasks.mycompany.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/staging.tasks.mycompany.com/privkey.pem;

    # Include security headers
    include /etc/nginx/includes/security-headers.conf;

    # Logs
    access_log /var/log/nginx/task-manager-staging.access.log detailed;
    error_log /var/log/nginx/task-manager-staging.error.log warn;

    # Backend routes
    location ~ ^/(api|graphql|auth) {
        limit_req zone=api burst=100 nodelay;  # More lenient for staging
        proxy_pass http://task-manager-backend-staging;
        include /etc/nginx/includes/proxy-headers.conf;
    }

    # Frontend routes
    location / {
        limit_req zone=general burst=200 nodelay;
        proxy_pass http://task-manager-frontend-staging;
        include /etc/nginx/includes/proxy-headers.conf;
    }
}
```

### Step 5: Update Nginx Main Config (Upstreams)

Edit `/deploy/platform/nginx/nginx.conf` and add upstream definitions:

```nginx
# Task Manager Production
upstream task-manager-backend {
    server task-manager-backend:8080 max_fails=3 fail_timeout=30s;
}

upstream task-manager-frontend {
    server task-manager-frontend:3000 max_fails=3 fail_timeout=30s;
}

# Task Manager Staging
upstream task-manager-backend-staging {
    server task-manager-backend-staging:8080 max_fails=3 fail_timeout=30s;
}

upstream task-manager-frontend-staging {
    server task-manager-frontend-staging:3000 max_fails=3 fail_timeout=30s;
}
```

### Step 6: Obtain SSL Certificates

```bash
# Production
docker exec platform-certbot certbot certonly \
  --webroot -w /var/www/certbot \
  -d tasks.mycompany.com \
  -d www.tasks.mycompany.com \
  --email admin@mycompany.com \
  --agree-tos \
  --non-interactive

# Staging
docker exec platform-certbot certbot certonly \
  --webroot -w /var/www/certbot \
  -d staging.tasks.mycompany.com \
  --email admin@mycompany.com \
  --agree-tos \
  --non-interactive
```

### Step 7: Deploy!

```bash
# Deploy to staging first
./deploy/lib/deploy.sh task-manager staging

# Check health
./deploy/lib/health-check.sh task-manager staging

# If healthy, deploy to production
./deploy/lib/deploy.sh task-manager production
```

## ✅ Verification Checklist

After deployment, verify:

- [ ] Application accessible at domain (`https://tasks.mycompany.com`)
- [ ] SSL certificate valid (check browser)
- [ ] Backend routes working (`https://tasks.mycompany.com/api/health`)
- [ ] Frontend routes working (`https://tasks.mycompany.com/`)
- [ ] Health checks passing: `./deploy/lib/health-check.sh task-manager production`
- [ ] Metrics visible in Prometheus: `http://prometheus:9090/targets`
- [ ] Dashboard in Grafana: `https://monitoring.filter-ical.de`
- [ ] Alerts configured in Alertmanager

## 🔍 Troubleshooting

### Issue: Container won't start

```bash
# Check logs
docker logs task-manager-backend
docker logs task-manager-frontend

# Check environment variables
docker exec task-manager-backend env

# Check health endpoint manually
docker exec task-manager-backend curl http://localhost:8080/api/health
```

### Issue: 502 Bad Gateway

```bash
# Check nginx logs
docker logs platform-nginx

# Check upstream definition
docker exec platform-nginx nginx -T | grep -A 5 "upstream task-manager"

# Check container networking
docker inspect task-manager-backend | grep -A 10 Networks
```

### Issue: SSL certificate not found

```bash
# List certificates
docker exec platform-certbot certbot certificates

# Check certificate location
docker exec platform-nginx ls -la /etc/letsencrypt/live/

# Re-obtain certificate (see Step 6)
```

## 📚 Next Steps

1. **Set up CI/CD** - Add GitHub Actions workflow to deploy on push
2. **Configure monitoring** - Expose `/metrics` endpoint from your app
3. **Test rollback** - Simulate a failure and test auto-rollback
4. **Load testing** - Verify performance under load
5. **Documentation** - Document your app-specific configuration

## 🎓 Templates

Full templates available in `/deploy/templates/new-app/`:

```bash
cp -r /deploy/templates/new-app /deploy/apps/my-new-app
# Edit files as needed
```

---

**Congratulations!** Your application is now part of the production-grade platform. 🎉
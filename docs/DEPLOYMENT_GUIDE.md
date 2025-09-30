# Deployment Guide

> Comprehensive guide to deploying applications on the platform

## 🎯 Overview

The platform supports two deployment strategies:

1. **Direct Deployment** - Simple, fast, brief downtime (~5-10 seconds)
2. **Blue-Green Deployment** - Zero downtime, safer, more complex

## 📋 Prerequisites

Before deploying, ensure:

- [ ] **Docker images built** and pushed to registry
- [ ] **DNS configured** (domain points to server)
- [ ] **SSL certificates** obtained (or will auto-obtain)
- [ ] **Environment variables** set in `.env` files
- [ ] **Health endpoints** implemented in application
- [ ] **projects.yml** updated with project configuration

## 🚀 Deployment Strategies

### Direct Deployment (Simple)

**When to use**:
- Low-traffic applications
- Non-critical services
- Staging environments
- Quick updates/hotfixes

**Downtime**: ~5-10 seconds (during container restart)

**Command**:
```bash
./deploy/lib/deploy.sh <project-name> <environment>
```

**Example**:
```bash
./deploy/lib/deploy.sh task-manager staging
```

**What happens**:
1. Pre-flight validation
2. Create backup
3. Pull new images
4. Stop old containers
5. Start new containers
6. Health check (60s warmup)
7. Reload nginx

**Rollback** (if needed):
```bash
./deploy/lib/rollback.sh task-manager staging
```

### Blue-Green Deployment (Zero Downtime)

**When to use**:
- Production environments
- High-traffic applications
- Critical services
- When zero downtime is required

**Downtime**: 0 seconds

**Command**:
```bash
# Configured in projects.yml: deployment_strategy: blue-green
./deploy/lib/deploy.sh <project-name> production
```

**Example**:
```bash
./deploy/lib/deploy.sh filter-ical production
```

**What happens**:
1. Pre-flight validation
2. Create backup
3. Deploy to **inactive environment** (e.g., green)
4. Health check green environment (120s warmup)
5. **Switch traffic** (nginx now routes to green)
6. Monitor for 5 minutes
7. Stop blue environment (old version)

**Rollback** (automatic on failure):
- If green health check fails → automatic rollback to blue
- Traffic instantly switches back to blue
- Zero impact to users

## 📝 Step-by-Step: Production Deployment

### Step 1: Pre-Deployment Checklist

```bash
# 1. Verify application is working locally
make test
make test-all

# 2. Build and tag Docker images
docker build -t ghcr.io/user/app-backend:v1.2.3 .
docker push ghcr.io/user/app-backend:v1.2.3

# 3. Update version in .env.production
echo "VERSION=v1.2.3" > /deploy/apps/my-app/.env.production

# 4. Verify SSH access to server
ssh ec2 "echo 'SSH working'"

# 5. Check disk space on server
ssh ec2 "df -h"

# 6. Verify current production status
./deploy/lib/health-check.sh my-app production
```

### Step 2: Deploy to Staging (Dry Run)

```bash
# SSH into server
ssh ec2

# Deploy to staging
./deploy/lib/deploy.sh my-app staging

# Watch logs during deployment
docker logs -f my-app-backend-staging

# Verify staging health
./deploy/lib/health-check.sh my-app staging

# Test staging manually
curl https://staging.myapp.com/api/health
# Manually test critical features in browser
```

### Step 3: Deploy to Production

```bash
# Still on server

# Deploy with monitoring
./deploy/lib/deploy.sh my-app production

# Script will:
# - Validate everything BEFORE touching production
# - Create backup of current deployment
# - Deploy to inactive environment
# - Run health checks
# - Switch traffic only if healthy
# - Auto-rollback on any failure

# Monitor deployment logs
tail -f /var/log/deployments.log
```

### Step 4: Post-Deployment Verification

```bash
# 1. Check application health
./deploy/lib/health-check.sh my-app production

# 2. Check HTTP endpoints
curl https://myapp.com/api/health
curl https://myapp.com/

# 3. Check Docker containers
docker ps | grep my-app

# 4. Check logs for errors
docker logs --tail 50 my-app-backend
docker logs --tail 50 my-app-frontend

# 5. Check nginx logs
docker logs --tail 50 platform-nginx | grep myapp

# 6. Check Prometheus metrics
# Open http://server-ip:9090
# Query: up{project="my-app"}

# 7. Check Grafana dashboard
# Open https://monitoring.filter-ical.de
# Look for my-app dashboard

# 8. Test critical user flows
# - Login
# - Main features
# - Database operations
```

### Step 5: Monitor for Issues

```bash
# Watch for errors in next 15 minutes
watch -n 30 './deploy/lib/health-check.sh my-app production'

# Monitor error rate in logs
docker logs -f my-app-backend 2>&1 | grep -i error

# Check Prometheus for alerts
curl http://localhost:9090/api/v1/alerts

# If issues detected → immediate rollback
./deploy/lib/rollback.sh my-app production
```

## 🔧 Deployment Options

### Skip Backup (Faster)

```bash
./deploy/lib/deploy.sh my-app production --skip-backup
```

**Use when**:
- Hotfix deployment
- No state to lose
- You have manual backups

**Risk**: Cannot rollback automatically

### Force Deploy (Bypass Validation)

```bash
./deploy/lib/deploy.sh my-app production --force
```

**Use when**:
- Emergency hotfix
- Validation is giving false negatives
- You know what you're doing

**Risk**: May deploy broken version

## 🔄 Rollback Procedures

### Automatic Rollback

The deployment script automatically rolls back if:

- Health checks fail after deployment
- Containers fail to start
- HTTP endpoints return errors

**No action needed** - script handles it automatically.

### Manual Rollback

If you detect issues after deployment succeeds:

```bash
# Rollback to last backup
./deploy/lib/rollback.sh my-app production

# Rollback to specific backup
./deploy/lib/rollback.sh my-app production backup_20250930_143000

# List available backups
ls -la /opt/backups/my-app/production/
```

### Emergency Rollback (Blue-Green)

For blue-green deployments, you can instantly switch back:

```bash
# Check current active environment
cat /opt/websites/state/my-app.active
# Output: green

# Switch back to blue (instant)
echo "blue" > /opt/websites/state/my-app.active
docker exec platform-nginx nginx -s reload

# Verify rollback
curl https://myapp.com/api/version
```

## 📊 Monitoring During Deployment

### Real-Time Logs

**Terminal 1** - Deployment script:
```bash
./deploy/lib/deploy.sh my-app production
```

**Terminal 2** - Application logs:
```bash
docker logs -f my-app-backend
```

**Terminal 3** - Nginx logs:
```bash
docker logs -f platform-nginx | grep myapp
```

**Terminal 4** - System metrics:
```bash
watch -n 5 'docker stats --no-stream | grep my-app'
```

### Prometheus Queries

```promql
# Check if app is up
up{project="my-app", environment="production"}

# Check error rate
rate(http_requests_total{project="my-app", status=~"5.."}[5m])

# Check response time
histogram_quantile(0.95, rate(http_request_duration_seconds_bucket{project="my-app"}[5m]))

# Check container restarts
rate(container_last_seen{name=~"my-app.*"}[5m])
```

## 🚨 Troubleshooting Deployments

### Issue: Health Check Fails

**Symptoms**:
```
❌ Health check failed: http://localhost:3000/health (HTTP 000 after 3 attempts)
```

**Diagnosis**:
```bash
# 1. Check if container is running
docker ps | grep my-app

# 2. Check container logs
docker logs my-app-backend

# 3. Check health endpoint manually
docker exec my-app-backend curl http://localhost:3000/health

# 4. Check if port is correct
docker port my-app-backend

# 5. Check container health status
docker inspect my-app-backend | grep -A 10 Health
```

**Common causes**:
- Application crashed during startup
- Wrong port in health check
- Health endpoint not implemented
- start_period too short (app needs more time to start)

**Fix**:
```bash
# Increase start_period in projects.yml
start_period: 90  # was 60

# Or fix application startup time
```

### Issue: 502 Bad Gateway

**Symptoms**:
```
curl https://myapp.com → 502 Bad Gateway
```

**Diagnosis**:
```bash
# 1. Check nginx error logs
docker logs platform-nginx 2>&1 | grep -i error | tail -20

# 2. Check upstream
docker exec platform-nginx nginx -T | grep -A 5 "upstream my-app"

# 3. Check if backend is accessible from nginx
docker exec platform-nginx wget -O- http://my-app-backend:3000/health

# 4. Check container network
docker network inspect platform | grep -A 10 my-app
```

**Common causes**:
- Backend container not running
- Wrong container name in upstream
- Backend not connected to platform network
- Backend port mismatch

**Fix**:
```nginx
# Verify upstream points to correct container:port
upstream my-app-backend {
    server my-app-backend:3000;  # Must match container name:port
}
```

### Issue: Rollback Fails

**Symptoms**:
```
❌ Cannot rollback: green environment is not running
```

**Diagnosis**:
```bash
# 1. Check available backups
ls -la /opt/backups/my-app/production/

# 2. Check Docker images with backup tags
docker images | grep backup

# 3. Check if old containers were removed too quickly
docker ps -a | grep my-app
```

**Manual fix**:
```bash
# 1. Find last working backup
ls -lt /opt/backups/my-app/production/*.meta | head -1

# 2. Restore specific backup
./deploy/lib/rollback.sh my-app production backup_20250930_120000

# 3. If no backups, pull last known good version
docker pull ghcr.io/user/my-app:v1.2.2
# Manually update docker-compose and restart
```

## 🔐 Security Considerations

### Environment Variables

```bash
# NEVER commit secrets to git
# ✅ Use .env files (git ignored)
echo "SECRET_KEY=abc123" >> /deploy/apps/my-app/.env.production

# ✅ Or use GitHub Secrets in CI/CD
# Then SSH deploy script reads from environment
```

### SSL Certificates

```bash
# Auto-renewal configured via certbot
# Check renewal:
docker exec platform-certbot certbot certificates

# Manual renewal if needed:
./deploy/platform/scripts/certbot-renew.sh
```

### Access Control

```bash
# Only allow deployments from CI/CD or specific IPs
# Configure SSH key-based auth only
# Use firewall rules to restrict access
```

## 📚 CI/CD Integration

### GitHub Actions Example

```yaml
# .github/workflows/deploy-production.yml
name: Deploy to Production

on:
  push:
    tags:
      - 'v*'

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Build and Push Docker Images
        run: |
          docker build -t ghcr.io/${{ github.repository }}:${{ github.ref_name }} .
          docker push ghcr.io/${{ github.repository }}:${{ github.ref_name }}

      - name: Deploy to Production
        uses: appleboy/ssh-action@v1.0.3
        with:
          host: ${{ secrets.EC2_HOST }}
          username: ${{ secrets.EC2_USER }}
          key: ${{ secrets.EC2_SSH_KEY }}
          script: |
            cd /deploy/apps/my-app
            echo "VERSION=${{ github.ref_name }}" > .env.production
            cd /deploy
            ./lib/deploy.sh my-app production

      - name: Verify Deployment
        run: |
          sleep 30
          curl -f https://myapp.com/api/health || exit 1

      - name: Notify on Failure
        if: failure()
        run: |
          # Send Slack notification
          # Roll back deployment
```

## 🎓 Best Practices

1. **Always deploy to staging first**
2. **Use blue-green for production**
3. **Monitor for 15 minutes after deployment**
4. **Have rollback plan ready**
5. **Document deployment-specific steps**
6. **Tag Docker images with versions**
7. **Test rollback procedure regularly**
8. **Keep backups for 30 days**
9. **Review logs after every deployment**
10. **Automate via CI/CD**

---

**Happy deploying!** 🚀
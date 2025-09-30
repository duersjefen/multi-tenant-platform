# Troubleshooting Guide

> Common issues and their solutions

## 🔍 Diagnostic Commands

Quick commands to check system status:

```bash
# Platform health
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
./deploy/lib/health-check.sh <project> production

# Logs
docker logs <container-name>
docker logs platform-nginx
docker logs platform-prometheus

# Resources
docker stats --no-stream
df -h
free -h

# Network
docker network inspect platform
curl http://localhost/nginx-health

# Configuration
docker exec platform-nginx nginx -T
```

## 🚨 Common Issues

### Issue 1: Container Won't Start

**Symptoms**:
```bash
$ docker ps | grep my-app
# No output - container not running
```

**Diagnosis**:
```bash
# Check recent container exits
docker ps -a | grep my-app

# Check exit code and reason
docker inspect my-app-backend --format='{{.State.ExitCode}}: {{.State.Error}}'

# Check logs from failed container
docker logs my-app-backend
```

**Common Causes & Fixes**:

#### Environment Variable Missing
```bash
# Error in logs: "DATABASE_URL is required"

# Fix: Add to .env file
echo "DATABASE_URL=postgresql://..." >> .env.production

# Restart
docker-compose up -d
```

#### Port Already in Use
```bash
# Error: "port is already allocated"

# Find what's using the port
netstat -tuln | grep 3000

# Kill the process
kill $(lsof -t -i:3000)

# Or change port in docker-compose.yml
```

#### Image Not Found
```bash
# Error: "Unable to find image"

# Verify image exists
docker pull ghcr.io/user/app:v1.0.0

# Check registry auth
docker login ghcr.io

# Update image tag in .env
echo "VERSION=v1.0.0" > .env.production
```

#### Out of Disk Space
```bash
# Error: "no space left on device"

# Check disk usage
df -h

# Clean up old images
docker system prune -a --volumes

# Clean up old backups
find /opt/backups -mtime +30 -delete
```

---

### Issue 2: 502 Bad Gateway

**Symptoms**:
```bash
$ curl https://myapp.com
<html>502 Bad Gateway</html>
```

**Diagnosis**:
```bash
# Check nginx error logs
docker logs platform-nginx 2>&1 | grep -A 5 "502"

# Typical error:
# "connect() failed (111: Connection refused) while connecting to upstream"
```

**Common Causes & Fixes**:

#### Backend Not Running
```bash
# Check if backend container is running
docker ps | grep my-app-backend

# If not running, check why
docker logs my-app-backend

# Start it
docker-compose -f /deploy/apps/my-app/docker-compose.yml up -d backend
```

#### Wrong Upstream Configuration
```bash
# Check nginx upstream
docker exec platform-nginx nginx -T | grep -A 5 "upstream my-app"

# Should be:
upstream my-app-backend {
    server my-app-backend:3000;  # Must match container name and internal port
}

# NOT:
upstream my-app-backend {
    server my-app-backend:80;  # Wrong port
    server localhost:3000;     # Wrong host
}

# Fix nginx.conf and reload
docker exec platform-nginx nginx -s reload
```

#### Not on Platform Network
```bash
# Check if container is on platform network
docker inspect my-app-backend | grep -A 10 Networks

# Should show "platform" network

# Fix: Add to docker-compose.yml
networks:
  platform:
    external: true
    name: platform

services:
  backend:
    networks:
      - platform
```

#### Backend Health Check Failing
```bash
# Test backend manually
docker exec my-app-backend curl http://localhost:3000/health

# If fails, check:
# 1. Is app actually running inside container?
docker exec my-app-backend ps aux

# 2. Is app listening on correct port?
docker exec my-app-backend netstat -tuln | grep 3000

# 3. Is health endpoint implemented?
docker exec my-app-backend curl -v http://localhost:3000/health
```

---

### Issue 3: SSL Certificate Errors

**Symptoms**:
```bash
$ curl https://myapp.com
curl: (60) SSL certificate problem: certificate has expired
```

**Diagnosis**:
```bash
# Check certificate status
docker exec platform-certbot certbot certificates

# Check nginx certificate paths
docker exec platform-nginx cat /etc/nginx/nginx.conf | grep ssl_certificate
```

**Common Causes & Fixes**:

#### Certificate Not Obtained Yet
```bash
# Obtain certificate
docker exec platform-certbot certbot certonly \
  --webroot -w /var/www/certbot \
  -d myapp.com \
  --email admin@myapp.com \
  --agree-tos \
  --non-interactive

# Reload nginx
docker exec platform-nginx nginx -s reload
```

#### Certificate Expired
```bash
# Renew all certificates
docker exec platform-certbot certbot renew

# Or run renewal script
./deploy/platform/scripts/certbot-renew.sh

# Check expiry dates
docker exec platform-certbot certbot certificates
```

#### Wrong Certificate Path in Nginx
```bash
# List available certificates
docker exec platform-nginx ls -la /etc/letsencrypt/live/

# Update nginx config
vim /deploy/platform/nginx/conf.d/my-app.conf

# Should be:
ssl_certificate /etc/letsencrypt/live/myapp.com/fullchain.pem;
ssl_certificate_key /etc/letsencrypt/live/myapp.com/privkey.pem;

# Reload
docker exec platform-nginx nginx -s reload
```

---

### Issue 4: Health Checks Failing

**Symptoms**:
```bash
$ docker ps | grep my-app-backend
my-app-backend ... (unhealthy) ...
```

**Diagnosis**:
```bash
# Check health check configuration
docker inspect my-app-backend | grep -A 15 Healthcheck

# Check health check logs
docker inspect my-app-backend | grep -A 20 Health | grep Log

# Test health endpoint manually
docker exec my-app-backend curl -v http://localhost:3000/health
```

**Common Causes & Fixes**:

#### Start Period Too Short
```bash
# App takes 90 seconds to start, but start_period is 60s

# Fix in docker-compose.yml:
healthcheck:
  start_period: 90s  # Increase from 60s

# Or in projects.yml:
health_check:
  start_period: 90

# Recreate container
docker-compose up -d --force-recreate
```

#### Wrong Health Check Command
```bash
# Check current command
docker inspect my-app-backend --format='{{.Config.Healthcheck.Test}}'

# Fix common issues:

# ❌ Wrong: curl without -f flag (doesn't fail on 404/500)
test: ["CMD", "curl", "http://localhost:3000/health"]

# ✅ Correct: curl with -f flag
test: ["CMD", "curl", "-f", "http://localhost:3000/health"]

# ❌ Wrong: wget without spider/quiet
test: ["CMD", "wget", "http://localhost:80/"]

# ✅ Correct: wget with spider and quiet
test: ["CMD", "wget", "--spider", "-q", "http://localhost:80/"]
```

#### Health Endpoint Not Implemented
```bash
# Check if endpoint exists
docker exec my-app-backend curl -v http://localhost:3000/health

# If 404, implement health endpoint in your app

# Example (Python/FastAPI):
@app.get("/health")
def health():
    return {"status": "healthy"}

# Example (Node.js/Express):
app.get('/health', (req, res) => {
  res.json({ status: 'healthy' });
});
```

---

### Issue 5: High Memory Usage

**Symptoms**:
```bash
$ docker stats
CONTAINER          MEM USAGE / LIMIT
my-app-backend     1.8GB / 2GB      # 90% usage!
```

**Diagnosis**:
```bash
# Check container memory
docker stats --no-stream my-app-backend

# Check server memory
free -h

# Check for memory leaks
docker exec my-app-backend ps aux --sort=-%mem | head -10
```

**Common Causes & Fixes**:

#### No Memory Limit Set
```bash
# Add memory limits to docker-compose.yml
services:
  backend:
    deploy:
      resources:
        limits:
          memory: 1G
        reservations:
          memory: 512M

# Restart
docker-compose up -d --force-recreate
```

#### Memory Leak in Application
```bash
# Monitor memory over time
watch -n 5 'docker stats --no-stream my-app-backend'

# If continuously increasing → memory leak

# Fix application code (beyond scope of infra)
# Workaround: Add restart policy
services:
  backend:
    restart: unless-stopped
    deploy:
      resources:
        limits:
          memory: 1G
    # OOM killer will restart container if it exceeds limit
```

#### Too Many Containers Running
```bash
# Check all containers
docker ps | wc -l

# Clean up old/unused containers
docker ps -a | grep Exited | awk '{print $1}' | xargs docker rm

# Clean up old images
docker images | grep "<none>" | awk '{print $3}' | xargs docker rmi
```

---

### Issue 6: Deployment Script Fails

**Symptoms**:
```bash
$ ./deploy/lib/deploy.sh my-app production
❌ VALIDATION FAILED - Deployment aborted
```

**Diagnosis**:
```bash
# Run with verbose output
bash -x ./deploy/lib/deploy.sh my-app production

# Check what validation failed
# Common failures: disk space, missing images, bad config
```

**Common Causes & Fixes**:

#### Insufficient Disk Space
```bash
# Error: "Insufficient disk space: 2GB available, 5GB required"

# Check disk usage
df -h

# Clean up
docker system prune -a --volumes
find /opt/backups -mtime +30 -delete
find /var/log -name "*.log" -mtime +7 -delete

# Or bypass (if you know what you're doing)
./deploy/lib/deploy.sh my-app production --force
```

#### Missing Docker Images
```bash
# Error: "Missing Docker images: ghcr.io/user/app:v1.2.3"

# Pull images first
docker pull ghcr.io/user/app:v1.2.3

# Or build locally
docker build -t ghcr.io/user/app:v1.2.3 .
```

#### Invalid Nginx Configuration
```bash
# Error: "Nginx configuration is invalid"

# Test nginx config
docker exec platform-nginx nginx -t

# Check syntax errors
# Fix the error in nginx config
vim /deploy/platform/nginx/conf.d/my-app.conf

# Test again
docker exec platform-nginx nginx -t
```

---

### Issue 7: Prometheus Not Scraping Metrics

**Symptoms**:
```bash
# In Prometheus UI: Target shows as "DOWN"
```

**Diagnosis**:
```bash
# Check Prometheus targets
curl http://localhost:9090/api/v1/targets | jq

# Check if app exposes /metrics
curl http://my-app-backend:3000/metrics
```

**Common Causes & Fixes**:

#### /metrics Endpoint Not Implemented
```bash
# Check if endpoint exists
docker exec my-app-backend curl http://localhost:3000/metrics

# If 404, implement in your application:

# Python (FastAPI + prometheus-client):
from prometheus_client import make_asgi_app
metrics_app = make_asgi_app()
app.mount("/metrics", metrics_app)

# Node.js (Express + prom-client):
const promClient = require('prom-client');
app.get('/metrics', async (req, res) => {
  res.set('Content-Type', promClient.register.contentType);
  res.end(await promClient.register.metrics());
});
```

#### Wrong Scrape Configuration
```bash
# Check Prometheus config
docker exec platform-prometheus cat /etc/prometheus/prometheus.yml

# Fix scrape config in /deploy/platform/monitoring/prometheus/prometheus.yml:
- job_name: 'my-app-backend'
  static_configs:
    - targets: ['my-app-backend:3000']  # Must match container name:port
      labels:
        project: 'my-app'

# Reload Prometheus
docker exec platform-prometheus killall -HUP prometheus
```

---

## 🛠️ Emergency Procedures

### Complete Platform Restart

```bash
# Stop everything
cd /deploy/platform
docker-compose -f docker-compose.platform.yml down

cd /deploy/apps/my-app
docker-compose down

# Start platform first
cd /deploy/platform
docker-compose -f docker-compose.platform.yml up -d

# Wait for platform to be healthy
sleep 30

# Start applications
cd /deploy/apps/my-app
docker-compose up -d

# Verify
docker ps
```

### Complete System Recovery

```bash
# If everything is broken, rebuild from scratch:

# 1. Stop all containers
docker stop $(docker ps -q)
docker rm $(docker ps -aq)

# 2. Remove all networks
docker network prune -f

# 3. Recreate platform network
docker network create platform

# 4. Start platform
cd /deploy/platform
docker-compose -f docker-compose.platform.yml up -d

# 5. Start applications
./deploy/lib/deploy.sh my-app production --force
```

## 📞 Getting Help

### Collect Diagnostic Information

```bash
# Save to file for sharing
cat > diagnostics.txt <<EOF
=== System Info ===
$(uname -a)
$(docker --version)
$(docker-compose --version)

=== Containers ===
$(docker ps -a)

=== Networks ===
$(docker network ls)
$(docker network inspect platform)

=== Disk Space ===
$(df -h)

=== Memory ===
$(free -h)

=== Logs ===
$(docker logs platform-nginx 2>&1 | tail -50)
$(docker logs my-app-backend 2>&1 | tail -50)

=== Nginx Config ===
$(docker exec platform-nginx nginx -T 2>&1)
EOF

# Share this file when asking for help
```

### Check System Status

```bash
# Run comprehensive health check
./deploy/lib/health-check.sh my-app production

# Check all platform services
docker ps --filter "name=platform-*"

# Check all application services
docker ps --filter "name=my-app-*"
```

---

**Still stuck?** Open an issue with your diagnostics file!
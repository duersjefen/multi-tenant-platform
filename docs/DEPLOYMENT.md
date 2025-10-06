# Deployment System Documentation

## Overview

The multi-tenant platform uses a robust, automated deployment system with comprehensive validation, smoke testing, and automatic rollback capabilities. This ensures zero-downtime deployments with strong safety guarantees.

## 🎯 Key Features

- ✅ **Pre-flight validation** - Validates environment before deployment starts
- ✅ **Automatic backups** - Creates backups before every deployment
- ✅ **Smoke tests before traffic switch** - Tests new containers before sending traffic
- ✅ **Automatic rollback** - Rolls back on failure using latest backup
- ✅ **Deployment manifests** - Tracks deployment history and state
- ✅ **Nginx config generation** - Configs auto-generated from projects.yml
- ✅ **Environment isolation** - Production/staging completely separate

## 🚀 Deployment Flow

### Step-by-Step Process

```
┌─────────────────────────────────────────────────────────────┐
│ 1. PRE-FLIGHT VALIDATION                                    │
│    ✓ Check disk space                                       │
│    ✓ Validate platform repo sync                            │
│    ✓ Validate nginx configuration                           │
│    ✓ Validate environment variables                         │
└─────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────┐
│ 2. CREATE BACKUP                                            │
│    ✓ Tag current Docker images with backup name            │
│    ✓ Backup volumes                                         │
│    ✓ Backup configuration files                             │
│    ✓ Save backup metadata                                   │
└─────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────┐
│ 3. PULL NEW DOCKER IMAGES                                   │
│    ✓ Pull latest images from registry                       │
└─────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────┐
│ 4. DEPLOY NEW VERSION                                       │
│    ✓ Stop and remove old containers                         │
│    ✓ Start new containers                                   │
│    ✓ Containers NOT receiving traffic yet                   │
└─────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────┐
│ 4.5. DATABASE MIGRATIONS                                    │
│     ✓ Run Alembic migrations if backend exists              │
└─────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────┐
│ 5. HEALTH CHECK                                             │
│    ✓ Validate all containers are healthy                    │
│    ✓ Wait for health checks to pass                         │
│    ✓ Rollback if health check fails                         │
└─────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────┐
│ 5.5. SMOKE TESTS (PRE-TRAFFIC SWITCH) ⭐                    │
│     ✓ Test backend endpoints (curl inside container)        │
│     ✓ Test frontend endpoints (curl inside container)       │
│     ✓ Rollback if smoke tests fail                          │
│     ✓ Traffic still going to OLD containers                 │
└─────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────┐
│ 6. RELOAD NGINX (TRAFFIC SWITCH) 🚦                         │
│    ✓ Validate nginx configuration                           │
│    ✓ Reload nginx to switch traffic to new containers       │
│    ✓ Traffic now going to NEW containers                    │
└─────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────┐
│ 7. CLEANUP DANGLING RESOURCES                               │
│    ✓ Remove dangling Docker images                          │
└─────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────┐
│ 8. SAVE DEPLOYMENT MANIFEST                                 │
│    ✓ Record deployment details (images, git SHA, backup)    │
│    ✓ Update deployment history                              │
└─────────────────────────────────────────────────────────────┘
                            ↓
                       ✅ SUCCESS
```

### Critical Safety Feature: Smoke Tests Before Traffic Switch

**The most important improvement**: Smoke tests now run **BEFORE** nginx reload, meaning:

1. **New containers deployed** but NOT receiving traffic
2. **Smoke tests run** against new containers
3. **If tests fail**: Automatic rollback, traffic stays on old containers
4. **If tests pass**: Nginx reloads, traffic switches to new containers
5. **Old containers removed** only after successful switch

This ensures **zero impact** on users if deployment fails.

## 📋 Pre-Deployment Validation

Before any deployment starts, the system validates:

### 1. Disk Space
- Minimum 5GB required
- Prevents deployment failures due to insufficient space

### 2. Platform Repo Sync
- Ensures platform configs match remote
- Prevents deployment with stale configs

### 3. Nginx Configuration
- Validates nginx syntax
- Prevents breaking the reverse proxy

### 4. Environment Variables
- Checks required vars exist in .env files
- Validates DATABASE_URL, SECRET_KEY, etc.

**Validation fails**: Deployment aborted immediately (unless `--force` used)

## 🔄 Automatic Rollback

The system automatically rolls back on failure at these points:

### Health Check Failure (Step 5)
```bash
if container health check fails:
    1. Get latest backup name
    2. Restore backup images (retag as :latest)
    3. Restore volumes
    4. Restore configuration
    5. Restart containers
    6. Notify about rollback
```

### Smoke Test Failure (Step 5.5)
```bash
if smoke tests fail:
    1. Get latest backup name
    2. Restore backup (same as above)
    3. Traffic never switched to broken deployment
    4. Notify about rollback
```

### Rollback Implementation Details

1. **Backup tagged images**: `ghcr.io/user/app:backup_20250106_120000`
2. **Restore retaggs images**: `ghcr.io/user/app:latest` ← backup tag
3. **Docker compose uses :latest**: Starts restored containers automatically

## 📊 Deployment Manifests

Every successful deployment saves a manifest in `/opt/deployments/{project}/{environment}/manifest.json`:

```json
{
  "project": "filter-ical",
  "environment": "production",
  "current_deployment": {
    "version": "latest",
    "deployed_at": "2025-01-06T12:00:00Z",
    "deployed_by": "github-actions",
    "git_sha": "abc123def456",
    "backup": "backup_20250106_120000",
    "images": {
      "backend": "ghcr.io/user/filter-ical-backend:latest",
      "frontend": "ghcr.io/user/filter-ical-frontend:latest"
    }
  },
  "deployment_history": [
    // Last 10 deployments
  ]
}
```

### View Deployment Status

```bash
# Current status
./lib/deployment-status.sh filter-ical production

# Deployment history
./lib/deployment-status.sh filter-ical production --history

# Rollback options
./lib/deployment-status.sh filter-ical production --rollback
```

## 🔧 Usage

### Deploy to Staging (Automatic)

```bash
# Triggered automatically on push to main
git push origin main

# Or manually trigger via GitHub Actions
# Go to Actions → Deploy to Staging → Run workflow
```

### Deploy to Production (Manual Approval)

```bash
# Via GitHub Actions (RECOMMENDED)
1. Go to Actions → Deploy to Production
2. Click "Run workflow"
3. Type "deploy" to confirm
4. Workflow runs with manual approval gate

# Or directly on server (NOT RECOMMENDED)
ssh user@server
cd /opt/multi-tenant-platform
./lib/deploy.sh filter-ical production
```

### Deploy with Options

```bash
# Skip backup (NOT RECOMMENDED)
./lib/deploy.sh filter-ical staging --skip-backup

# Force deployment (bypasses validation failures)
./lib/deploy.sh filter-ical staging --force
```

### View Deployment Status

```bash
# Current deployment info
./lib/deployment-status.sh filter-ical production

# Full deployment history
./lib/deployment-status.sh filter-ical production --history

# Available rollback options
./lib/deployment-status.sh filter-ical production --rollback
```

### Manual Rollback

```bash
# List available backups
./lib/deployment-status.sh filter-ical production --rollback

# Rollback to specific backup
cd /opt/multi-tenant-platform
source lib/functions/backup.sh
restore_backup filter-ical production backup_20250106_120000
```

## 🏗️ Nginx Configuration

### Auto-Generation from projects.yml

Nginx configs are **auto-generated** from `/config/projects.yml`:

```yaml
projects:
  filter-ical:
    domains:
      production: filter-ical.de
      staging: staging.filter-ical.de
    containers:
      backend:
        name: filter-ical-backend
        port: 3000
        api_locations: ["/api", "/domains", "/calendars", "/admin"]
      frontend:
        name: filter-ical-frontend
        port: 80
```

### Generation Process

```bash
# Manual generation (usually not needed)
python3 lib/generate-nginx-configs.py

# Automatic generation (happens in deployment workflow)
# - Pull platform configs
# - Regenerate nginx configs
# - Validate nginx syntax
# - Reload nginx
```

### Protection Against Manual Edits

A pre-commit hook **blocks manual edits** to generated nginx configs:

```bash
# This will fail
vim platform/nginx/conf.d/filter-ical.de.conf
git commit -m "manual edit"
# ❌ BLOCKED: Nginx config files were modified directly
#    Edit config/projects.yml instead
```

**To bypass (emergencies only)**:
```bash
git commit --no-verify
```

## 🐛 Troubleshooting

### Deployment Fails at Validation

```bash
# Check validation errors
./lib/deploy.sh filter-ical production

# Common issues:
# - Insufficient disk space → Free up space
# - Platform repo not synced → git fetch && git reset --hard origin/main
# - Invalid nginx config → Check projects.yml syntax
# - Missing env vars → Check .env.production

# Force deployment (skip validation)
./lib/deploy.sh filter-ical production --force
```

### Deployment Fails at Health Check

```bash
# Check container logs
docker logs filter-ical-backend-production
docker logs filter-ical-frontend-production

# Check container status
docker ps -a | grep filter-ical

# Automatic rollback already occurred
# Check deployment manifest for rollback details
./lib/deployment-status.sh filter-ical production
```

### Deployment Fails at Smoke Tests

```bash
# Check what smoke tests failed
# (Logs shown during deployment)

# Test endpoints manually
docker exec filter-ical-backend-production curl http://localhost:3000/health
docker exec filter-ical-frontend-production curl http://localhost/

# Automatic rollback already occurred
# Traffic never switched to broken deployment
```

### Nginx Reload Fails

```bash
# Validate nginx config
docker exec platform-nginx nginx -t

# Check nginx logs
docker logs platform-nginx

# Regenerate nginx configs
python3 lib/generate-nginx-configs.py

# Reload nginx
docker exec platform-nginx nginx -s reload
```

### Rollback Fails

```bash
# List available backups
ls -la /opt/backups/filter-ical/production/

# Check backup metadata
cat /opt/backups/filter-ical/production/backup_20250106_120000.meta

# Manually restore backup
cd /opt/multi-tenant-platform
source lib/functions/backup.sh
restore_backup filter-ical production backup_20250106_120000

# If all else fails: redeploy from GitHub Actions
```

## 📝 Environment Variables

### Required Variables

Each project needs these variables in `.env.{environment}`:

```bash
# Security
SECRET_KEY=your-secret-key-here
ADMIN_PASSWORD=your-admin-password

# Database
DATABASE_URL=postgresql://user:pass@host:5432/dbname

# Frontend (if applicable)
VITE_API_BASE_URL=https://your-domain.com
```

### Validation

The deployment system validates required variables exist:

```bash
# filter-ical requires: DATABASE_URL, SECRET_KEY
# Add more validations in lib/functions/validation.sh validate_all()
```

## 🔐 Security Notes

1. **Never commit secrets** to git repos
2. **Store secrets** in platform repo `.env.{environment}` files (gitignored)
3. **Platform repo** should be private with restricted access
4. **GitHub secrets** used for EC2 SSH keys, GHCR tokens
5. **Pre-commit hooks** prevent sensitive files from being committed

## 📚 Additional Resources

- [Platform Architecture](ARCHITECTURE.md)
- [Adding New Projects](ADDING_PROJECTS.md)
- [GitHub Actions Workflows](../.github/workflows/)
- [Nginx Config Generator](../lib/generate-nginx-configs.py)
- [Deployment Functions](../lib/functions/)

## 🆘 Emergency Procedures

### Production is Down

```bash
1. SSH to server: ssh user@ec2-host
2. Check container status: docker ps -a | grep filter-ical
3. Check nginx status: docker exec platform-nginx nginx -t
4. Quick rollback: restore_backup filter-ical production $(get_latest_backup filter-ical production)
5. If rollback fails: Trigger production deployment from GitHub Actions
```

### Database Issues

```bash
1. Check database connectivity:
   docker exec postgres-platform psql -U user -d dbname -c "SELECT 1;"

2. Check migrations:
   docker exec filter-ical-backend-production alembic current

3. Rollback migration if needed:
   docker exec filter-ical-backend-production alembic downgrade -1

4. Re-run migrations:
   docker exec filter-ical-backend-production alembic upgrade head
```

### Nginx Not Loading Configs

```bash
1. Validate syntax: docker exec platform-nginx nginx -t
2. Check file exists: docker exec platform-nginx ls -la /etc/nginx/conf.d/
3. Regenerate configs: python3 lib/generate-nginx-configs.py
4. Copy to container: docker cp platform/nginx/conf.d/filter-ical.de.conf platform-nginx:/etc/nginx/conf.d/
5. Reload: docker exec platform-nginx nginx -s reload
```

## ✅ Post-Deployment Checklist

After every production deployment:

- [ ] External HTTPS check passed
- [ ] Backend health endpoint responding
- [ ] Frontend loading correctly
- [ ] Database migrations applied
- [ ] Deployment manifest saved
- [ ] Backup created and verified
- [ ] No errors in container logs
- [ ] Monitoring shows healthy metrics

## 📊 Metrics and Monitoring

The deployment system tracks:

- Deployment duration
- Deployment success/failure rate
- Rollback frequency
- Backup creation/restoration
- Container health status
- Nginx reload success

View deployment history:
```bash
./lib/deployment-status.sh filter-ical production --history
```

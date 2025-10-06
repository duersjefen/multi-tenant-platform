# Deployment Quick Reference

Quick commands for common deployment tasks.

## 🚀 Deploy

```bash
# Staging (automatic on git push)
git push origin main

# Production (manual approval via GitHub Actions)
# GitHub → Actions → "Deploy to Production" → Run workflow → Type "deploy"

# Direct deployment (on server)
./lib/deploy.sh filter-ical production
./lib/deploy.sh filter-ical staging
```

## 📊 Status

```bash
# Current deployment status
./lib/deployment-status.sh filter-ical production

# Deployment history
./lib/deployment-status.sh filter-ical production --history

# Rollback options
./lib/deployment-status.sh filter-ical production --rollback
```

## 🔄 Rollback

```bash
# Automatic rollback (happens on deployment failure)
# - Health check fails → Auto rollback
# - Smoke tests fail → Auto rollback

# Manual rollback to latest backup
cd /opt/multi-tenant-platform
source lib/functions/backup.sh
LATEST=$(get_latest_backup filter-ical production)
restore_backup filter-ical production $LATEST

# Manual rollback to specific backup
restore_backup filter-ical production backup_20250106_120000
```

## 🔧 Nginx

```bash
# Regenerate configs from projects.yml
python3 lib/generate-nginx-configs.py

# Validate nginx config
docker exec platform-nginx nginx -t

# Reload nginx
docker exec platform-nginx nginx -s reload

# View nginx logs
docker logs platform-nginx
```

## 🐛 Debug

```bash
# Container status
docker ps -a | grep filter-ical

# Container logs
docker logs filter-ical-backend-production
docker logs filter-ical-frontend-production

# Test endpoints
docker exec filter-ical-backend-production curl http://localhost:3000/health
docker exec filter-ical-frontend-production curl http://localhost/

# Database connectivity
docker exec postgres-platform psql -U filterical_user -d filterical_production -c "SELECT 1;"

# Disk space
df -h /opt
```

## 📝 Configuration

```bash
# Edit environment variables
vim /opt/multi-tenant-platform/configs/filter-ical/.env.production
vim /opt/multi-tenant-platform/configs/filter-ical/.env.staging

# Edit nginx config (via projects.yml)
vim /opt/multi-tenant-platform/config/projects.yml
python3 lib/generate-nginx-configs.py

# Commit and push changes
git add -A
git commit -m "Update configs"
git push
```

## 💾 Backups

```bash
# List backups
ls -la /opt/backups/filter-ical/production/

# View backup metadata
cat /opt/backups/filter-ical/production/backup_20250106_120000.meta

# Cleanup old backups (keeps last 30 days)
source lib/functions/backup.sh
cleanup_old_backups filter-ical production 30
```

## 🗄️ Database

```bash
# Check current migration
docker exec filter-ical-backend-production alembic current

# Run migrations
docker exec filter-ical-backend-production alembic upgrade head

# Rollback migration
docker exec filter-ical-backend-production alembic downgrade -1

# View migration history
docker exec filter-ical-backend-production alembic history
```

## 🆘 Emergency

```bash
# Quick health check
curl -f https://filter-ical.de/ || echo "DOWN"

# Quick rollback
cd /opt/multi-tenant-platform
source lib/functions/backup.sh
restore_backup filter-ical production $(get_latest_backup filter-ical production)

# Redeploy from GitHub
# GitHub → Actions → "Deploy to Production" → Run workflow → Type "deploy"
```

## 📋 Pre-Deployment Checklist

Before deploying to production:

- [ ] Tested in staging
- [ ] Database migrations tested
- [ ] Backup available
- [ ] Disk space sufficient (5GB+)
- [ ] No active incidents
- [ ] Team notified

## 🔍 Monitoring

```bash
# Deployment manifest
cat /opt/deployments/filter-ical/production/manifest.json | jq

# Container resource usage
docker stats --no-stream | grep filter-ical

# Recent container events
docker events --since 1h --filter name=filter-ical
```

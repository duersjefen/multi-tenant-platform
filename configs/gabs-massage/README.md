# Gabs Massage - Deployment

Physiotherapy Scheduler application deployment for the multi-tenant platform.

## Quick Start

### First-Time Setup on Production Server

1. **Set environment variables:**
   ```bash
   cd /opt/multi-tenant-platform/deploy/apps/gabs-massage
   cp .env.example .env
   nano .env  # Set production secrets
   ```

2. **Obtain SSL certificates:**
   ```bash
   # Production domain
   docker compose -f /opt/multi-tenant-platform/platform/docker-compose.platform.yml run --rm certbot \
     certonly --webroot -w /var/www/certbot \
     -d gabs-massage.de \
     -d www.gabs-massage.de \
     --email info@paiss.me --agree-tos --no-eff-email

   # Staging domain
   docker compose -f /opt/multi-tenant-platform/platform/docker-compose.platform.yml run --rm certbot \
     certonly --webroot -w /var/www/certbot \
     -d staging.gabs-massage.de \
     --email info@paiss.me --agree-tos --no-eff-email
   ```

3. **Deploy the application:**
   ```bash
   cd /opt/multi-tenant-platform/deploy/apps/gabs-massage
   docker compose up -d
   ```

4. **Reload nginx to pick up new configuration:**
   ```bash
   cd /opt/multi-tenant-platform
   docker exec platform-nginx nginx -t
   docker exec platform-nginx nginx -s reload
   ```

5. **Verify deployment:**
   ```bash
   # Check container health
   docker ps | grep gabs-massage

   # Check logs
   docker logs gabs-massage-web
   docker logs gabs-massage-web-staging

   # Test domains
   curl https://gabs-massage.de/health
   curl https://staging.gabs-massage.de/health
   ```

## Regular Deployments

### Update to Latest Version

```bash
cd /opt/multi-tenant-platform/deploy/apps/gabs-massage

# Pull latest image
docker compose pull

# Restart with new image (brief downtime)
docker compose up -d

# Or use blue-green deployment (zero downtime)
./deploy-blue-green.sh  # TODO: Create this script
```

## Database Backups

The SQLite database is stored in a Docker volume: `gabs-massage-data`

### Manual Backup
```bash
# Backup production database
docker run --rm -v gabs-massage-data:/data -v $(pwd):/backup \
  alpine tar czf /backup/gabs-massage-backup-$(date +%Y%m%d-%H%M%S).tar.gz -C /data .

# Backup staging database
docker run --rm -v gabs-massage-staging-data:/data -v $(pwd):/backup \
  alpine tar czf /backup/gabs-massage-staging-backup-$(date +%Y%m%d-%H%M%S).tar.gz -C /data .
```

### Restore from Backup
```bash
# Restore production database
docker compose down gabs-massage-web
docker run --rm -v gabs-massage-data:/data -v $(pwd):/backup \
  alpine sh -c "cd /data && tar xzf /backup/gabs-massage-backup-TIMESTAMP.tar.gz"
docker compose up -d gabs-massage-web
```

## Troubleshooting

### Container won't start
```bash
# Check logs
docker logs gabs-massage-web

# Common issues:
# - Database file permissions
# - Missing environment variables
# - Port conflicts
```

### Database is locked
```bash
# SQLite database is locked by another process
# Stop the container and check for stale locks
docker compose down
docker compose up -d
```

### Reset staging database
```bash
docker compose down gabs-massage-web-staging
docker volume rm gabs-massage-staging-data
docker compose up -d gabs-massage-web-staging
```

## Architecture

- **Image:** ghcr.io/duersjefen/physiotherapy-scheduler
- **Port:** 3000 (internal)
- **Database:** SQLite in `/app/data/physiotherapy.db`
- **Frontend:** Served by backend at `/`
- **API:** Served by backend at `/api/*`

## Monitoring

View metrics at: https://monitoring.paiss.me

The application exposes:
- `/health` - Health check endpoint
- Application metrics (TODO: Add Prometheus metrics)

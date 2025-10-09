# Gabs Massage - Deployment

Professional massage therapy booking platform with Vue 3 frontend and Python FastAPI backend.

## Architecture

- **Backend Image:** ghcr.io/duersjefen/gabs-massage-backend:latest (Python 3.13)
- **Frontend Image:** ghcr.io/duersjefen/gabs-massage-frontend:latest
- **Backend Port:** 3001 (internal)
- **Frontend Port:** 80 (internal)
- **Database:** PostgreSQL (shared platform instance at `postgres-platform:5432`)
- **API Docs:** Available at `/docs` and `/redoc`

## Quick Start

### First-Time Setup on Production Server

1. **Create database and user on platform PostgreSQL:**
   ```bash
   docker exec postgres-platform psql -U postgres << EOF
   CREATE USER gabs_massage_user WITH PASSWORD 'YOUR_SECURE_PASSWORD';
   CREATE DATABASE gabs_massage_production OWNER gabs_massage_user;
   CREATE DATABASE gabs_massage_staging OWNER gabs_massage_user;
   GRANT ALL PRIVILEGES ON DATABASE gabs_massage_production TO gabs_massage_user;
   GRANT ALL PRIVILEGES ON DATABASE gabs_massage_staging TO gabs_massage_user;
   EOF
   ```

2. **Set environment variables:**
   ```bash
   cd /opt/multi-tenant-platform/deploy/apps/gabs-massage
   cp .env.example .env.production
   cp .env.example .env.staging
   nano .env.production  # Set production secrets
   nano .env.staging     # Set staging secrets
   ```

   **Important variables to change:**
   - `DATABASE_URL` - Update password to match PostgreSQL user password
   - `JWT_SECRET` - Generate with: `openssl rand -hex 64`
   - `SECRET_KEY` - Generate with: `openssl rand -hex 64`
   - `ADMIN_PASSWORD` - Set secure admin password

3. **Obtain SSL certificates:**
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

4. **Deploy the application:**
   ```bash
   cd /opt/multi-tenant-platform/deploy/apps/gabs-massage

   # Deploy staging first
   ENVIRONMENT=staging docker compose up -d

   # Test staging, then deploy production
   ENVIRONMENT=production docker compose up -d
   ```

5. **Reload nginx to pick up new configuration:**
   ```bash
   cd /opt/multi-tenant-platform
   docker exec platform-nginx nginx -t
   docker exec platform-nginx nginx -s reload
   ```

6. **Verify deployment:**
   ```bash
   # Check container health
   docker ps | grep gabs-massage

   # Check backend logs
   docker logs gabs-massage-backend-production
   docker logs gabs-massage-backend-staging

   # Check frontend logs
   docker logs gabs-massage-frontend-production
   docker logs gabs-massage-frontend-staging

   # Test health endpoints
   curl https://gabs-massage.de/health
   curl https://staging.gabs-massage.de/health

   # Test API docs
   curl https://gabs-massage.de/docs
   ```

## Regular Deployments

### Update to Latest Version

```bash
cd /opt/multi-tenant-platform/deploy/apps/gabs-massage

# Pull latest images
ENVIRONMENT=staging docker compose pull
ENVIRONMENT=production docker compose pull

# Deploy staging first (with brief downtime)
ENVIRONMENT=staging docker compose up -d

# Test staging thoroughly
curl https://staging.gabs-massage.de/health

# Deploy production
ENVIRONMENT=production docker compose up -d
```

### Rollback to Previous Version

```bash
cd /opt/multi-tenant-platform/deploy/apps/gabs-massage

# Rollback production to specific version
VERSION=v1.2.3 ENVIRONMENT=production docker compose up -d

# Or rollback staging
VERSION=v1.2.3 ENVIRONMENT=staging docker compose up -d
```

## Database Management

### Database Migrations

Migrations are automatically applied when the backend container starts (via Alembic).

**Manual migration execution:**
```bash
# Enter backend container
docker exec -it gabs-massage-backend-production bash

# View migration status
alembic current

# View migration history
alembic history --verbose

# Manually apply migrations (if needed)
alembic upgrade head

# Rollback one migration
alembic downgrade -1
```

### Database Backups

PostgreSQL database is managed by the platform-wide PostgreSQL instance.

**Manual backup:**
```bash
# Backup production database
docker exec postgres-platform pg_dump -U gabs_massage_user gabs_massage_production > \
  gabs-massage-backup-$(date +%Y%m%d-%H%M%S).sql

# Backup staging database
docker exec postgres-platform pg_dump -U gabs_massage_user gabs_massage_staging > \
  gabs-massage-staging-backup-$(date +%Y%m%d-%H%M%S).sql
```

**Restore from backup:**
```bash
# Stop backend containers first
ENVIRONMENT=production docker compose stop backend

# Restore production database
docker exec -i postgres-platform psql -U gabs_massage_user gabs_massage_production < \
  gabs-massage-backup-TIMESTAMP.sql

# Restart backend
ENVIRONMENT=production docker compose start backend
```

### Reset Staging Database

```bash
# Drop and recreate staging database
docker exec postgres-platform psql -U postgres << EOF
DROP DATABASE gabs_massage_staging;
CREATE DATABASE gabs_massage_staging OWNER gabs_massage_user;
GRANT ALL PRIVILEGES ON DATABASE gabs_massage_staging TO gabs_massage_user;
EOF

# Restart staging backend (migrations will run automatically)
ENVIRONMENT=staging docker compose restart backend
```

## Troubleshooting

### Backend container won't start

```bash
# Check backend logs
docker logs gabs-massage-backend-production

# Common issues:
# - Database connection failed (check DATABASE_URL)
# - Migration errors (check Alembic logs)
# - Missing environment variables
```

### Frontend container won't start

```bash
# Check frontend logs
docker logs gabs-massage-frontend-production

# Common issues:
# - Nginx configuration errors
# - Missing health endpoint
```

### Database connection errors

```bash
# Test database connectivity
docker exec gabs-massage-backend-production \
  python -c "from app.core.database import engine; engine.connect(); print('OK')"

# Check PostgreSQL is running
docker ps | grep postgres-platform

# Check database exists
docker exec postgres-platform psql -U postgres -c "\l" | grep gabs_massage
```

### API returns 502 Bad Gateway

```bash
# Check if backend is healthy
docker exec gabs-massage-backend-production curl http://localhost:3000/health

# Check nginx can reach backend
docker exec platform-nginx curl http://gabs-massage-backend-production:3000/health

# Check nginx config
docker exec platform-nginx nginx -t
```

### Migration errors

```bash
# View current migration state
docker exec gabs-massage-backend-production alembic current

# View migration history
docker exec gabs-massage-backend-production alembic history

# Force migration to specific version
docker exec gabs-massage-backend-production alembic upgrade <revision>

# If migrations are broken, may need to reset (⚠️ DANGER: loses data)
# Only do this on staging!
docker exec postgres-platform psql -U postgres << EOF
DROP DATABASE gabs_massage_staging;
CREATE DATABASE gabs_massage_staging OWNER gabs_massage_user;
EOF
ENVIRONMENT=staging docker compose restart backend
```

## Container Management

### View running containers

```bash
docker ps | grep gabs-massage
```

### Restart services

```bash
# Restart production backend only
docker restart gabs-massage-backend-production

# Restart production frontend only
docker restart gabs-massage-frontend-production

# Restart all production services
ENVIRONMENT=production docker compose restart

# Restart all staging services
ENVIRONMENT=staging docker compose restart
```

### View logs

```bash
# Follow production backend logs
docker logs -f gabs-massage-backend-production

# Follow production frontend logs
docker logs -f gabs-massage-frontend-production

# View last 100 lines
docker logs --tail 100 gabs-massage-backend-production
```

## Monitoring

### Health Checks

```bash
# Production
curl https://gabs-massage.de/health
curl https://gabs-massage.de/docs  # API documentation

# Staging
curl https://staging.gabs-massage.de/health
curl https://staging.gabs-massage.de/docs
```

### Container Stats

```bash
# View resource usage
docker stats gabs-massage-backend-production gabs-massage-frontend-production
```

## Development

For local development, see the main repository:
- **Repository:** https://github.com/duersjefen/gabs-massage
- **Local setup:** `make setup && make dev`
- **Documentation:** See `CLAUDE.md` and `README.md` in the repository

## Security Notes

- Change all default passwords before production deployment
- Keep `JWT_SECRET` and `SECRET_KEY` secure and different between environments
- Regularly update Docker images to get security patches
- Monitor logs for suspicious activity
- Use strong passwords for database and admin accounts

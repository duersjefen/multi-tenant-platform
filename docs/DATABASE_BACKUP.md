# Database Backup System

Complete guide to the PostgreSQL database backup and recovery system.

## 🎯 Overview

The platform uses a comprehensive database backup system with:
- **Point-in-time backups** using `pg_dump` (no corruption risk)
- **Automated daily backups** via cron
- **Weekly backup verification** to ensure restorability
- **Pre-deployment backups** for safe rollback
- **30-day retention** with automatic cleanup

## 📋 Architecture

### Backup Types

1. **Pre-Deployment Backups** - Created before every deployment
2. **Scheduled Daily Backups** - Automated nightly backups (2 AM UTC)
3. **Manual Backups** - On-demand backup creation

### Storage Structure

```
/opt/backups/
└── {project}/
    └── {environment}/
        ├── database/
        │   ├── db_20250106_020000.sql.gz
        │   ├── db_20250107_020000.sql.gz
        │   └── ...
        ├── backup_20250106_120000.meta
        └── ...
```

### Backup Format

- **Format:** PostgreSQL custom format (`pg_dump --format=custom`)
- **Compression:** gzip (level 9)
- **Size:** Typically 10-100x smaller than raw SQL
- **Restorability:** Can restore to different PostgreSQL versions

## 🔧 Configuration

### projects.yml

Add database configuration to each project:

```yaml
filter-ical:
  # ... other config ...

  database:
    type: postgresql
    container: postgres-platform
    databases:
      production: filterical_production
      staging: filterical_staging
    user: filterical_user

    backup:
      enabled: true
      retention_days: 30
      verify_on_restore: true
```

**Parameters:**
- `type`: Database type (currently only `postgresql` supported)
- `container`: Docker container name for PostgreSQL
- `databases`: Map of environment → database name
- `user`: PostgreSQL user for backups
- `backup.enabled`: Enable/disable backups for this database
- `backup.retention_days`: How long to keep backups (default: 30)
- `backup.verify_on_restore`: Verify backups after restoration (default: true)

## 🚀 Usage

### Manual Backup

```bash
cd /opt/multi-tenant-platform
source lib/functions/backup.sh

# Backup specific database
backup_database filter-ical production

# Returns path to backup file
# /opt/backups/filter-ical/production/database/db_20250106_153045.sql.gz
```

### Manual Restore

```bash
cd /opt/multi-tenant-platform
source lib/functions/backup.sh

# Restore from specific backup
restore_database filter-ical production \
  /opt/backups/filter-ical/production/database/db_20250106_020000.sql.gz
```

**⚠️ WARNING:** This will DROP and recreate the database!

### Scheduled Backups

Run all configured database backups:

```bash
./lib/scheduled-backup.sh

# Dry run (test without actual backup)
./lib/scheduled-backup.sh --dry-run
```

**Cron Setup:**
```bash
# Add to crontab (daily at 2 AM UTC)
0 2 * * * /opt/multi-tenant-platform/lib/scheduled-backup.sh
```

### Backup Verification

Verify backups are restorable:

```bash
./lib/verify-backups.sh

# Verify specific backup
./lib/verify-backups.sh filter-ical production

# Dry run
./lib/verify-backups.sh --dry-run
```

**Cron Setup:**
```bash
# Add to crontab (weekly on Sunday at 3 AM UTC)
0 3 * * 0 /opt/multi-tenant-platform/lib/verify-backups.sh
```

## 📊 Monitoring

### View Deployment Manifest

Deployment manifests track which database backup was created:

```bash
./lib/deployment-status.sh filter-ical production
```

Output includes:
```json
{
  "backup": "backup_20250106_120000",
  "database_backup": "/opt/backups/.../db_20250106_120000.sql.gz"
}
```

### Check Backup Status

```bash
# List all database backups
ls -lh /opt/backups/filter-ical/production/database/

# Check backup size and age
du -h /opt/backups/filter-ical/production/database/
find /opt/backups/filter-ical/production/database/ -name "*.sql.gz" -mtime -7
```

### Verify Latest Backup

```bash
# Quick verification
./lib/verify-backups.sh filter-ical production
```

## 🆘 Disaster Recovery

### Scenario 1: Bad Deployment (Recent)

If deployment just happened and broke the database:

```bash
# 1. Check deployment manifest for backup
./lib/deployment-status.sh filter-ical production

# 2. Rollback will automatically restore database
cd /opt/multi-tenant-platform
source lib/functions/backup.sh
LATEST=$(get_latest_backup filter-ical production)
restore_backup filter-ical production $LATEST

# This restores both containers AND database
```

### Scenario 2: Data Corruption (Need Specific Backup)

```bash
# 1. List available backups
ls -lht /opt/backups/filter-ical/production/database/

# 2. Restore specific backup
cd /opt/multi-tenant-platform
source lib/functions/backup.sh
restore_database filter-ical production \
  /opt/backups/filter-ical/production/database/db_20250105_020000.sql.gz
```

### Scenario 3: Complete Data Loss

```bash
# 1. Find latest verified backup
./lib/verify-backups.sh filter-ical production

# 2. Restore from latest backup
cd /opt/multi-tenant-platform
source lib/functions/backup.sh

LATEST_DB_BACKUP=$(ls -t /opt/backups/filter-ical/production/database/*.sql.gz | head -1)
restore_database filter-ical production "$LATEST_DB_BACKUP"

# 3. Verify restoration
docker exec postgres-platform psql -U filterical_user -d filterical_production -c "\dt"
```

## 🔍 Troubleshooting

### Backup Fails: "Database container not found"

**Problem:** PostgreSQL container not running

**Solution:**
```bash
# Check if postgres container is running
docker ps | grep postgres-platform

# Start if not running
docker compose -f platform/docker-compose.database.yml up -d
```

### Backup Fails: "pg_dump: error: connection failed"

**Problem:** Database doesn't exist or wrong credentials

**Solution:**
```bash
# List databases
docker exec postgres-platform psql -U admin -l

# Check environment file has correct DATABASE_URL
cat /opt/multi-tenant-platform/configs/filter-ical/.env.production | grep DATABASE_URL
```

### Restore Fails: "database is being accessed by other users"

**Problem:** Application still connected to database

**Solution:**
```bash
# Stop application containers first
docker stop filter-ical-backend-production

# Then restore
restore_database filter-ical production backup.sql.gz

# Restart application
docker start filter-ical-backend-production
```

### Backup Verification Fails

**Problem:** Backup file may be corrupted

**Solution:**
```bash
# Check backup file integrity
zcat /opt/backups/filter-ical/production/database/db_20250106_020000.sql.gz | head -100

# If corrupted, use previous backup
ls -lht /opt/backups/filter-ical/production/database/ | head -5
```

### Disk Space Issues

**Problem:** Backups filling up disk

**Solution:**
```bash
# Check disk usage
df -h /opt/backups

# Reduce retention period in projects.yml
# retention_days: 30 → 14

# Manual cleanup (older than 14 days)
find /opt/backups -name "db_*.sql.gz" -mtime +14 -delete
```

## 🔐 Security

### Backup Permissions

```bash
# Backups are stored with restrictive permissions
chmod 600 /opt/backups/*/database/*.sql.gz
chown root:root /opt/backups/*/database/*.sql.gz
```

### Encryption (Optional)

For extra security, encrypt backups:

```bash
# Encrypt backup
gpg --symmetric --cipher-algo AES256 backup.sql.gz

# Decrypt for restore
gpg --decrypt backup.sql.gz.gpg | restore_database ...
```

### Off-site Backups (Recommended)

Sync backups to S3/external storage:

```bash
# Example: S3 sync (add to cron after daily backup)
aws s3 sync /opt/backups/ s3://my-backup-bucket/platform-backups/ \
  --storage-class GLACIER \
  --exclude "*" \
  --include "*/database/*.sql.gz"
```

## 📈 Best Practices

### 1. Regular Verification

- **Weekly:** Automated verification via cron
- **Monthly:** Manual spot-check of random backup
- **Quarterly:** Full disaster recovery drill

### 2. Retention Strategy

- **Daily backups:** 30 days
- **Weekly backups:** 12 weeks (offsite)
- **Monthly backups:** 12 months (offsite, Glacier)

### 3. Pre-Deployment

- **Always backup before migrations**
- **Verify backup completed before proceeding**
- **Keep backup until deployment verified**

### 4. Monitoring

- **Alert on backup failure**
- **Alert on verification failure**
- **Alert on disk space < 10GB**

### 5. Testing

```bash
# Monthly drill: Restore backup to test environment
1. Create test database
2. Restore latest backup
3. Run smoke tests
4. Verify data integrity
5. Drop test database
```

## 📚 Technical Details

### pg_dump Options

```bash
pg_dump \
  -U filterical_user \      # Database user
  filterical_production \    # Database name
  --format=custom \          # Custom format (compressed, flexible)
  --compress=9 \             # Maximum compression
  --verbose                  # Show progress
```

**Why custom format?**
- Compressed by default
- Can restore individual tables
- Can restore to different PostgreSQL versions
- Includes schema and data

### Backup Process Flow

```
1. Read projects.yml for database config
2. Verify database container is running
3. Create backup directory
4. Run pg_dump with compression
5. Verify backup file size > 100 bytes
6. Return backup file path
7. Track in deployment manifest
```

### Restore Process Flow

```
1. Verify backup file exists
2. Read database config from projects.yml
3. Stop application containers
4. DROP existing database (⚠️)
5. CREATE new database
6. pg_restore from backup
7. Verify restoration success
8. Restart application containers
```

### Verification Process

```
1. Find latest backup
2. Create temporary test database
3. Restore backup to test database
4. Query table count
5. Query row count
6. DROP test database
7. Report success/failure
```

## 🔄 Migration from Volume Backups

If you previously used volume backups:

```bash
# Old method (risky):
docker run --rm \
  -v postgres-data:/volume \
  alpine tar czf backup.tar.gz /volume

# New method (safe):
backup_database filter-ical production
```

**Advantages of pg_dump:**
- ✅ Point-in-time consistent
- ✅ No corruption risk
- ✅ Cross-version compatible
- ✅ Smaller file size
- ✅ Verifiable restore

## 📞 Support

**Backup Issues:**
1. Check logs: `tail -f /var/log/cron.log`
2. Test manual backup: `backup_database filter-ical production`
3. Verify database connectivity: `docker exec postgres-platform psql -U admin -l`

**Restore Issues:**
1. Ensure application stopped
2. Check backup file integrity
3. Verify PostgreSQL version compatibility
4. Check disk space

**Emergency:**
- Latest backup always at: `/opt/backups/{project}/{env}/database/`
- Deployment manifests track all backups
- Weekly verification ensures restorability

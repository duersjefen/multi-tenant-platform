# Platform-Driven Deployment Architecture

Complete guide to the multi-tenant platform deployment system.

---

## 🎯 Architecture Principles

### **Core Principle: Platform Repo is Source of Truth**

```
Application Repos (Passive)          Platform Repo (Active Orchestrator)
├── Code                            ├── Deployment configs
├── Dockerfile                      ├── Environment variables
└── Build images                    └── Orchestrates deployment
    ↓ Notify                            ↓ Deploys
    Platform                            All projects
```

**Key Insight:** Applications build images. Platform decides when and how to run them.

---

## 📋 How It Works

### 1. Application Code Changes

**Developer pushes to filter-ical/main:**
```bash
cd filter-ical
git commit -m "Add new feature"
git push origin main
```

**What happens:**
1. GitHub Actions builds Docker images
2. Images pushed to ghcr.io
3. **Platform repo notified** via repository_dispatch
4. Platform deploys to staging automatically
5. Production requires manual approval

### 2. Configuration Changes

**Developer changes docker-compose.yml or env files:**
```bash
cd multi-tenant-platform
# Edit configs/filter-ical/docker-compose.yml
git commit -m "Update health check settings"
git push origin main
```

**What happens:**
1. GitHub Actions detects config change
2. Platform redeploys affected projects to staging
3. Production requires manual approval

### 3. Manual Deployment

**Force a deployment:**
```bash
cd multi-tenant-platform
make deploy project=filter-ical env=staging
```

---

## 🚀 Deployment Commands

### Via Makefile (Recommended)

```bash
# Deploy project to environment
make deploy project=filter-ical env=staging

# Redeploy with current configs (fast)
make redeploy project=filter-ical env=staging

# Trigger via GitHub Actions
make trigger-deploy project=filter-ical env=staging

# Promote staging → production
make promote project=filter-ical

# Check deployment status
make deployment-status project=filter-ical env=staging
```

### Via GitHub Actions

```bash
# Trigger deployment
gh workflow run deploy-project.yml \
  -f project=filter-ical \
  -f environment=staging \
  --repo duersjefen/multi-tenant-platform

# Monitor
gh run list --repo duersjefen/multi-tenant-platform
```

---

## 🔄 Complete Workflow Examples

### Scenario 1: Deploy Code Change

```bash
# 1. Make code changes
cd ~/Desktop/filter-ical
vim backend/app/main.py

# 2. Commit and push
git add .
git commit -m "Add new API endpoint"
git push origin main

# 3. Automatic pipeline:
#    ✅ Build images (filter-ical repo)
#    ✅ Notify platform (repository_dispatch)
#    ✅ Deploy to staging (platform repo)
#    ⏸️  Production (requires approval)

# 4. Approve production (if staging looks good)
cd ~/Desktop/multi-tenant-platform
make promote project=filter-ical
```

### Scenario 2: Deploy Config Change

```bash
# 1. Make config changes
cd ~/Desktop/multi-tenant-platform
vim configs/filter-ical/docker-compose.yml

# 2. Commit and push
git add .
git commit -m "Standardize health checks"
git push origin main

# 3. Automatic pipeline:
#    ✅ Detect config change (platform repo)
#    ✅ Deploy to staging
#    ⏸️  Production (requires approval)
```

### Scenario 3: Emergency Rollback

```bash
cd ~/Desktop/multi-tenant-platform

# Quick rollback via deployment system
ssh ec2
cd /opt/multi-tenant-platform
source lib/functions/backup.sh
LATEST=$(get_latest_backup filter-ical production)
restore_backup filter-ical production $LATEST
```

---

## 📁 Repository Structure

### filter-ical (Application Repo)

```
filter-ical/
├── backend/
│   ├── app/
│   └── Dockerfile          ← Defines what to run
├── frontend/
│   ├── src/
│   └── Dockerfile          ← Defines what to run
└── .github/workflows/
    └── build-and-push.yml  ← Builds + notifies platform
```

**Responsibility:** Define the application

### multi-tenant-platform (Platform Repo)

```
multi-tenant-platform/
├── configs/filter-ical/
│   ├── docker-compose.yml  ← Defines HOW to run
│   ├── .env.staging        ← Staging configuration
│   └── .env.production     ← Production configuration
├── lib/
│   └── deploy.sh           ← Deployment orchestration
├── .github/workflows/
│   └── deploy-project.yml  ← Deployment automation
└── Makefile                ← Manual operations
```

**Responsibility:** Orchestrate all deployments

---

## 🎭 Deployment Environments

### Staging
- **URL:** https://staging.filter-ical.de
- **Auto-deploy:** On code or config changes
- **Purpose:** Test changes before production

### Production
- **URL:** https://filter-ical.de
- **Manual approval:** Required via GitHub
- **Purpose:** Live user-facing environment

---

## 🔐 Required GitHub Secrets

### filter-ical repo:
- `PLATFORM_DEPLOY_TOKEN` - Personal access token to trigger platform workflows

### multi-tenant-platform repo:
- `EC2_SSH_PRIVATE_KEY` - SSH key for server access
- `EC2_HOST` - Server IP/hostname
- `EC2_USER` - SSH username
- `GHCR_TOKEN` - GitHub Container Registry token

---

## 🛠️ Setup Instructions

### 1. Create Platform Deploy Token

```bash
# Generate token with workflow permissions
gh auth login
gh auth token

# Add to filter-ical repo secrets
gh secret set PLATFORM_DEPLOY_TOKEN --repo duersjefen/filter-ical
```

### 2. Enable Repository Dispatch

Platform repo must allow repository_dispatch events (already enabled by workflow).

### 3. Test the Pipeline

```bash
# Test config change deployment
cd multi-tenant-platform
echo "# Test change" >> configs/filter-ical/docker-compose.yml
git add .
git commit -m "Test: Platform-driven deployment"
git push origin main

# Monitor
gh run list --repo duersjefen/multi-tenant-platform
```

---

## 📊 Monitoring Deployments

### View Active Workflows

```bash
# Platform deployments
gh run list --repo duersjefen/multi-tenant-platform

# App builds
gh run list --repo duersjefen/filter-ical
```

### Check Container Status

```bash
cd multi-tenant-platform
make status
make health
```

### View Deployment Manifest

```bash
cd multi-tenant-platform
make deployment-status project=filter-ical env=staging
```

---

## 🚨 Troubleshooting

### Deployment Not Triggered

**Symptom:** Pushed to filter-ical, but staging not deploying

**Check:**
```bash
# 1. Verify PLATFORM_DEPLOY_TOKEN exists
gh secret list --repo duersjefen/filter-ical

# 2. Check if build workflow ran
gh run list --repo duersjefen/filter-ical -L 5

# 3. Check platform workflow triggered
gh run list --repo duersjefen/multi-tenant-platform -L 5
```

### Health Check Failing

**Symptom:** Deployment fails at health check step

**Solution:**
```bash
# 1. SSH to server and check logs
cd multi-tenant-platform
make ssh

# On server:
docker logs filter-ical-backend-staging
docker logs filter-ical-frontend-staging

# 2. Check health endpoints
curl http://localhost:3000/health  # Backend
curl http://localhost/health       # Frontend
```

### Manual Deployment Needed

**Force deployment:**
```bash
cd multi-tenant-platform
make deploy project=filter-ical env=staging
```

---

## 🎓 Best Practices

### 1. Always Test on Staging First
```bash
# ✅ CORRECT: Automatic staging deployment
git push origin main  # Deploys to staging automatically

# Then promote if successful
make promote project=filter-ical
```

### 2. Use Descriptive Commit Messages
```bash
# ✅ GOOD
git commit -m "Fix: Standardize health check format for reliability"

# ❌ BAD
git commit -m "update stuff"
```

### 3. Monitor Deployments
```bash
# Always check deployment succeeded
gh run list --repo duersjefen/multi-tenant-platform -L 1
make deployment-status project=filter-ical env=staging
```

### 4. Document Config Changes
```yaml
# ✅ GOOD: Comment explains why
healthcheck:
  test: ["CMD-SHELL", "curl -f http://localhost/health || exit 1"]
  retries: 3  # Industry standard, faster failure detection
```

---

## 🔄 Migration from Old System

### Old Way (filter-ical controls deployment):
```bash
cd filter-ical
make deploy-staging  # Deploys from app repo
```

### New Way (platform controls deployment):
```bash
cd filter-ical
git push origin main  # Platform deploys automatically

# OR manual:
cd multi-tenant-platform
make deploy project=filter-ical env=staging
```

### Coexistence Period

Both systems work during migration:
- Old workflows still exist in filter-ical (will be deprecated)
- New platform-driven system is now primary
- Once stable, remove old filter-ical deployment workflows

---

## 📈 Benefits of This Architecture

1. **Separation of Concerns**
   - Apps focus on code
   - Platform focuses on deployment

2. **Configuration Changes Deployable**
   - No need to rebuild images for config changes
   - Fast iteration on infrastructure

3. **Consistent Deployment**
   - All projects deploy the same way
   - Easy to add new projects

4. **GitOps Compliance**
   - Git is source of truth
   - Audit trail in git history

5. **Scalability**
   - Works for 3 projects or 300 projects
   - Add new projects by copying configs

---

## 🚀 Future Enhancements

- **Canary Deployments:** Deploy to 10% of prod before full rollout
- **Blue-Green Deployments:** Zero-downtime production switches
- **Automated Rollback:** Auto-rollback on error rate increase
- **Slack Notifications:** Notify team of deployments
- **Deployment Dashboard:** Web UI for deployment status

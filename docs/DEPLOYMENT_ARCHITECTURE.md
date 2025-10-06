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

## 📋 How It Works - Continuous Deployment Pipeline

### 🎯 **Core Concept: Staging → Auto-Queue Production → Approve → Deploy**

Every change flows through the same continuous pipeline with a manual approval gate before production.

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
4. Platform deploys to **staging** automatically ✅
5. Production deployment **auto-queues** ⏸️
6. Click "Approve" in GitHub → deploys to **production** ✅

**Complete pipeline:** `Push → Build → Staging ✅ → [Approve] → Production ✅`

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
2. Platform redeploys affected projects to **staging** ✅
3. Production deployment **auto-queues** ⏸️
4. Click "Approve" in GitHub → deploys to **production** ✅

**Complete pipeline:** `Config Change → Staging ✅ → [Approve] → Production ✅`

### 3. Manual Deployment (Emergency Override)

**Force immediate deployment (skips auto-queue):**
```bash
cd multi-tenant-platform
make deploy project=filter-ical env=production
```

**Use case:** Emergency hotfixes that need immediate production deployment

---

## 🚀 Deployment Commands

### Primary Commands (Normal Workflow)

```bash
# 1. Push code (triggers continuous deployment)
cd filter-ical
git push origin main
# → Automatically deploys to staging
# → Auto-queues production (requires approval)

# 2. Approve production deployment
cd multi-tenant-platform
make approve-production project=filter-ical
# → Interactively lists pending deployments
# → Prompts for approval

# Check deployment status
make deployment-status project=filter-ical env=staging
make deployment-status project=filter-ical env=production
```

### Alternative Commands (Manual Control)

```bash
# Force immediate staging deployment (bypasses git push)
make deploy project=filter-ical env=staging
# → Deploys to staging
# → Auto-queues production

# Force immediate production deployment (EMERGENCY ONLY)
make deploy project=filter-ical env=production
# → Bypasses approval gate
# → Deploys directly to production

# Trigger via GitHub Actions (same as manual deploy)
make trigger-deploy project=filter-ical env=staging
# → Deploys via workflow
# → Auto-queues production

# Promote staging config to production
make promote project=filter-ical
# → Copies .env.staging → .env.production
# → Commits and pushes
# → Triggers continuous deployment pipeline
```

### Via GitHub UI (Simplest for Approval)

1. Visit: https://github.com/duersjefen/multi-tenant-platform/actions
2. Click on "Deploy Project" workflow run
3. Click "Review deployments"
4. Approve "production" environment
5. Watch deployment complete

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

# 3. Automatic pipeline starts:
#    ✅ Build images (filter-ical repo)
#    ✅ Notify platform (repository_dispatch)
#    ✅ Deploy to staging (platform repo)
#    ⏸️  Production auto-queued (waiting for approval)

# 4. Test staging
curl https://staging.filter-ical.de

# 5. Approve production (if staging looks good)
cd ~/Desktop/multi-tenant-platform
make approve-production project=filter-ical
# → Lists pending deployments
# → Enter run ID to approve
# → Watches deployment complete

# 6. Verify production
curl https://filter-ical.de
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
#    ⏸️  Production auto-queued (waiting for approval)

# 4. Approve when ready
make approve-production project=filter-ical
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

## 🔄 Continuous Deployment Benefits

### Compared to Manual Promotion:

**Old Manual Flow:**
```
Push → Staging ✅ → make promote → Staging ✅ → Approve → Production ✅
```
*Requires 2 staging deployments, manual config copy, extra commits*

**New Continuous Flow:**
```
Push → Staging ✅ → Approve → Production ✅
```
*Single staging deployment, instant approval, no extra commits*

### Why This Is Better:

1. **Faster**: No duplicate staging deployment
2. **Simpler**: No manual config copying
3. **Cleaner**: No "promote" commits cluttering history
4. **Industry Standard**: How CI/CD should work
5. **Better Visibility**: All deployments visible in GitHub Actions

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

## 🔐 GitHub Environment Setup

### Required for Approval Workflow

The continuous deployment pipeline requires GitHub environments with protection rules.

**Setup production environment:**

1. Go to: https://github.com/duersjefen/multi-tenant-platform/settings/environments
2. Click "New environment" → Name: `production`
3. Enable "Required reviewers" → Add team members
4. Save protection rules

**Staging environment (optional):**
- Can add for visibility but approval not required
- Shows deployment URL in workflow runs

### Environment Configuration

```yaml
# In .github/workflows/deploy-project.yml
environment:
  name: production  # Matches GitHub environment name
  url: https://${{ matrix.project }}.de  # Shows in GitHub UI
```

When staging succeeds, production job auto-queues and waits for approval from configured reviewers.

---

## 🚀 Future Enhancements

- **Multiple Approvers:** Require 2+ approvals for production
- **Deployment Windows:** Only allow deployments during business hours
- **Canary Deployments:** Deploy to 10% of prod before full rollout
- **Automated Rollback:** Auto-rollback on error rate increase
- **Slack Notifications:** Notify team of deployments and approvals

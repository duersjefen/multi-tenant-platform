# Multi-Tenant Deployment Platform

> 🎉 **Production-grade infrastructure for deploying multiple applications on a single server**

This is a **universal deployment platform** that can host multiple applications with zero-downtime deployments, comprehensive monitoring, and automatic rollback.

## 🏗️ What is This?

A **pure infrastructure repository** that:

- ✅ **Deploys any application** from any repository
- ✅ **Shared infrastructure** (one nginx, one monitoring stack for all apps)
- ✅ **Universal deployment scripts** (`./lib/deploy.sh <project> <environment>`)
- ✅ **Blue-green deployments** with automatic rollback
- ✅ **Comprehensive monitoring** (Prometheus + Grafana + Alertmanager)
- ✅ **Copy-paste ready** for new projects

**This repo does NOT contain application code** - only deployment infrastructure and configs.

## 📁 Structure

```
/
├── platform/              # Shared infrastructure (nginx, monitoring)
│   ├── docker-compose.platform.yml
│   ├── nginx/
│   ├── monitoring/
│   └── scripts/
│
├── lib/                   # Universal deployment scripts
│   ├── deploy.sh         # Main deployment orchestration
│   ├── rollback.sh       # Rollback to backup
│   ├── health-check.sh   # Health validation
│   └── functions/        # Reusable bash functions
│
├── configs/              # Per-app deployment configurations
│   └── filter-ical/      # Example: filter-ical app config
│       ├── docker-compose.yml    # References app images
│       ├── .env.production       # Production settings
│       ├── .env.staging         # Staging settings
│       └── nginx.conf           # App-specific routing
│
├── config/
│   └── projects.yml      # ⭐ Project registry (all apps)
│
└── docs/                 # Platform documentation
    ├── README.md
    ├── ARCHITECTURE.md
    ├── ADDING_A_PROJECT.md
    ├── DEPLOYMENT_GUIDE.md
    └── TROUBLESHOOTING.md
```

## 🚀 Quick Start

### Deploy an Application

```bash
# Deploy to production
./lib/deploy.sh filter-ical production

# Check health
./lib/health-check.sh filter-ical production

# Rollback if needed
./lib/rollback.sh filter-ical production
```

### Add New Application

```bash
# 1. Add to project registry
vim config/projects.yml

# 2. Create deployment config
mkdir -p configs/my-app
cp -r configs/filter-ical/* configs/my-app/
# Edit configs/my-app/* for your app

# 3. Deploy
./lib/deploy.sh my-app production
```

## 📚 Documentation

- **[docs/README.md](docs/README.md)** - Platform overview and quick start
- **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)** - How the platform works
- **[docs/ADDING_A_PROJECT.md](docs/ADDING_A_PROJECT.md)** - Add new applications
- **[docs/DEPLOYMENT_GUIDE.md](docs/DEPLOYMENT_GUIDE.md)** - Deployment procedures
- **[docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)** - Common issues

## 🎯 Hosted Applications

Current applications on this platform:

### filter-ical (iCal Viewer & Filter)
- **App Repository**: https://github.com/duersjefen/filter-ical
- **Production**: https://filter-ical.de
- **Staging**: https://staging.filter-ical.de
- **Config**: `configs/filter-ical/`

## 🔧 Key Features

### Universal Deployment
- One script works for ALL applications
- No hard-coding - everything configured in `config/projects.yml`
- Apps can be in ANY repository

### Zero-Downtime Deployments
- Blue-green deployment strategy
- Deploy → Validate → Switch traffic → Success!
- Automatic rollback on failure

### Production Safety
- Pre-flight validation (disk space, images, configs)
- Automatic backups before every deployment
- Health checks with proper warmup periods
- Auto-rollback if anything fails

### Monitoring
- **Prometheus** scrapes metrics from all applications
- **Grafana** visualizes with auto-provisioned dashboards
- **Alertmanager** sends notifications (email/Slack/PagerDuty)
- Built-in alerts for downtime, errors, slow responses

### SSL Certificate Management
- **Automatic provisioning** via Let's Encrypt
- **Multi-domain certificates** for production domains (e.g., `example.com` + `www.example.com`)
- **Smart detection** - only requests missing certificates
- **Placeholder certificates** for local/pre-DNS environments
- **Zero-downtime renewal** via certbot cron jobs

```bash
# Provision all missing SSL certificates
make provision-ssl

# Preview what would be provisioned (dry-run)
make provision-ssl-dry-run

# Force renewal of all certificates
ssh server "cd /opt/multi-tenant-platform && ./lib/provision-ssl-certs.sh --force"
```

**How it works:**
1. Script reads all domains from `config/projects.yml`
2. Groups production domains together (e.g., `domain.com,www.domain.com`)
3. Checks which certificates exist (skips existing valid certs)
4. Requests multi-domain Let's Encrypt certificates via HTTP-01 challenge
5. Falls back to self-signed placeholders if DNS not configured yet

**Certificate storage:**
- Production domains: `/etc/letsencrypt/live/primary-domain/` (covers all SANs)
- Staging domains: Separate certificates per environment
- Nginx automatically uses primary domain path for all aliases

## 🌟 Architecture Principles

This platform follows industry best practices:

1. **Separation of Concerns**: Infrastructure repo vs application repos
2. **Infrastructure as Code**: Everything configured, nothing manual
3. **Immutable Deployments**: Deploy new, validate, switch traffic
4. **Observable Systems**: Monitoring built-in from day one
5. **Fail-Safe Defaults**: Auto-rollback, health checks, validations

## 🔄 Workflow

### For Application Developers

1. **Develop** in your app repository (e.g., `ical-viewer`)
2. **Build** Docker images and push to registry
3. **Deploy** using platform scripts: `./lib/deploy.sh my-app production`

### For Platform Maintainers

1. **Configure** new apps in `configs/`
2. **Register** apps in `config/projects.yml`
3. **Monitor** all apps through shared Grafana dashboards

## 📊 Stats

- **Platform files**: 28 infrastructure and script files
- **Documentation**: 95+ pages of comprehensive guides
- **Deployment time**: ~2 minutes (with health checks)
- **Rollback time**: ~30 seconds
- **Zero downtime**: Yes (blue-green deployments)

## 🎓 Example: Deploying filter-ical

```bash
# The platform pulls images from the app repo's registry

# Deploy latest version
./lib/deploy.sh filter-ical production

# Deploy specific version
echo "VERSION=v1.2.3" > configs/filter-ical/.env.production
./lib/deploy.sh filter-ical production

# The script automatically:
# 1. Pulls ghcr.io/duersjefen/filter-ical-backend:v1.2.3
# 2. Pulls ghcr.io/duersjefen/filter-ical-frontend:v1.2.3
# 3. Deploys to inactive environment (blue or green)
# 4. Validates health checks
# 5. Switches traffic
# 6. Success! (or auto-rollback on failure)
```

## 🌟 Netflix-Ready

This architecture implements patterns used by companies like Netflix:

- ✅ Infrastructure as Code
- ✅ Blue-Green Deployments
- ✅ Health Checks with warmup periods
- ✅ Monitoring & Alerting
- ✅ Automatic Rollback
- ✅ Immutable Infrastructure

---

**Ready to deploy?** Start with [docs/README.md](docs/README.md)
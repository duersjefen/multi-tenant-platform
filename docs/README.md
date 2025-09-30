# Multi-Tenant Deployment Platform

> Production-grade, copy-paste infrastructure for deploying multiple applications on a single server

## 🎯 What is This?

This is a **universal deployment platform** that allows you to run multiple applications on a single EC2 instance with:

- **One nginx** for all projects
- **One monitoring stack** (Prometheus + Grafana) for all projects
- **Universal deployment scripts** that work for any project
- **Blue-green deployments** with automatic rollback
- **SSL certificates** via Let's Encrypt
- **Health checks** and **automatic backups**

## 🚀 Quick Start

### Adding a New Project

1. **Edit the project registry**:
   ```bash
   vim /deploy/config/projects.yml
   ```

2. **Add your project** (copy the template):
   ```yaml
   my-new-app:
     name: "My New Application"
     repository: "https://github.com/user/my-new-app"
     domains:
       production:
         - my-app.com
     # ... see template for full structure
   ```

3. **Generate nginx config**:
   ```bash
   ./deploy/lib/generate-nginx-config.sh my-new-app
   ```

4. **Deploy**:
   ```bash
   ./deploy/lib/deploy.sh my-new-app production
   ```

Done! Your app is live with SSL, monitoring, and health checks.

## 📁 Directory Structure

```
/deploy/
├── platform/              # Shared infrastructure
│   ├── docker-compose.platform.yml
│   ├── nginx/            # Main nginx config
│   ├── monitoring/       # Prometheus, Grafana, Alertmanager
│   └── scripts/          # Platform maintenance scripts
│
├── apps/                 # Per-project configurations
│   └── filter-ical/
│       ├── docker-compose.yml
│       ├── .env.production
│       └── .env.staging
│
├── lib/                  # Universal deployment scripts
│   ├── deploy.sh        # Main deployment script
│   ├── rollback.sh      # Rollback script
│   ├── health-check.sh  # Health check script
│   └── functions/       # Reusable bash functions
│
├── config/
│   └── projects.yml     # ⭐ PROJECT REGISTRY (the heart of the system)
│
├── templates/           # Copy-paste starter for new projects
│   └── new-app/
│
└── docs/                # Documentation (you are here)
    ├── README.md
    ├── ARCHITECTURE.md
    ├── ADDING_A_PROJECT.md
    ├── DEPLOYMENT_GUIDE.md
    └── TROUBLESHOOTING.md
```

## 🔧 Key Commands

### Deployment
```bash
# Deploy to production
./deploy/lib/deploy.sh filter-ical production

# Deploy to staging
./deploy/lib/deploy.sh filter-ical staging

# Deploy with options
./deploy/lib/deploy.sh filter-ical production --skip-backup
./deploy/lib/deploy.sh filter-ical production --force
```

### Rollback
```bash
# Rollback to latest backup
./deploy/lib/rollback.sh filter-ical production

# Rollback to specific backup
./deploy/lib/rollback.sh filter-ical production backup_20250930_143000
```

### Health Checks
```bash
# Check application health
./deploy/lib/health-check.sh filter-ical production

# Check platform health
docker ps
curl http://localhost/nginx-health
```

### Monitoring
```bash
# View Grafana
open https://monitoring.filter-ical.de
# Login: admin / [see .env]

# View Prometheus
ssh ec2 -L 9090:localhost:9090
open http://localhost:9090

# View logs
docker logs filter-ical-backend
docker logs filter-ical-frontend
docker logs platform-nginx
```

## 🏗️ Architecture

### How It Works

1. **Central Registry** (`projects.yml`):
   - Defines ALL projects on the platform
   - Specifies domains, containers, health checks, monitoring

2. **Universal Scripts**:
   - Scripts read `projects.yml` for configuration
   - No hard-coding - works for ANY project

3. **Shared Infrastructure**:
   - One nginx routes to all apps
   - One monitoring stack tracks all apps
   - Each app has isolated containers

4. **Deployment Flow**:
   ```
   Pre-flight Validation
   → Create Backup
   → Pull New Images
   → Deploy (blue-green or direct)
   → Health Check
   → Switch Traffic (if blue-green)
   → Success! (or auto-rollback on failure)
   ```

### Key Benefits

- **Copy-paste reusability**: Add new projects in minutes
- **Zero hard-coding**: Everything configured via `projects.yml`
- **Production-ready**: Health checks, backups, rollbacks, monitoring
- **Cost-efficient**: Multiple apps on one server
- **Safe deployments**: Validation before touching production

## 📚 Documentation

- **[ARCHITECTURE.md](./ARCHITECTURE.md)** - Deep dive into how the platform works
- **[ADDING_A_PROJECT.md](./ADDING_A_PROJECT.md)** - Step-by-step guide to add new apps
- **[DEPLOYMENT_GUIDE.md](./DEPLOYMENT_GUIDE.md)** - Comprehensive deployment guide
- **[TROUBLESHOOTING.md](./TROUBLESHOOTING.md)** - Common issues and solutions

## 🎓 Example: filter-ical

The **filter-ical** project is configured as a reference example:

- **Docker Compose**: `/deploy/apps/filter-ical/docker-compose.yml`
- **Nginx Config**: `/deploy/platform/nginx/conf.d/filter-ical.conf`
- **Registry Entry**: `/deploy/config/projects.yml` (lines 20-119)

Study this configuration to understand how projects are structured.

## 🌟 Next Steps

1. **Read** [ADDING_A_PROJECT.md](./ADDING_A_PROJECT.md)
2. **Copy** the template from `/deploy/templates/new-app/`
3. **Configure** your project in `projects.yml`
4. **Deploy** with `./deploy/lib/deploy.sh`

Welcome to production-grade deployment!
# Multi-Tenant Platform

**Simplified infrastructure for hosting multiple web applications**

This platform provides shared nginx reverse proxy, PostgreSQL database, and SSL automation (Let's Encrypt) for hosting multiple applications on a single EC2 instance.

## 🎯 Design Philosophy

**Simple. Static. Reliable.**

- ✅ **No GitHub Actions complexity** - Deploy via SSM from your local machine
- ✅ **No image registry** - Builds happen on server from git repos
- ✅ **Static nginx configs** - No auto-generation scripts, just simple .conf files
- ✅ **App-based deployment** - Each app manages its own deployment
- ✅ **Minimal dependencies** - Just Docker, nginx, postgres, certbot

## 🏗️ Architecture

```
┌─────────────────────────────────────────────────────────┐
│ EC2 Instance (Amazon Linux 2023 / t3.medium)           │
│                                                         │
│  ┌──────────────────────────────────────────────────┐  │
│  │ Platform (this repo)                             │  │
│  │  - nginx (reverse proxy)                         │  │
│  │  - postgres (shared database)                    │  │
│  │  - certbot (SSL automation)                      │  │
│  └──────────────────────────────────────────────────┘  │
│                                                         │
│  ┌──────────────────────────────────────────────────┐  │
│  │ Apps (deployed separately via SSM)               │  │
│  │  - paiss-production, paiss-staging               │  │
│  │  - filter-ical-backend + frontend                │  │
│  │  - gabs-massage-web                              │  │
│  └──────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────┘
```

## 📦 What's Included

- **Nginx** - Reverse proxy with SSL, HTTP/2, HTTP/3, rate limiting, security headers
- **PostgreSQL** - Shared database for all apps (separate databases per app)
- **Certbot** - Automatic SSL certificate generation and renewal
- **Docker networking** - All apps join the `platform` network
- **Static nginx configs** - Per-app configurations in `platform/nginx/sites/`
- **Backup automation** - Daily database backups (7-day retention)

## 🚀 Quick Start

### 1. Provision EC2 Instance

See [docs/EC2_SPECS.md](docs/EC2_SPECS.md) for detailed specifications.

**TL;DR:**
- AMI: Amazon Linux 2023
- Type: t3.medium
- Storage: 30 GB gp3
- Region: eu-north-1
- IAM Role: SSM + ECR access

### 2. Setup Server

```bash
# Connect via SSM
aws ssm start-session --target i-YOUR-INSTANCE-ID --region eu-north-1

# Run setup script (as root)
sudo bash /opt/platform/scripts/setup-server.sh
```

See [docs/SETUP.md](docs/SETUP.md) for detailed setup instructions.

### 3. Deploy Platform

```bash
# From your local machine
./scripts/deploy-platform.sh i-YOUR-INSTANCE-ID
```

### 4. Deploy Apps

Each app manages its own deployment via SSM. See app repos for deployment instructions:
- paiss: `make deploy-staging` / `make deploy-prod`
- filter-ical: `make deploy-staging` / `make deploy-prod`
- gabs-massage: `make deploy-staging` / `make deploy-prod`

## 📁 Repository Structure

```
multi-tenant-platform/
├── README.md                    # This file
├── docs/
│   ├── SETUP.md                # Initial server setup guide
│   ├── ADDING_APP.md           # How to add new apps
│   └── EC2_SPECS.md            # EC2 configuration details
├── platform/
│   ├── docker-compose.yml      # Platform services
│   ├── .env.example            # Environment template
│   └── nginx/
│       ├── nginx.conf          # Main nginx config
│       ├── includes/           # Reusable nginx configs
│       └── sites/              # Per-app configs
│           ├── paiss.conf
│           ├── filter-ical.conf
│           └── gabs-massage.conf
├── database/
│   ├── init.sql                # Database initialization
│   └── backup.sh               # Backup script
└── scripts/
    ├── setup-server.sh         # Server setup script
    └── deploy-platform.sh      # Platform deployment via SSM
```

## 🔧 Common Tasks

### View Platform Logs

```bash
# Connect via SSM
aws ssm start-session --target i-YOUR-INSTANCE-ID --region eu-north-1

# View logs
cd /opt/platform/platform
docker-compose logs -f
```

### Restart Platform Services

```bash
cd /opt/platform/platform
docker-compose restart nginx
```

### Manual Database Backup

```bash
/opt/platform/database/backup.sh
```

### Generate SSL Certificates (First Time)

```bash
# For each domain
docker run --rm -v certbot-etc:/etc/letsencrypt -v certbot-var:/var/www/certbot \
    certbot/certbot certonly --webroot --webroot-path=/var/www/certbot \
    --email your@email.com --agree-tos --no-eff-email \
    -d paiss.me -d www.paiss.me
```

## 📊 Current Apps

| App | Domain | Stack | Container Names |
|-----|--------|-------|----------------|
| **paiss** | paiss.me | Static site (nginx) | `paiss-production`, `paiss-staging` |
| **filter-ical** | filter-ical.de | Vue 3 + FastAPI | `filter-ical-frontend-{env}`, `filter-ical-backend-{env}` |
| **gabs-massage** | gabs-massage.de | Vue 3 + FastAPI | `gabs-massage-web`, `gabs-massage-web-staging` |

## 🛡️ Security

- All HTTP traffic redirected to HTTPS
- Modern TLS configuration (TLSv1.2+)
- Security headers (X-Frame-Options, CSP, etc.)
- Rate limiting on all endpoints
- Automated SSL certificate renewal
- No SSH access required (using AWS SSM)

## 💰 Cost

**Estimated monthly cost:** ~$35-40
- EC2 t3.medium: ~$32/month
- EBS 30GB gp3: ~$2.40/month
- Data transfer: minimal

## 📚 Documentation

- [SETUP.md](docs/SETUP.md) - Complete server setup guide
- [ADDING_APP.md](docs/ADDING_APP.md) - How to add new apps
- [EC2_SPECS.md](docs/EC2_SPECS.md) - EC2 configuration details

## 🔗 Related Repositories

- [paiss](https://github.com/duersjefen/paiss) - Company website
- [filter-ical](https://github.com/duersjefen/filter-ical) - Calendar filtering app
- [gabs-massage](https://github.com/duersjefen/physiotherapy-scheduler) - Physiotherapy scheduler

---

**Region:** eu-north-1
**Last Updated:** 2025-10-10

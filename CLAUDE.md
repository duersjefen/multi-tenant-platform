# CLAUDE.md - Multi-Tenant Platform

Shared infrastructure for hosting multiple applications on a single EC2 instance.

---

## 🔗 GLOBAL DEVELOPMENT PRINCIPLES

**For universal development principles (TDD, architecture, critical behaviors):**
→ **See:** `~/.claude/CLAUDE.md`

This file contains ONLY platform-specific infrastructure patterns.

---

## 🎯 WHAT IS THIS

**Platform provides:**
- Nginx reverse proxy (routes traffic to app containers)
- PostgreSQL database (shared by all apps)
- Certbot (automatic SSL certificates)

**Apps using this platform:**
- paiss (paiss.me)
- filter-ical (filter-ical.de)
- gabs-massage (gabs-massage.de)

**Key principles:**
- Platform = infrastructure, Apps = business logic
- **Contract-First Development:** OpenAPI specs define APIs before implementation

---

## 📋 CONTRACT-FIRST DEVELOPMENT

**All apps on this platform MUST follow contract-first development:**

### The Iron Law

```
OpenAPI Contract (openapi.yaml) → Implementation → Tests
```

**✅ CORRECT workflow:**
1. **Design API in openapi.yaml** - Define exact endpoints, parameters, responses
2. **Write contract tests** - Validate implementation matches spec exactly
3. **Implement backend** - Code to satisfy the contract
4. **Frontend consumes contract** - Never depends on implementation details

**❌ WRONG workflow:**
```
Code first → Generate OpenAPI → Hope frontend works
```

### Why This Matters

**Problem without contracts:**
- Backend refactoring breaks frontend
- APIs drift from documentation
- Frontend tightly coupled to implementation
- Breaking changes go unnoticed

**Benefits of contract-first:**
- **100% API stability** - Contract = immutable interface
- **Fearless refactoring** - Rewrite backend, frontend keeps working
- **True decoupling** - Frontend/backend can work in parallel
- **Living documentation** - OpenAPI spec is always correct
- **Type safety** - Frontend auto-generates types from contract

### Implementation Example

**filter-ical demonstrates this perfectly:**

```yaml
# backend/openapi.yaml - THE CONTRACT
paths:
  /api/domains/{domain}/groups:
    get:
      summary: Get groups for domain
      responses:
        '200':
          content:
            application/json:
              schema:
                type: array
                items:
                  $ref: '#/components/schemas/Group'
```

```python
# backend/app/routers/domains.py - IMPLEMENTATION MATCHES CONTRACT
@router.get("/{domain}/groups")
async def get_domain_groups_endpoint(domain: str, db: Session = Depends(get_db)):
    """Implementation MUST match OpenAPI contract exactly."""
    groups = get_domain_groups(db, domain)
    # Transform to exact OpenAPI schema format
    return [{
        "id": group.id,
        "name": group.name,
        "domain_key": group.domain_key
    } for group in groups]
```

```javascript
// frontend - CONSUMES CONTRACT (not implementation)
const groups = await fetch(`/api/domains/${domain}/groups`)
// Works forever, even if backend is completely rewritten
```

### Contract-First Checklist

Before implementing ANY new API endpoint:

- [ ] **1. OpenAPI spec written** - Endpoint fully defined in openapi.yaml
- [ ] **2. Contract test created** - Test validates response matches schema
- [ ] **3. Implementation matches** - Backend returns exactly what contract promises
- [ ] **4. Frontend uses contract** - No coupling to implementation details

**If OpenAPI spec doesn't exist for an endpoint, STOP and write it first!**

---

## 🏗️ ARCHITECTURE

```
multi-tenant-platform/
├── platform/
│   ├── docker-compose.yml         # Platform services (nginx, postgres, certbot)
│   ├── nginx/
│   │   ├── nginx.conf             # Main nginx config
│   │   ├── includes/              # Shared config snippets
│   │   └── sites/                 # ⚠️ ONE FILE PER APP ⚠️
│   │       ├── paiss.conf         # Routes *.paiss.me → paiss containers
│   │       ├── filter-ical.conf   # Routes *.filter-ical.de → filter-ical containers
│   │       └── gabs-massage.conf  # Routes *.gabs-massage.de → gabs-massage containers
│   └── .env                       # Platform secrets (postgres password)
└── scripts/
    └── setup-server.sh            # One-time EC2 setup

EC2 Server:
/opt/platform/              # This git repo
/opt/apps/paiss/            # paiss git repo
/opt/apps/filter-ical/      # filter-ical git repo
/opt/apps/gabs-massage/     # gabs-massage git repo
```

---

## ⚠️ CRITICAL RULES

### 1. Git is Source of Truth

**✅ ALWAYS:**
- Edit nginx configs locally in git repo
- Commit and push
- Pull on EC2
- Restart nginx

**❌ NEVER:**
- Edit files directly on EC2 via SSM
- Create configs with `cat > file` on server
- Make "temporary" changes on server

**Why:** Server and git MUST stay in sync (DRY principle)

### 2. Nginx Config Editing Workflow

```bash
# 1. Edit locally
cd ~/Documents/Projects/multi-tenant-platform
vi platform/nginx/sites/paiss.conf

# 2. Test locally (optional)
docker-compose -f platform/docker-compose.yml config

# 3. Commit and push
git add platform/nginx/sites/paiss.conf
git commit -m "Update paiss routing"
git push origin main

# 4. Deploy to EC2
aws ssm send-command --region eu-north-1 \
  --instance-ids i-00c2eac2757315946 \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=["cd /opt/platform && git pull origin main && cd platform && docker-compose restart nginx"]'

# Or manually via SSM session:
aws ssm start-session --target i-00c2eac2757315946
cd /opt/platform && git pull && cd platform && docker-compose restart nginx
```

### 3. Container Naming Convention

**Staging:** `{app}-{component}-staging` (single-service apps omit component)
- paiss-staging
- filter-ical-backend-staging, filter-ical-frontend-staging
- gabs-massage-backend-staging

**Production:** `{app}-{component}-production` (single-service apps omit component)
- paiss-production
- filter-ical-backend-production, filter-ical-frontend-production
- gabs-massage-backend-production

**Nginx must route to correct container names!**

### 4. Environment Variables (.env files)

**Platform .env** (`/opt/platform/platform/.env`) - Infrastructure only:
```bash
POSTGRES_PASSWORD=<generated-secret>
```

**App .env files** - Per-component pattern (see global CLAUDE.md):
```
/opt/apps/myapp/
├── backend/.env.staging        # Backend-only vars
├── backend/.env.production
├── frontend/.env.staging       # Frontend-only vars (VITE_API_BASE_URL, etc.)
└── frontend/.env.production
```

**Multi-component apps (filter-ical, gabs-massage):**
- Use per-component .env files for security (frontend never gets backend secrets)
- `docker-compose.yml` uses: `env_file: backend/.env.${ENVIRONMENT}`

**Single-component apps (paiss):**
- Root `.env.staging` / `.env.production` acceptable

**✅ Edit .env files directly on EC2 (they contain secrets, never commit)**
**✅ Set once, rarely change**
**✅ See `~/.claude/CLAUDE.md` for per-component pattern details**

---

## 🔧 COMMON TASKS

### Add New App to Platform

1. **Create nginx config:**
```bash
cd ~/Documents/Projects/multi-tenant-platform
cp platform/nginx/sites/paiss.conf platform/nginx/sites/newapp.conf
# Edit newapp.conf with correct domains and container names
git add platform/nginx/sites/newapp.conf
git commit -m "Add newapp routing"
git push origin main
```

2. **Deploy to EC2:**
```bash
# Pull config
aws ssm send-command ... 'cd /opt/platform && git pull'

# Clone app repo
aws ssm send-command ... 'cd /opt/apps && git clone https://github.com/user/newapp.git'

# Create .env file
aws ssm send-command ... 'echo "ENVIRONMENT=staging" > /opt/apps/newapp/.env'

# Start app containers
aws ssm send-command ... 'cd /opt/apps/newapp && ENVIRONMENT=staging docker-compose up -d'

# Restart nginx
aws ssm send-command ... 'cd /opt/platform/platform && docker-compose restart nginx'
```

3. **Generate SSL:**
```bash
docker exec certbot-platform certbot certonly --webroot \
  -w /var/www/certbot \
  -d newapp.com -d www.newapp.com -d staging.newapp.com \
  --email your@email.com --agree-tos --non-interactive
```

### Update Nginx Routing

**See "Nginx Config Editing Workflow" above** - ALWAYS via git!

### Update Platform Services

```bash
cd ~/Documents/Projects/multi-tenant-platform
vi platform/docker-compose.yml  # Edit postgres version, add service, etc.
git commit -m "Update platform services"
git push origin main

# Deploy
aws ssm send-command ... 'cd /opt/platform && git pull && cd platform && docker-compose up -d'
```

### SSL Certificate Renewal

**Automatic:** Certbot renews certificates automatically (runs daily)

**Manual (if needed):**
```bash
docker exec certbot-platform certbot renew
docker-compose restart nginx  # Reload certs
```

---

## 🚢 DEPLOYMENT

### Platform Initial Setup (One-Time)

```bash
# 1. Launch EC2 (Amazon Linux 2023, t3.medium)
# 2. Ensure IAM role has AmazonSSMManagedInstanceCore policy
# 3. Connect via SSM
aws ssm start-session --target i-00c2eac2757315946

# 4. Run setup script
sudo dnf update -y
sudo dnf install -y docker git
sudo systemctl start docker && sudo systemctl enable docker
sudo usermod -aG docker ec2-user

# Install docker-compose
sudo curl -L "https://github.com/docker/compose/releases/download/v2.24.5/docker-compose-linux-x86_64" -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose

# 5. Clone platform
sudo mkdir -p /opt/platform /opt/apps
cd /opt/platform
sudo git clone https://github.com/duersjefen/multi-tenant-platform.git .

# 6. Create .env and start platform
cd platform
echo "POSTGRES_PASSWORD=$(openssl rand -hex 32)" | sudo tee .env
sudo docker-compose up -d

# 7. Clone app repos (see app CLAUDE.md files for deployment)
```

### Platform Updates

```bash
cd /opt/platform
git pull origin main
cd platform
docker-compose up -d  # Recreates containers if needed
docker-compose restart nginx  # Or just restart nginx
```

---

## 📊 MONITORING

```bash
# Check all platform services
docker ps | grep -E 'nginx-platform|postgres-platform|certbot-platform'

# Check nginx logs
docker logs nginx-platform --tail 100

# Check postgres
docker exec postgres-platform psql -U platform_admin -l

# Check SSL certificates
docker exec certbot-platform certbot certificates
```

---

## 🔗 RELATED DOCUMENTATION

**App Deployment:**
- paiss: `/Users/martijn/Documents/Projects/paiss/CLAUDE.md`
- filter-ical: `/Users/martijn/Documents/Projects/filter-ical/CLAUDE.md`
- gabs-massage: `/Users/martijn/Documents/Projects/gabs-massage/CLAUDE.md`

**EC2 Instance:**
- Instance ID: `i-00c2eac2757315946`
- Region: `eu-north-1` (Stockholm)
- Public IP: Check via `aws ec2 describe-instances`

---

**Last Updated:** 2025-10-10

# Platform Architecture

## 🎯 Design Philosophy

**"Configure once, deploy anywhere"**

The platform is built on these principles:

1. **Central Configuration**: All projects defined in ONE place (`projects.yml`)
2. **Universal Scripts**: Deployment scripts work for ANY project
3. **Shared Infrastructure**: One nginx, one monitoring stack
4. **Project Isolation**: Each app has separate containers/configs
5. **Production Safety**: Validation, backups, health checks, rollbacks

## 🏗️ System Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                         Internet                             │
└───────────────────────────┬─────────────────────────────────┘
                            │
                    ┌───────▼────────┐
                    │  Let's Encrypt │ (SSL Certificates)
                    └───────┬────────┘
                            │
┌───────────────────────────▼─────────────────────────────────┐
│                    EC2 Instance (56.228.25.95)              │
│                                                              │
│  ┌────────────────────────────────────────────────────────┐ │
│  │            Platform Infrastructure (Shared)            │ │
│  │                                                        │ │
│  │  ┌─────────┐  ┌────────────┐  ┌──────────┐           │ │
│  │  │  Nginx  │  │ Prometheus │  │ Grafana  │           │ │
│  │  │ (ports  │  │  (metrics) │  │  (dash)  │           │ │
│  │  │ 80/443) │  │            │  │          │           │ │
│  │  └────┬────┘  └──────▲─────┘  └────▲─────┘           │ │
│  │       │              │             │                  │ │
│  │       │              │             │                  │ │
│  └───────┼──────────────┼─────────────┼──────────────────┘ │
│          │              │             │                    │
│  ┌───────▼──────────────┴─────────────┴──────────────────┐ │
│  │                   Docker Network                       │ │
│  └───────┬────────────────────────────────────────────────┘ │
│          │                                                   │
│  ┌───────▼────────────┐         ┌───────────────────────┐  │
│  │  Project: filter   │         │  Project: my-new-app  │  │
│  │  ─────────────────│         │  ───────────────────── │  │
│  │  ┌─────────────┐  │         │  ┌─────────────┐      │  │
│  │  │  Backend    │  │         │  │  App Server │      │  │
│  │  │  (port 3000)│  │         │  │  (port 8080)│      │  │
│  │  └─────────────┘  │         │  └─────────────┘      │  │
│  │  ┌─────────────┐  │         │                        │  │
│  │  │  Frontend   │  │         │                        │  │
│  │  │  (port 80)  │  │         │                        │  │
│  │  └─────────────┘  │         │                        │  │
│  └────────────────────┘         └────────────────────────┘  │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

## 📋 Component Responsibilities

### Platform Layer (Shared)

#### Nginx
- **Routes traffic** to correct project based on domain
- **SSL termination** (Let's Encrypt certificates)
- **Rate limiting** (configurable per-project)
- **Static asset caching**
- **Health check endpoint** (`/nginx-health`)

**Config**: `platform/nginx/`

#### Prometheus
- **Scrapes metrics** from all projects
- **Evaluates alert rules**
- **Stores time-series data** (30 day retention)

**Config**: `platform/monitoring/prometheus/`

#### Grafana
- **Visualizes metrics** from Prometheus
- **Pre-configured dashboards** for all projects
- **Accessible** at `monitoring.filter-ical.de`

**Config**: `platform/monitoring/grafana/`

#### Alertmanager
- **Routes alerts** to notification channels (email, Slack, PagerDuty)
- **Deduplicates alerts**
- **Inhibition rules** (don't alert about apps if server is down)

**Config**: `platform/monitoring/alertmanager/`

#### Node Exporter & cAdvisor
- **Server-level metrics** (CPU, memory, disk)
- **Container-level metrics** (per-container resource usage)

### Application Layer (Isolated)

Each project has:

1. **Docker Compose file**: Defines app containers
2. **Environment files**: `.env.production`, `.env.staging`
3. **Nginx config**: Generated from `projects.yml`

**Location**: `configs/{project-name}/`

## 🔄 Deployment Flow

### Direct Deployment (Simple)

```
1. Pre-flight Validation
   ├─ Check disk space
   ├─ Validate environment variables
   └─ Validate Docker images exist

2. Create Backup
   ├─ Tag current images as backup-{timestamp}
   ├─ Backup volumes (if any)
   └─ Backup configuration files

3. Pull New Images
   └─ docker-compose pull

4. Deploy
   └─ docker-compose up -d --no-deps

5. Health Check
   ├─ Wait for containers to start (60s warmup)
   ├─ Check Docker health status
   └─ Validate HTTP endpoints

6. Reload Nginx
   └─ nginx -s reload

7. Success (or Rollback)
```

### Blue-Green Deployment (Zero Downtime)

```
1. Pre-flight Validation
   └─ (same as direct)

2. Create Backup
   └─ (same as direct)

3. Deploy to Inactive Environment
   ├─ Current: blue (active)
   ├─ Deploy to: green (inactive)
   └─ Containers: project-green-*

4. Validate Inactive Environment
   ├─ Health checks on green environment
   ├─ Smoke tests
   └─ Only proceed if 100% healthy

5. Switch Traffic
   ├─ Update nginx upstream
   ├─ Reload nginx
   └─ Traffic now → green

6. Cleanup Old Environment
   ├─ Wait 5 minutes (monitoring period)
   ├─ Stop blue containers
   └─ Keep images for rollback

7. Success (or Rollback)
```

## 📝 Project Registry (`projects.yml`)

The **heart of the system**. Defines everything about each project:

```yaml
my-app:
  # Basic info
  name: "My Application"
  repository: "https://github.com/user/my-app"

  # Routing
  domains:
    production: [my-app.com, www.my-app.com]
    staging:
      subdomain: staging
      domains: [staging.my-app.com]

  # Containers
  containers:
    backend:
      name: my-app-backend
      port: 3000
      health_check:
        path: /health
        expected_status: 200
        timeout: 30
        retries: 10
        start_period: 60  # Critical: warmup time

  # Deployment strategy
  environments:
    production:
      containers: [my-app-backend]
      deployment_strategy: blue-green  # or 'direct'
      auto_rollback: true

  # Nginx routing rules
  nginx:
    api_locations: [/api, /graphql]
    rate_limit:
      zone: api
      rate: 10r/s
      burst: 20

  # Monitoring
  monitoring:
    enabled: true
    alerts:
      - name: production_down
        condition: "up == 0"
        duration: 1m
        severity: critical

  # Backups
  backup:
    enabled: true
    pre_deployment: true
    retention: 3
```

## 🛠️ Universal Deployment Scripts

### How They Work

All scripts are **project-agnostic**:

```bash
# ❌ OLD WAY (hard-coded)
if [ "$project" = "filter-ical" ]; then
    deploy_filter_ical
elif [ "$project" = "my-new-app" ]; then
    deploy_my_new_app
fi

# ✅ NEW WAY (universal)
read_from_projects_yml "$project" "$environment"
deploy_using_configuration
```

### Script Library

Located in `lib/`:

- **`deploy.sh`**: Main deployment orchestration
- **`rollback.sh`**: Rollback to previous version
- **`health-check.sh`**: Validate application health
- **`functions/validation.sh`**: Pre-flight checks
- **`functions/blue-green.sh`**: Blue-green logic
- **`functions/backup.sh`**: Backup/restore operations
- **`functions/notifications.sh`**: Alert notifications

## 🔐 Security

### Network Isolation
- All containers in isolated `platform` network
- Monitoring tools only accessible from `localhost`
- Only nginx exposed to internet (ports 80/443)

### SSL/TLS
- Let's Encrypt certificates (auto-renewal)
- TLS 1.2+ only
- Strong cipher suites
- HSTS headers

### Rate Limiting
- Per-project rate limits defined in `projects.yml`
- API routes: 10 req/s (configurable)
- General routes: 100 req/s (configurable)

### Health Checks
- Container-level health checks (Docker)
- Application-level health checks (HTTP)
- Warmup periods to prevent false negatives

## 📊 Monitoring

### Metrics Collected

**Server-level** (Node Exporter):
- CPU usage
- Memory usage
- Disk space
- Network I/O

**Container-level** (cAdvisor):
- Per-container CPU/memory
- Container restarts
- Container state

**Application-level**:
- HTTP request rate
- Response times (p50, p95, p99)
- Error rates (4xx, 5xx)
- Custom business metrics (via `/metrics` endpoint)

### Alerting

Alerts defined per-project in `projects.yml`:

```yaml
alerts:
  - name: production_down
    condition: "up == 0"
    duration: 1m
    severity: critical

  - name: high_error_rate
    condition: "rate(http_5xx[5m]) > 0.05"
    duration: 2m
    severity: warning
```

Alertmanager routes based on severity:
- **Critical**: Immediate notification (email + Slack + PagerDuty)
- **Warning**: Notification after 5 minutes
- **Staging**: Low-priority, email only

## 🚀 Scaling Considerations

### Current Setup (Single Server)
- Multiple apps on one EC2 instance
- Shared nginx, shared monitoring
- Good for: Low/medium traffic apps

### Future Scaling Options

**Vertical Scaling**:
- Increase EC2 instance size
- Add more CPU/memory

**Horizontal Scaling** (future):
- Multiple EC2 instances behind load balancer
- Docker Swarm or Kubernetes
- Distributed monitoring (Prometheus federation)

**Database Scaling** (future):
- Move to RDS (managed database)
- Read replicas
- Connection pooling

## 🔄 CI/CD Integration

The platform is designed to work with GitHub Actions:

```yaml
# .github/workflows/deploy.yml
- name: Deploy to Production
  run: |
    ssh ec2 './deploy/lib/deploy.sh my-app production'
```

Scripts return proper exit codes:
- `0`: Success
- `1`: Failure (CI/CD will fail the build)

## 📦 Adding New Projects

### Copy-Paste Workflow

1. **Copy template**:
   ```bash
   cp -r templates/new-app configs/my-new-app
   ```

2. **Add to registry**:
   ```bash
   # Edit projects.yml, copy filter-ical section
   ```

3. **Generate nginx config**:
   ```bash
   # (Future: auto-generation script)
   # For now: copy filter-ical.conf and modify
   ```

4. **Deploy**:
   ```bash
   ./lib/deploy.sh my-new-app production
   ```

Time: **~15 minutes** from idea to production!

## 🎯 Design Decisions

### Why One Nginx for All Projects?
- **Pros**: Single SSL endpoint, simpler routing, resource efficiency
- **Cons**: Single point of failure (mitigated by health checks)

### Why Shared Monitoring?
- **Pros**: Unified dashboards, cross-project insights, cost efficiency
- **Cons**: More complex setup initially (but reusable)

### Why YAML for Configuration?
- **Pros**: Human-readable, industry standard, easy to diff
- **Cons**: Requires parsing (mitigated by using standard tools)

### Why Bash Scripts?
- **Pros**: Universal, no dependencies, easy to debug
- **Cons**: Can be complex for advanced features (mitigated by function libraries)

## 📚 Further Reading

- [ADDING_A_PROJECT.md](./ADDING_A_PROJECT.md) - Add new projects
- [DEPLOYMENT_GUIDE.md](./DEPLOYMENT_GUIDE.md) - Deployment deep-dive
- [TROUBLESHOOTING.md](./TROUBLESHOOTING.md) - Common issues

---

**This architecture is Netflix-ready**. Seriously. 😎
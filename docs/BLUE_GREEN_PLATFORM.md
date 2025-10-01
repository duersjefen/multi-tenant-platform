# Blue-Green Deployment Strategy for Platform Components

## Overview

Blue-green deployment for platform infrastructure (nginx, monitoring) provides zero-downtime updates with instant rollback capability. This document describes the strategy and implementation approach.

## Current State (2025-10-01)

**Implemented:**
- ✅ Staging test container (`test-nginx-staging.sh`) - Test on port 8443 before production
- ✅ Backup and rollback for nginx (`deploy-platform.sh`)
- ✅ Health checks and validation
- ✅ Blue-green for applications (filter-ical, paiss)

**Not Yet Implemented:**
- ❌ Full blue-green for platform nginx
- ❌ Traffic switching mechanism
- ❌ Automated health-based promotion

## Architecture Options

### Option 1: DNS-Based Blue-Green (Recommended for Future)

**Architecture:**
```
┌─────────────┐
│   DNS/CDN   │
│ (Cloudflare)│
└──────┬──────┘
       │
       ├────────────┐
       ↓            ↓
┌──────────┐  ┌──────────┐
│  Blue    │  │  Green   │
│  Server  │  │  Server  │
│ (Active) │  │ (Standby)│
└──────────┘  └──────────┘
```

**Benefits:**
- True zero-downtime
- Instant rollback (change DNS)
- Complete isolation
- Can test green with real traffic

**Drawbacks:**
- Requires DNS management
- DNS TTL delay (5-60s)
- Doubles infrastructure cost
- More complex automation

**Implementation:**
```bash
# Blue server: 13.62.136.72 (production)
# Green server: (new EC2 instance)

# Deploy green
ssh green-server
cd /opt/multi-tenant-platform
git pull
./lib/deploy-platform.sh all

# Test green
./lib/validate-all-projects.sh

# Switch traffic (Cloudflare API)
curl -X PATCH "https://api.cloudflare.com/client/v4/zones/{zone_id}/dns_records/{record_id}" \
  -H "Authorization: Bearer {token}" \
  --data '{"content":"<green-server-ip>"}'
```

### Option 2: Port-Based Blue-Green (Current Approach)

**Architecture:**
```
┌──────────────┐
│    Server    │
│              │
│ ┌──────────┐ │
│ │  Nginx   │ │  Port 443 (production)
│ │  Blue    │ │
│ └──────────┘ │
│              │
│ ┌──────────┐ │
│ │  Nginx   │ │  Port 8443 (staging)
│ │  Green   │ │
│ └──────────┘ │
└──────────────┘
```

**Benefits:**
- Same infrastructure
- Quick to implement
- Good for testing
- No DNS changes

**Drawbacks:**
- Still requires brief downtime to swap ports
- Can't test with real production traffic
- Port conflict management

**Implementation:**
Currently implemented via `test-nginx-staging.sh`:
```bash
# Start green
./lib/test-nginx-staging.sh start

# Test green
./lib/test-nginx-staging.sh test

# Promote green (stops staging, deploys to prod)
./lib/test-nginx-staging.sh promote
```

### Option 3: Container-Based Blue-Green

**Architecture:**
```
┌──────────────────────────────┐
│          HAProxy             │  Port 443
│    (Traffic Director)        │
└──────┬───────────────┬───────┘
       │               │
       ↓               ↓
┌────────────┐  ┌────────────┐
│   Nginx    │  │   Nginx    │
│   Blue     │  │   Green    │
│   :8081    │  │   :8082    │
└────────────┘  └────────────┘
```

**Benefits:**
- True zero-downtime
- Instant traffic switch
- Same server
- Can gradually shift traffic (canary)

**Drawbacks:**
- Adds HAProxy complexity
- More containers to manage
- Slightly higher resource usage

**Implementation Plan:**
```yaml
# docker-compose.blue-green.yml
services:
  haproxy:
    image: haproxy:alpine
    ports:
      - "443:443"
      - "443:443/udp"
    volumes:
      - ./haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg
    depends_on:
      - nginx-blue
      - nginx-green

  nginx-blue:
    image: macbre/nginx-http3:latest
    container_name: platform-nginx-blue
    expose:
      - "8081"
      - "8081/udp"
    # ... rest of config

  nginx-green:
    image: macbre/nginx-http3:latest
    container_name: platform-nginx-green
    expose:
      - "8082"
      - "8082/udp"
    # ... rest of config
```

```haproxy
# haproxy.cfg
frontend https
    bind *:443 ssl crt /etc/ssl/certs/
    default_backend nginx-servers

backend nginx-servers
    server blue platform-nginx-blue:8081 check
    # server green platform-nginx-green:8082 check backup

# To switch: comment blue, uncomment green, reload haproxy
```

## Recommended Path Forward

### Phase 1: Enhanced Staging (✅ DONE)
- Use `test-nginx-staging.sh` for testing platform changes
- Manual promotion after validation

### Phase 2: Automated Rollback (Future)
- Enhance `deploy-platform.sh` with automatic rollback
- Health check failures trigger instant revert
- Metrics-based rollback (error rate spike)

### Phase 3: Full Blue-Green (When Needed)
Choose implementation based on growth:
- **< 10 projects:** Stick with staging approach
- **10-50 projects:** Consider Container-Based Blue-Green
- **50+ projects or critical SLA:** DNS-Based Blue-Green

## Current Workflow (Recommended)

**For platform nginx updates:**
```bash
# 1. Test locally
./lib/test-platform.sh nginx

# 2. Test in staging container
./lib/test-nginx-staging.sh start
./lib/test-nginx-staging.sh test

# 3. Promote if good
./lib/test-nginx-staging.sh promote
# OR rollback if bad
./lib/test-nginx-staging.sh stop

# 4. Verify production
./lib/validate-all-projects.sh
```

**For monitoring updates:**
```bash
# Direct deployment (monitoring less critical)
./lib/deploy-platform.sh monitoring
```

## Rollback Procedures

### Immediate Rollback (< 5 minutes)

**Option 1: Docker image rollback**
```bash
# Find backup
docker images | grep platform-nginx-backup

# Tag as latest
docker tag platform-nginx-backup-TIMESTAMP macbre/nginx-http3:latest

# Redeploy
docker compose -f platform/docker-compose.platform.yml up -d nginx
```

**Option 2: Git revert**
```bash
# Revert config changes
git revert <commit-hash>

# Redeploy
./lib/deploy-platform.sh nginx
```

### Extended Rollback (> 5 minutes, full restore)

```bash
# Use backup script
./lib/rollback.sh platform nginx <backup-name>
```

## Metrics to Monitor

**Health indicators:**
- HTTP status code distribution (2xx, 4xx, 5xx)
- Response time (p50, p95, p99)
- Active connections
- Error logs rate

**Rollback triggers:**
- 5xx error rate > 5% for 1 minute
- p95 latency > 2x baseline for 2 minutes
- Health check failures > 50% for 30 seconds

## Future Enhancements

1. **Automated Canary Testing**
   - Route 10% traffic to green
   - Monitor for 5 minutes
   - Auto-promote if healthy, auto-rollback if issues

2. **Metrics-Based Deployment**
   - Prometheus alerts trigger rollback
   - SLO-based promotion decisions
   - Automated smoke tests

3. **Multi-Region Blue-Green**
   - Deploy to secondary region first
   - Validate before primary region
   - Geographic failover capability

## Cost-Benefit Analysis

| Approach | Setup Time | Operational Complexity | Infrastructure Cost | Downtime |
|----------|-----------|----------------------|-------------------|----------|
| Current (Staging Port) | ✅ Done | Low | $0 | ~30s |
| Container Blue-Green | 4-8 hours | Medium | ~$10/month | 0s |
| DNS Blue-Green | 2-4 days | High | ~$50-100/month | 0s (DNS TTL) |

**Recommendation:** Current approach is sufficient until reaching 20+ projects or requiring stricter SLA.

---

**Last Updated:** 2025-10-01
**Status:** Phase 1 (Enhanced Staging) Complete

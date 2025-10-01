# Grafana Dashboard Setup Guide

This guide explains the newly configured Grafana dashboards for the multi-tenant platform.

## What Was Added

### 1. Nginx Prometheus Exporter
- **Service**: `nginx-exporter` (port 9113)
- **Monitors**: Request rates, active connections, connection states
- **Config Changes**:
  - Added `/nginx-status` endpoint in `platform/nginx/nginx.conf`
  - Added nginx-exporter service to `platform/docker-compose.platform.yml`
  - Enabled nginx scraping in `platform/monitoring/prometheus/prometheus.yml`

### 2. Three New Dashboards

#### **Nginx Performance** (`nginx-performance.json`)
- Request rate (req/sec)
- Active connections gauge
- Total requests counter
- Connection states (reading, writing, waiting)
- Connection handling rate

#### **Container Resources** (`container-resources.json`)
- CPU usage per container (%)
- Memory usage per container
- Network traffic (TX/RX) per container
- Disk I/O per container
- Resource summary table

#### **Node/Server Health** (`node-health.json`)
- CPU usage gauge
- Memory usage gauge
- Disk usage gauge
- System uptime
- CPU usage by mode (user, system, idle, etc.)
- Memory details (total, available, buffers, cached)
- Network traffic by interface
- Disk I/O operations
- Filesystem usage table

## Deployment Steps

### Step 1: Test Configuration Locally (Optional)
```bash
# Validate nginx config syntax
docker compose -f platform/docker-compose.platform.yml config

# Check if dashboard files are valid JSON
for f in platform/monitoring/grafana/dashboards/*.json; do
  echo "Checking $f"
  jq empty "$f" && echo "✓ Valid" || echo "✗ Invalid"
done
```

### Step 2: Deploy to Production

**Option A: Using Makefile (Recommended)**
```bash
# Deploy platform changes (safer, includes staging)
make deploy-nginx

# Or deploy all platform services
make deploy-platform
```

**Option B: Using deployment scripts directly**
```bash
# Deploy the entire platform stack
./lib/deploy-platform.sh all

# Or just deploy monitoring components
./lib/deploy-platform.sh monitoring
```

**Option C: Manual deployment on server**
```bash
# SSH to server
ssh user@your-server

# Navigate to platform directory
cd /opt/multi-tenant-platform

# Pull latest changes
git pull

# Deploy platform services
docker compose -f platform/docker-compose.platform.yml up -d

# Check services are running
docker compose -f platform/docker-compose.platform.yml ps

# Check nginx-exporter logs
docker logs platform-nginx-exporter

# Reload prometheus to pick up new config
docker compose -f platform/docker-compose.platform.yml exec prometheus \
  kill -HUP 1

# Restart Grafana to pick up new dashboards
docker compose -f platform/docker-compose.platform.yml restart grafana
```

### Step 3: Verify Metrics Collection

```bash
# Check nginx metrics endpoint
curl http://localhost:80/nginx-status
# Should return: Active connections, requests, etc.

# Check nginx-exporter is scraping
curl http://localhost:9113/metrics | grep nginx_
# Should return: nginx_http_requests_total, nginx_connections_active, etc.

# Check Prometheus targets
curl http://localhost:9090/api/v1/targets | jq '.data.activeTargets[] | {job: .labels.job, health: .health}'
# All should show "health": "up"

# Specifically check nginx target
curl 'http://localhost:9090/api/v1/query?query=up{job="nginx"}' | jq
# Should return: "value": ["timestamp", "1"]
```

### Step 4: Access Grafana

1. **Open Grafana**: https://monitoring.paiss.me
2. **Login**: Use admin credentials from `GRAFANA_ADMIN_PASSWORD` env variable
3. **Navigate to Dashboards**:
   - Click "Dashboards" in left sidebar
   - You should see:
     - Nginx Performance
     - Container Resources
     - Node/Server Health

### Step 5: Verify Dashboards Are Working

For each dashboard:
- ✅ Panels load without "No Data" errors
- ✅ Graphs show actual data (not empty)
- ✅ Time series show recent data points
- ✅ Gauges display current values

**Troubleshooting "No Data":**

```bash
# Check if Prometheus has the metrics
curl 'http://localhost:9090/api/v1/query?query=nginx_http_requests_total' | jq

# Check container metrics
curl 'http://localhost:9090/api/v1/query?query=container_cpu_usage_seconds_total' | jq

# Check node metrics
curl 'http://localhost:9090/api/v1/query?query=node_cpu_seconds_total' | jq
```

## Dashboard Features

### Auto-Refresh
All dashboards refresh every **30 seconds** automatically.

### Time Range
Default time range is **Last 6 hours**. You can change this:
- Top-right corner: Click time range selector
- Choose: Last 5m, 15m, 1h, 6h, 24h, 7d, etc.

### Customization
Since `allowUiUpdates: true` is set, you can:
- Modify panels
- Add new panels
- Rearrange layout
- Changes persist in Grafana's database

To save changes to git (optional):
1. In Grafana: Dashboard Settings → JSON Model → Copy
2. Save to `platform/monitoring/grafana/dashboards/<name>.json`
3. Commit to repository

## Metrics Collected

### From Nginx Exporter
- `nginx_http_requests_total` - Total HTTP requests
- `nginx_connections_active` - Current active connections
- `nginx_connections_reading` - Connections reading request
- `nginx_connections_writing` - Connections writing response
- `nginx_connections_waiting` - Idle keepalive connections
- `nginx_connections_accepted` - Total accepted connections
- `nginx_connections_handled` - Total handled connections

### From cAdvisor (Containers)
- `container_cpu_usage_seconds_total` - CPU time consumed
- `container_memory_usage_bytes` - Current memory usage
- `container_network_transmit_bytes_total` - Network TX bytes
- `container_network_receive_bytes_total` - Network RX bytes
- `container_fs_reads_bytes_total` - Disk read bytes
- `container_fs_writes_bytes_total` - Disk write bytes

### From Node Exporter (Server)
- `node_cpu_seconds_total` - CPU time by mode
- `node_memory_*` - Memory metrics (total, available, cached, etc.)
- `node_filesystem_*` - Disk usage and space
- `node_network_*` - Network interface statistics
- `node_disk_*` - Disk I/O statistics
- `node_boot_time_seconds` - System boot time

## Alert Rules (Future Enhancement)

The platform already has Alertmanager configured. You can add alert rules to:
`platform/monitoring/prometheus/alerts.yml`

Example alerts you might want:
- High CPU usage (>80% for 5 minutes)
- High memory usage (>85%)
- Disk almost full (>90%)
- Nginx connection errors
- Container restarts
- SSL certificate expiry (<7 days)

## Performance Impact

### Resource Usage
- **nginx-exporter**: ~10MB memory, negligible CPU
- **Prometheus**: ~100-500MB memory (depends on retention)
- **Grafana**: ~50-100MB memory
- **cAdvisor**: ~100-200MB memory
- **Node Exporter**: ~10MB memory

### Network Impact
- Prometheus scrapes all exporters every **15 seconds**
- Each scrape: <10KB
- Total bandwidth: <50KB/sec (~4MB/hour)

## Files Modified/Created

### Modified
1. `platform/nginx/nginx.conf` - Added `/nginx-status` endpoint
2. `platform/docker-compose.platform.yml` - Added nginx-exporter service
3. `platform/monitoring/prometheus/prometheus.yml` - Enabled nginx scraping

### Created
1. `platform/monitoring/grafana/dashboards/nginx-performance.json`
2. `platform/monitoring/grafana/dashboards/container-resources.json`
3. `platform/monitoring/grafana/dashboards/node-health.json`
4. `GRAFANA_SETUP.md` (this file)

## Maintenance

### Dashboard Updates
To update dashboards:
1. Edit JSON files in `platform/monitoring/grafana/dashboards/`
2. Commit changes
3. Deploy: `./lib/deploy-platform.sh monitoring`
4. Grafana will pick up changes automatically (within 10 seconds)

### Prometheus Data Retention
Current settings (see docker-compose.platform.yml):
- **Time**: 30 days
- **Size**: 10GB max
- **Location**: `prometheus-data` Docker volume

To change:
```yaml
command:
  - '--storage.tsdb.retention.time=60d'  # Change to 60 days
  - '--storage.tsdb.retention.size=20GB'  # Change to 20GB
```

### Backup Grafana Dashboards
```bash
# Export all dashboards
curl -H "Authorization: Bearer $GRAFANA_API_KEY" \
  http://localhost:3001/api/search | \
  jq -r '.[] | .uid' | \
  while read uid; do
    curl -H "Authorization: Bearer $GRAFANA_API_KEY" \
      "http://localhost:3001/api/dashboards/uid/$uid" \
      > "backup-$uid.json"
  done
```

## Next Steps

1. **Deploy the changes** using one of the methods above
2. **Verify all dashboards work** and show data
3. **Configure alerts** in `prometheus/alerts.yml` (optional)
4. **Set up notifications** in `alertmanager/alertmanager.yml` (optional)
5. **Customize dashboards** to your needs
6. **Monitor regularly** - check dashboards daily for issues

## Support

For issues:
1. Check logs: `docker logs platform-nginx-exporter`
2. Verify Prometheus targets: http://localhost:9090/targets
3. Test metrics endpoints manually (see Step 3 above)
4. Check Grafana logs: `docker logs platform-grafana`

---

**Last Updated**: 2025-10-01
**Author**: Claude Code (AI Assistant)

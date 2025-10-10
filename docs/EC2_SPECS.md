# EC2 Instance Specifications

Detailed specifications for the multi-tenant platform EC2 instance.

## Instance Configuration

### AMI
- **Name**: Amazon Linux 2023
- **Region**: eu-north-1 (Stockholm)
- **Architecture**: x86_64
- **Virtualization**: HVM

### Instance Type
- **Type**: t3.medium
- **vCPUs**: 2
- **RAM**: 4 GB
- **Network**: Up to 5 Gbps
- **EBS-Optimized**: Yes (by default)

**Cost**: ~$32/month (eu-north-1, on-demand pricing)

### Storage
- **Type**: EBS gp3 (General Purpose SSD)
- **Size**: 30 GB
- **IOPS**: 3,000 (default for gp3)
- **Throughput**: 125 MB/s (default for gp3)
- **Delete on Termination**: No (for safety)

**Cost**: ~$2.40/month

### Networking
- **VPC**: Default VPC
- **Subnet**: Public subnet (eu-north-1a, eu-north-1b, or eu-north-1c)
- **Auto-assign Public IP**: Yes
- **Elastic IP**: Optional (recommended for production)

## Security Group

**Name**: `multi-tenant-platform-sg`

### Inbound Rules

| Type | Protocol | Port | Source | Description |
|------|----------|------|--------|-------------|
| HTTP | TCP | 80 | 0.0.0.0/0 | Public HTTP access + Let's Encrypt |
| HTTP | TCP | 80 | ::/0 | Public HTTP access (IPv6) |
| HTTPS | TCP | 443 | 0.0.0.0/0 | Public HTTPS access |
| HTTPS | TCP | 443 | ::/0 | Public HTTPS access (IPv6) |
| HTTPS | UDP | 443 | 0.0.0.0/0 | HTTP/3 (QUIC) |
| HTTPS | UDP | 443 | ::/0 | HTTP/3 (QUIC) IPv6 |

**Note**: No SSH (port 22) - using AWS SSM for access

### Outbound Rules

| Type | Protocol | Port | Destination | Description |
|------|----------|------|-------------|-------------|
| All traffic | All | All | 0.0.0.0/0 | Required for updates, Docker pulls, SSM |

## IAM Role

**Name**: `MultiTenantPlatformEC2Role`

### Attached Policies

1. **AmazonSSMManagedInstanceCore** (AWS Managed)
   - Required for AWS Systems Manager (SSM) access
   - Allows remote command execution without SSH

**Note**: No ECR/registry permissions needed - apps build directly on server from git repos

## User Data (Optional)

If you want to automate initial setup, add this as User Data:

```bash
#!/bin/bash
set -e

# Update system
dnf update -y

# Install Docker
dnf install -y docker git

# Start Docker
systemctl start docker
systemctl enable docker

# Add ec2-user to docker group
usermod -a -G docker ec2-user

# Install Docker Compose
DOCKER_COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep 'tag_name' | cut -d'"' -f4)
curl -L "https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" \
    -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

# Create directories
mkdir -p /opt/platform /opt/apps /opt/backups
chown -R ec2-user:ec2-user /opt/platform /opt/apps /opt/backups

# Clone platform repo
cd /opt/platform
git clone https://github.com/duersjefen/multi-tenant-platform.git .

echo "Setup complete!" > /var/log/user-data-complete.log
```

## Tags

Recommended tags for organization:

| Key | Value |
|-----|-------|
| Name | multi-tenant-platform-v2 |
| Environment | production |
| Project | multi-tenant-platform |
| ManagedBy | terraform/manual |

## Capacity Planning

### Current Usage (3 apps)

| Resource | Used | Available | Headroom |
|----------|------|-----------|----------|
| CPU | ~20% | 2 vCPUs | 80% |
| RAM | ~2 GB | 4 GB | 2 GB |
| Storage | ~10 GB | 30 GB | 20 GB |
| Network | <1 Gbps | 5 Gbps | 4+ Gbps |

### Scaling Thresholds

**When to upgrade:**
- CPU consistently >70% → Consider t3.large
- RAM consistently >3 GB → Consider t3.large
- Storage >20 GB → Resize EBS volume
- More than 5-6 apps → Consider t3.large or separate databases

## Monitoring

### CloudWatch Metrics (Free Tier)

- **CPUUtilization** - Target: <70%
- **NetworkIn/NetworkOut** - Monitor for anomalies
- **StatusCheckFailed** - Alert immediately

### Application-Level

Monitor via docker stats or consider adding Prometheus/Grafana if needed:
```bash
docker stats
```

## Backup Strategy

### EBS Snapshots

Create automated EBS snapshots:
- **Frequency**: Daily
- **Retention**: 7 days
- **Schedule**: 3 AM UTC (off-peak)

### Database Backups

Automated via `/opt/platform/database/backup.sh`:
- **Frequency**: Daily (2 AM local)
- **Location**: `/opt/backups/postgres/`
- **Retention**: 7 days

**Off-instance backups** (recommended):
- Sync backups to S3 daily
- Or use RDS automated backups if you migrate to RDS

## Cost Breakdown

| Item | Monthly Cost (USD) |
|------|-------------------|
| EC2 t3.medium (on-demand) | $32.00 |
| EBS gp3 30 GB | $2.40 |
| Data Transfer Out (first 100 GB) | $0.00 |
| Data Transfer Out (>100 GB) | $0.09/GB |
| **Total (base)** | **~$34.40** |

**Potential savings:**
- Reserved Instance (1 year): ~30% discount → ~$24/month
- Reserved Instance (3 years): ~50% discount → ~$16/month

## Disaster Recovery

### Backup Instance

For critical production, consider:
- **Blue-Green Setup**: Two instances, switch DNS during updates
- **Warm Standby**: Backup instance that's off, start when needed
- **Multi-Region**: Secondary instance in another region

### Recovery Time Objective (RTO)

- **From EBS Snapshot**: ~15 minutes
- **From Backup to New Instance**: ~30-60 minutes
- **Full DNS Propagation**: ~5-30 minutes

## Security Best Practices

✅ **Enabled:**
- No SSH access (using SSM)
- Security Group limits to 80/443
- IAM role with minimal permissions
- Automated security updates
- Non-root user (ec2-user)
- Docker containers (isolation)

⚠️ **Consider:**
- Elastic IP (prevents IP changes)
- AWS WAF (if DDoS is a concern)
- CloudWatch alarms for anomalies
- VPC Flow Logs (network monitoring)
- AWS Config (compliance tracking)

---

**Region**: eu-north-1 (Stockholm)
**Pricing**: As of October 2025
**Documentation**: See [SETUP.md](SETUP.md) for deployment guide

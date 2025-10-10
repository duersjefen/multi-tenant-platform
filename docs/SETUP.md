# Server Setup Guide

Complete guide for setting up a new EC2 instance for the multi-tenant platform.

## Prerequisites

- AWS Account with EC2 access
- AWS CLI configured locally (`aws configure`)
- AWS SSM permissions
- GitHub account with access to app repositories

## Step 1: Launch EC2 Instance

### Instance Configuration

1. **Go to EC2 Console** → Launch Instance

2. **Name**: `multi-tenant-platform-v2`

3. **AMI**: Amazon Linux 2023 (latest)
   - Search: "Amazon Linux 2023"
   - Select the official AWS AMI

4. **Instance Type**: t3.medium
   - 2 vCPUs, 4 GB RAM
   - ~$32/month in eu-north-1

5. **Key Pair**: (Optional - we're using SSM)
   - You can select "Proceed without a key pair"
   - SSH not required when using SSM

6. **Network Settings**:
   - VPC: Default VPC
   - Auto-assign public IP: **Enable**
   - Security Group: Create new
     - Name: `multi-tenant-platform-sg`
     - Rules:
       - HTTP (80) from 0.0.0.0/0
       - HTTPS (443) from 0.0.0.0/0
       - **No SSH** (using SSM instead)

7. **Storage**: 30 GB gp3
   - Type: gp3 (General Purpose SSD)
   - Size: 30 GB
   - IOPS: 3000 (default)
   - Throughput: 125 MB/s (default)

8. **Advanced Details**:
   - IAM Instance Profile: **Create new** (see below)
   - User data: (optional, or run setup script later)

### IAM Role Setup

Create an IAM role for the EC2 instance:

1. **Go to IAM Console** → Roles → Create Role

2. **Trusted entity**: AWS service → EC2

3. **Attach policies**:
   - `AmazonSSMManagedInstanceCore` (for SSM access)
   - That's it! (no registry permissions needed)

4. **Role name**: `MultiTenantPlatformEC2Role`

5. **Attach to EC2**: Go back to EC2 → Actions → Security → Modify IAM role → Select the role

### Launch Instance

Click **Launch Instance** and wait for it to start.

Note the **Instance ID** (e.g., `i-0123456789abcdef0`) - you'll need this.

---

## Step 2: Verify SSM Connectivity

From your local machine:

```bash
# Test SSM connection
aws ssm start-session --target i-YOUR-INSTANCE-ID --region eu-north-1

# If successful, you'll see:
# Starting session with SessionId: ...
```

If this fails:
- Check IAM role is attached
- Wait 2-3 minutes for SSM agent to register
- Verify instance has internet access (for SSM endpoints)

---

## Step 3: Clone Platform Repository

```bash
# Connect via SSM
aws ssm start-session --target i-YOUR-INSTANCE-ID --region eu-north-1

# Create platform directory
sudo mkdir -p /opt/platform
sudo chown ec2-user:ec2-user /opt/platform

# Clone repository
cd /opt/platform
git clone https://github.com/duersjefen/multi-tenant-platform.git .

# Verify files
ls -la
```

---

## Step 4: Run Setup Script

```bash
# Run setup script (installs Docker, Docker Compose, creates directories)
sudo bash /opt/platform/scripts/setup-server.sh
```

This script will:
- Update system packages
- Install Docker and Docker Compose
- Configure SSM agent
- Create directory structure
- Setup log rotation
- Configure automated backups

**Reboot recommended** after setup:
```bash
sudo reboot
```

Wait 2-3 minutes, then reconnect via SSM.

---

## Step 5: Configure Environment

```bash
# Create .env file
cd /opt/platform/platform
cp .env.example .env
nano .env
```

Update with your values:
```bash
POSTGRES_USER=platform_admin
POSTGRES_PASSWORD=YOUR_SECURE_PASSWORD_HERE
AWS_REGION=eu-north-1
EC2_INSTANCE_ID=i-YOUR-INSTANCE-ID
```

**⚠️ IMPORTANT:** Use a strong password for PostgreSQL!

---

## Step 6: Start Platform Services

```bash
cd /opt/platform/platform
docker-compose up -d
```

**Check status:**
```bash
docker-compose ps
docker ps
```

You should see:
- `nginx-platform` - running
- `postgres-platform` - running
- `certbot-platform` - running

**Check logs:**
```bash
docker-compose logs -f
```

---

## Step 7: Generate SSL Certificates

For each domain, generate SSL certificates:

```bash
# Production domains
docker run --rm -v certbot-etc:/etc/letsencrypt -v certbot-var:/var/www/certbot \
    certbot/certbot certonly --webroot --webroot-path=/var/www/certbot \
    --email your@email.com --agree-tos --no-eff-email \
    -d paiss.me -d www.paiss.me

docker run --rm -v certbot-etc:/etc/letsencrypt -v certbot-var:/var/www/certbot \
    certbot/certbot certonly --webroot --webroot-path=/var/www/certbot \
    --email your@email.com --agree-tos --no-eff-email \
    -d filter-ical.de -d www.filter-ical.de

docker run --rm -v certbot-etc:/etc/letsencrypt -v certbot-var:/var/www/certbot \
    certbot/certbot certonly --webroot --webroot-path=/var/www/certbot \
    --email your@email.com --agree-tos --no-eff-email \
    -d gabs-massage.de -d www.gabs-massage.de

# Staging domains
docker run --rm -v certbot-etc:/etc/letsencrypt -v certbot-var:/var/www/certbot \
    certbot/certbot certonly --webroot --webroot-path=/var/www/certbot \
    --email your@email.com --agree-tos --no-eff-email \
    -d staging.paiss.me

docker run --rm -v certbot-etc:/etc/letsencrypt -v certbot-var:/var/www/certbot \
    certbot/certbot certonly --webroot --webroot-path=/var/www/certbot \
    --email your@email.com --agree-tos --no-eff-email \
    -d staging.filter-ical.de

docker run --rm -v certbot-etc:/etc/letsencrypt -v certbot-var:/var/www/certbot \
    certbot/certbot certonly --webroot --webroot-path=/var/www/certbot \
    --email your@email.com --agree-tos --no-eff-email \
    -d staging.gabs-massage.de
```

**Reload nginx to use certificates:**
```bash
docker-compose restart nginx
```

---

## Step 8: Deploy Applications

Now deploy your applications. From each app repository (on your local machine):

### Paiss

```bash
cd ~/Documents/Projects/paiss
make deploy-staging
```

### Filter-iCal

```bash
cd ~/Documents/Projects/filter-ical
make deploy-staging
```

### Gabs-Massage

```bash
cd ~/Documents/Projects/gabs-massage
make deploy-staging
```

---

## Step 9: Update DNS

Update DNS A records to point to the new EC2 instance:

1. Get EC2 public IP:
```bash
# From AWS Console or CLI
aws ec2 describe-instances --instance-ids i-YOUR-INSTANCE-ID --region eu-north-1 \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text
```

2. Update DNS records:
   - `paiss.me` → New EC2 IP
   - `www.paiss.me` → New EC2 IP
   - `staging.paiss.me` → New EC2 IP
   - `filter-ical.de` → New EC2 IP
   - `www.filter-ical.de` → New EC2 IP
   - `staging.filter-ical.de` → New EC2 IP
   - `gabs-massage.de` → New EC2 IP
   - `www.gabs-massage.de` → New EC2 IP
   - `staging.gabs-massage.de` → New EC2 IP

3. Wait for DNS propagation (5-30 minutes)

---

## Step 10: Verify Everything Works

Test each domain:

```bash
# From your local machine
curl https://paiss.me
curl https://staging.paiss.me
curl https://filter-ical.de/api/health
curl https://staging.filter-ical.de/api/health
curl https://gabs-massage.de
curl https://staging.gabs-massage.de
```

All should return 200 OK with valid SSL certificates.

---

## Troubleshooting

### SSM Connection Fails

- Check IAM role is attached to instance
- Wait 2-3 minutes for SSM agent to register
- Verify instance has internet access
- Check Security Group allows outbound HTTPS (443)

### Docker Permission Denied

```bash
# Add user to docker group
sudo usermod -a -G docker ec2-user

# Log out and back in
exit
aws ssm start-session --target i-YOUR-INSTANCE-ID --region eu-north-1
```

### Nginx Won't Start

```bash
# Check nginx config
docker exec nginx-platform nginx -t

# Check logs
docker logs nginx-platform
```

### SSL Certificate Generation Fails

- Verify DNS is pointing to correct IP
- Check port 80 is accessible
- Ensure nginx is running
- Check certbot logs: `docker logs certbot-platform`

### App Container Can't Connect to Database

```bash
# Check postgres is running
docker ps | grep postgres

# Check database exists
docker exec -it postgres-platform psql -U platform_admin -l

# Check app is on platform network
docker inspect APP_CONTAINER_NAME | grep NetworkMode
```

---

## Next Steps

- [Add a new app](ADDING_APP.md)
- Monitor logs: `docker-compose logs -f`
- Setup monitoring (optional)
- Configure automated backups off-instance

---

**Need help?** Check logs first, then review this guide step-by-step.

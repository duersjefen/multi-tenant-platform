#!/bin/bash
# =============================================================================
# Multi-Tenant Platform - Server Setup Script
# =============================================================================
# Prepares a fresh Amazon Linux 2023 EC2 instance for multi-tenant hosting
# Run this ONCE after launching a new EC2 instance
# =============================================================================

set -e

echo "🚀 Multi-Tenant Platform - Server Setup"
echo "========================================"
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then
   echo "❌ Please run as root (use sudo)"
   exit 1
fi

# =============================================================================
# 1. System Updates
# =============================================================================
echo "📦 Updating system packages..."
dnf update -y

# =============================================================================
# 2. Install Required Packages
# =============================================================================
echo "📦 Installing Docker and dependencies..."
dnf install -y \
    docker \
    git \
    wget \
    curl \
    amazon-ssm-agent

# =============================================================================
# 3. Start and Enable Docker
# =============================================================================
echo "🐳 Configuring Docker..."
systemctl start docker
systemctl enable docker

# Add ec2-user to docker group
usermod -a -G docker ec2-user

# =============================================================================
# 4. Install Docker Compose
# =============================================================================
echo "🐳 Installing Docker Compose..."
DOCKER_COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep 'tag_name' | cut -d'"' -f4)
curl -L "https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" \
    -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

# Verify installation
docker-compose --version

# =============================================================================
# 5. Start and Enable SSM Agent
# =============================================================================
echo "🔧 Configuring SSM Agent..."
systemctl start amazon-ssm-agent
systemctl enable amazon-ssm-agent

# =============================================================================
# 6. Create Directory Structure
# =============================================================================
echo "📁 Creating directory structure..."
mkdir -p /opt/platform
mkdir -p /opt/apps/{paiss,filter-ical,gabs-massage}
mkdir -p /opt/backups/postgres
mkdir -p /var/log/nginx

# Set ownership
chown -R ec2-user:ec2-user /opt/platform /opt/apps /opt/backups

# =============================================================================
# 7. Configure Log Rotation
# =============================================================================
echo "📋 Configuring log rotation..."
cat > /etc/logrotate.d/nginx-platform << EOF
/var/log/nginx/*.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    sharedscripts
    postrotate
        docker exec nginx-platform nginx -s reload >/dev/null 2>&1 || true
    endscript
}
EOF

# =============================================================================
# 8. Setup Automated Backup Cron
# =============================================================================
echo "🕐 Setting up backup cron job..."
(crontab -l 2>/dev/null; echo "0 2 * * * /opt/platform/database/backup.sh") | crontab -

# =============================================================================
# 9. Configure Firewall (if needed)
# =============================================================================
echo "🔥 Checking firewall status..."
if systemctl is-active --quiet firewalld; then
    echo "  Firewall detected, configuring ports..."
    firewall-cmd --permanent --add-service=http
    firewall-cmd --permanent --add-service=https
    firewall-cmd --reload
else
    echo "  No firewall detected (using Security Groups)"
fi

# =============================================================================
# Completion
# =============================================================================
echo ""
echo "✅ Server setup complete!"
echo ""
echo "📋 Next steps:"
echo "  1. Clone multi-tenant-platform repo:"
echo "     cd /opt/platform"
echo "     git clone https://github.com/duersjefen/multi-tenant-platform.git ."
echo ""
echo "  2. Create .env file with secrets:"
echo "     cp platform/.env.example platform/.env"
echo "     nano platform/.env"
echo ""
echo "  3. Start the platform:"
echo "     cd /opt/platform/platform"
echo "     docker-compose up -d"
echo ""
echo "  4. Test SSM connectivity from your local machine:"
echo "     aws ssm start-session --target INSTANCE_ID --region eu-north-1"
echo ""
echo "  5. Deploy apps via SSM from app repos"
echo ""

#!/bin/bash
# =============================================================================
# Multi-Tenant Platform - Deploy Platform via SSM
# =============================================================================
# Deploys or updates the platform (nginx, postgres, certbot) via AWS SSM
# Usage: ./deploy-platform.sh <instance-id>
# =============================================================================

set -e

# Configuration
REGION="eu-north-1"
INSTANCE_ID="${1}"

if [ -z "$INSTANCE_ID" ]; then
    echo "❌ Usage: ./deploy-platform.sh <instance-id>"
    echo "   Example: ./deploy-platform.sh i-0123456789abcdef0"
    exit 1
fi

echo "🚀 Deploying Multi-Tenant Platform"
echo "===================================="
echo "Instance: $INSTANCE_ID"
echo "Region: $REGION"
echo ""

# =============================================================================
# Deploy via SSM
# =============================================================================
echo "📤 Sending deployment command via SSM..."

aws ssm send-command \
    --region "$REGION" \
    --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --comment "Deploy Multi-Tenant Platform" \
    --parameters 'commands=[
        "set -e",
        "echo \"📥 Pulling latest platform code...\"",
        "cd /opt/platform",
        "git pull origin main",
        "echo \"🐳 Starting platform services...\"",
        "cd /opt/platform/platform",
        "docker-compose pull",
        "docker-compose up -d",
        "echo \"⏳ Waiting for services...\"",
        "sleep 10",
        "echo \"🔍 Checking service health...\"",
        "docker-compose ps",
        "docker ps | grep -E \"nginx-platform|postgres-platform|certbot-platform\"",
        "echo \"✅ Platform deployment complete!\""
    ]' \
    --output text

echo ""
echo "✅ Deployment command sent!"
echo ""
echo "📋 Monitor deployment:"
echo "  aws ssm list-command-invocations --region $REGION --instance-id $INSTANCE_ID --details"
echo ""
echo "Or connect interactively:"
echo "  aws ssm start-session --target $INSTANCE_ID --region $REGION"
echo ""

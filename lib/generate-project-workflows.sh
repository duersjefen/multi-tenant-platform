#!/bin/bash
# =============================================================================
# Generate GitHub Actions Workflows from projects.yml
# =============================================================================
# This script reads projects.yml and generates deployment workflows for
# each project, ensuring consistency and reducing manual configuration.
#
# Usage:
#   ./lib/generate-project-workflows.sh [project-name]
#   ./lib/generate-project-workflows.sh --all
#
# Examples:
#   ./lib/generate-project-workflows.sh physiotherapy-scheduler
#   ./lib/generate-project-workflows.sh --all
# =============================================================================

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

log_info() { echo -e "${BLUE}ℹ${NC}  $1"; }
log_success() { echo -e "${GREEN}✅${NC} $1"; }
log_warning() { echo -e "${YELLOW}⚠️${NC}  $1"; }
log_error() { echo -e "${RED}❌${NC} $1"; }

cd "$PLATFORM_ROOT"

# =============================================================================
# Parse Arguments
# =============================================================================

PROJECT_NAME="${1:-}"

if [ -z "$PROJECT_NAME" ]; then
    log_error "Usage: $0 <project-name|--all>"
    log_info "Example: $0 physiotherapy-scheduler"
    log_info "         $0 --all"
    exit 1
fi

# =============================================================================
# Read projects.yml
# =============================================================================

log_info "Reading projects.yml..."

PROJECTS=$(python3 - "$PROJECT_NAME" <<'PYTHON'
import yaml
import sys

try:
    with open('config/projects.yml', 'r') as f:
        config = yaml.safe_load(f)

    project_arg = sys.argv[1]
    projects = config.get('projects', {})

    if project_arg == '--all':
        # Return all project names
        for name in projects.keys():
            print(name)
    elif project_arg in projects:
        # Return single project
        print(project_arg)
    else:
        print(f"ERROR: Project '{project_arg}' not found in projects.yml", file=sys.stderr)
        sys.exit(1)

except Exception as e:
    print(f"Error: {e}", file=sys.stderr)
    sys.exit(1)
PYTHON
)

if [ $? -ne 0 ]; then
    log_error "Failed to read projects.yml"
    exit 1
fi

# =============================================================================
# Generate Workflows for Each Project
# =============================================================================

for PROJECT in $PROJECTS; do
    log_info "Generating workflows for project: $PROJECT"

    # Extract project configuration
    PROJECT_CONFIG=$(python3 - "$PROJECT" <<'PYTHON'
import yaml
import json
import sys

with open('config/projects.yml', 'r') as f:
    config = yaml.safe_load(f)

project_name = sys.argv[1]
project = config['projects'][project_name]
print(json.dumps(project))
PYTHON
)

    # Extract project details
    PROJECT_REPO=$(echo "$PROJECT_CONFIG" | python3 -c "import sys, json; print(json.load(sys.stdin).get('repository', ''))")

    # Check if project has a repository (required for workflows)
    if [ -z "$PROJECT_REPO" ]; then
        log_warning "$PROJECT: No repository defined, skipping workflow generation"
        continue
    fi

    # Extract repository owner and name
    REPO_OWNER=$(echo "$PROJECT_REPO" | sed 's|https://github.com/||' | cut -d'/' -f1)
    REPO_NAME=$(echo "$PROJECT_REPO" | sed 's|https://github.com/||' | cut -d'/' -f2)

    log_info "$PROJECT: Repository: $REPO_OWNER/$REPO_NAME"

    # Clone or update the project repository
    PROJECT_DIR="/tmp/workflow-gen-$PROJECT"

    if [ -d "$PROJECT_DIR" ]; then
        log_info "$PROJECT: Updating existing clone..."
        cd "$PROJECT_DIR"
        git fetch origin main
        git reset --hard origin/main
    else
        log_info "$PROJECT: Cloning repository..."
        git clone "$PROJECT_REPO" "$PROJECT_DIR"
        cd "$PROJECT_DIR"
    fi

    # Create .github/workflows directory if it doesn't exist
    mkdir -p .github/workflows

    # ==========================================================================
    # Generate deploy-production.yml
    # ==========================================================================

    log_info "$PROJECT: Generating deploy-production.yml..."

    cat > .github/workflows/deploy-production.yml << 'EOF'
name: Deploy to Production

on:
  workflow_dispatch:  # Manual deployment only for production
    inputs:
      confirm:
        description: 'Type "deploy" to confirm production deployment'
        required: true
        default: ''

concurrency:
  group: deploy-production
  cancel-in-progress: false

jobs:
  validate-input:
    name: Validate Deployment Request
    runs-on: ubuntu-latest
    steps:
      - name: ✅ Validate confirmation
        run: |
          if [ "${{ github.event.inputs.confirm }}" != "deploy" ]; then
            echo "❌ Deployment cancelled: confirmation not provided"
            echo "   Please type 'deploy' to confirm"
            exit 1
          fi
          echo "✅ Deployment confirmed"

  deploy:
    name: Deploy to Production
    runs-on: ubuntu-latest
    needs: validate-input
    environment: production

    steps:
      - name: 🔑 Setup SSH
        run: |
          mkdir -p ~/.ssh
          echo "${{ secrets.SSH_PRIVATE_KEY }}" > ~/.ssh/id_rsa
          chmod 600 ~/.ssh/id_rsa
          ssh-keyscan -H ${{ secrets.PRODUCTION_HOST }} >> ~/.ssh/known_hosts

      - name: 📊 Pre-Deployment Status
        env:
          SSH_USER: ${{ secrets.SSH_USER }}
          SSH_HOST: ${{ secrets.PRODUCTION_HOST }}
        run: |
          echo "📊 Current production status:"
          ssh ${SSH_USER}@${SSH_HOST} 'docker ps --filter "name=PROJECT_NAME" --format "{{.Names}}: {{.Status}}"' || echo "No containers running"

      - name: 🚀 Deploy to Production
        env:
          SSH_USER: ${{ secrets.SSH_USER }}
          SSH_HOST: ${{ secrets.PRODUCTION_HOST }}
        run: |
          ssh -i ~/.ssh/id_rsa ${SSH_USER}@${SSH_HOST} << 'REMOTE'
            set -e

            echo "🚀 Starting production deployment..."
            echo "⚠️  PRODUCTION DEPLOYMENT - Extra validation enabled"

            cd /opt/multi-tenant-platform

            # Check disk space
            echo "🔍 Checking disk space..."
            DISK_AVAIL=$(df -h /opt | tail -1 | awk '{print $4}' | sed 's/G//')
            if (( $(echo "$DISK_AVAIL < 5" | bc -l) )); then
              echo "❌ Insufficient disk space: ${DISK_AVAIL}G available (need 5G)"
              exit 1
            fi
            echo "✅ Sufficient disk space: ${DISK_AVAIL}G available"

            # Authenticate to GitHub Container Registry
            echo "🔑 Authenticating to GitHub Container Registry..."
            echo "${{ secrets.GHCR_TOKEN }}" | docker login ghcr.io -u duersjefen --password-stdin

            # Run deployment
            echo "🚢 Deploying PROJECT_NAME to production..."
            PLATFORM_ROOT=/opt/multi-tenant-platform \
            ENVIRONMENT=production \
            ./lib/deploy.sh PROJECT_NAME production

            echo "✅ Deployment complete"
          REMOTE

      - name: 🧪 Run Smoke Tests
        env:
          SSH_USER: ${{ secrets.SSH_USER }}
          SSH_HOST: ${{ secrets.PRODUCTION_HOST }}
        run: |
          echo "🧪 Running smoke tests..."
          sleep 15

          # Test backend health (if exists)
          if ssh ${SSH_USER}@${SSH_HOST} 'docker ps --format "{{.Names}}" | grep -q "PROJECT_NAME-backend-production"'; then
            MAX_RETRIES=6
            RETRY_COUNT=0
            while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
              if ssh ${SSH_USER}@${SSH_HOST} 'docker exec PROJECT_NAME-backend-production curl -f http://localhost:3000/health 2>/dev/null'; then
                echo "✅ Backend is healthy"
                break
              else
                RETRY_COUNT=$((RETRY_COUNT + 1))
                if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
                  echo "❌ Backend health check failed after $MAX_RETRIES attempts"
                  exit 1
                fi
                echo "⏳ Waiting for backend... (attempt $RETRY_COUNT/$MAX_RETRIES)"
                sleep 10
              fi
            done
          fi

          # Test frontend health (if exists)
          if ssh ${SSH_USER}@${SSH_HOST} 'docker ps --format "{{.Names}}" | grep -q "PROJECT_NAME-frontend-production"'; then
            if ! ssh ${SSH_USER}@${SSH_HOST} 'docker exec PROJECT_NAME-frontend-production curl -f http://localhost/health 2>/dev/null || docker exec PROJECT_NAME-frontend-production curl -f http://localhost/ 2>/dev/null'; then
              echo "❌ Frontend health check failed"
              exit 1
            fi
            echo "✅ Frontend is healthy"
          fi

          echo "✅ All smoke tests passed"

      - name: 📢 Deployment Success
        if: success()
        run: |
          echo "## ✅ Production Deployment Successful" >> $GITHUB_STEP_SUMMARY
          echo "" >> $GITHUB_STEP_SUMMARY
          echo "**Project:** PROJECT_NAME" >> $GITHUB_STEP_SUMMARY
          echo "**Environment:** Production" >> $GITHUB_STEP_SUMMARY
          echo "**Commit:** ${{ github.sha }}" >> $GITHUB_STEP_SUMMARY
          echo "**Deployed by:** ${{ github.actor }}" >> $GITHUB_STEP_SUMMARY

      - name: 🔄 Rollback on Failure
        if: failure()
        env:
          SSH_USER: ${{ secrets.SSH_USER }}
          SSH_HOST: ${{ secrets.PRODUCTION_HOST }}
        run: |
          echo "❌ PRODUCTION DEPLOYMENT FAILED!"
          echo "🔄 Initiating automatic rollback..."
          ssh ${SSH_USER}@${SSH_HOST} \
            'cd /opt/multi-tenant-platform && ./lib/rollback.sh PROJECT_NAME production' || true
          echo "🔄 Rollback complete"
          exit 1
EOF

    # Replace PROJECT_NAME placeholder
    sed -i "s/PROJECT_NAME/$PROJECT/g" .github/workflows/deploy-production.yml

    log_success "$PROJECT: deploy-production.yml created"

    # ==========================================================================
    # Generate deploy-staging.yml
    # ==========================================================================

    log_info "$PROJECT: Generating deploy-staging.yml..."

    cat > .github/workflows/deploy-staging.yml << 'EOF'
name: Deploy to Staging

on:
  workflow_run:
    workflows: ["Build and Push Docker Images"]
    types:
      - completed
    branches:
      - main
  workflow_dispatch:  # Allow manual triggers

concurrency:
  group: deploy-staging
  cancel-in-progress: false

jobs:
  deploy:
    name: Deploy to Staging
    runs-on: ubuntu-latest
    if: ${{ github.event.workflow_run.conclusion == 'success' || github.event_name == 'workflow_dispatch' }}

    environment:
      name: staging

    steps:
      - name: 🔑 Setup SSH
        run: |
          mkdir -p ~/.ssh
          echo "${{ secrets.SSH_PRIVATE_KEY }}" > ~/.ssh/id_rsa
          chmod 600 ~/.ssh/id_rsa
          ssh-keyscan -H ${{ secrets.PRODUCTION_HOST }} >> ~/.ssh/known_hosts

      - name: 🚀 Deploy to Staging
        env:
          SSH_USER: ${{ secrets.SSH_USER }}
          SSH_HOST: ${{ secrets.PRODUCTION_HOST }}
        run: |
          ssh -i ~/.ssh/id_rsa ${SSH_USER}@${SSH_HOST} << 'REMOTE'
            set -e
            cd /opt/multi-tenant-platform

            echo "🚀 Deploying PROJECT_NAME to staging..."

            # Authenticate to GitHub Container Registry
            echo "${{ secrets.GHCR_TOKEN }}" | docker login ghcr.io -u duersjefen --password-stdin

            # Run deployment
            PLATFORM_ROOT=/opt/multi-tenant-platform \
            ENVIRONMENT=staging \
            ./lib/deploy.sh PROJECT_NAME staging

            echo "✅ Staging deployment complete"
          REMOTE

      - name: 🧪 Run Smoke Tests
        env:
          SSH_USER: ${{ secrets.SSH_USER }}
          SSH_HOST: ${{ secrets.PRODUCTION_HOST }}
        run: |
          echo "🧪 Running smoke tests..."
          sleep 10

          # Test backend health (if exists)
          if ssh ${SSH_USER}@${SSH_HOST} 'docker ps --format "{{.Names}}" | grep -q "PROJECT_NAME-backend-staging"'; then
            if ! ssh ${SSH_USER}@${SSH_HOST} 'docker exec PROJECT_NAME-backend-staging curl -f http://localhost:3000/health 2>/dev/null'; then
              echo "❌ Backend health check failed"
              exit 1
            fi
            echo "✅ Backend is healthy"
          fi

          # Test frontend health (if exists)
          if ssh ${SSH_USER}@${SSH_HOST} 'docker ps --format "{{.Names}}" | grep -q "PROJECT_NAME-frontend-staging"'; then
            if ! ssh ${SSH_USER}@${SSH_HOST} 'docker exec PROJECT_NAME-frontend-staging curl -f http://localhost/health 2>/dev/null || docker exec PROJECT_NAME-frontend-staging curl -f http://localhost/ 2>/dev/null'; then
              echo "❌ Frontend health check failed"
              exit 1
            fi
            echo "✅ Frontend is healthy"
          fi

          echo "✅ All smoke tests passed"

      - name: 📢 Deployment Success
        if: success()
        run: |
          echo "## ✅ Staging Deployment Successful" >> $GITHUB_STEP_SUMMARY
          echo "" >> $GITHUB_STEP_SUMMARY
          echo "**Project:** PROJECT_NAME" >> $GITHUB_STEP_SUMMARY
          echo "**Environment:** Staging" >> $GITHUB_STEP_SUMMARY
          echo "**Trigger:** ${{ github.event_name }}" >> $GITHUB_STEP_SUMMARY
          echo "**Commit:** ${{ github.sha }}" >> $GITHUB_STEP_SUMMARY

      - name: 🔄 Rollback on Failure
        if: failure()
        env:
          SSH_USER: ${{ secrets.SSH_USER }}
          SSH_HOST: ${{ secrets.PRODUCTION_HOST }}
        run: |
          echo "❌ Deployment failed! Attempting rollback..."
          ssh ${SSH_USER}@${SSH_HOST} \
            'cd /opt/multi-tenant-platform && ./lib/rollback.sh PROJECT_NAME staging' || true
          echo "🔄 Rollback complete"
          exit 1
EOF

    # Replace PROJECT_NAME placeholder
    sed -i "s/PROJECT_NAME/$PROJECT/g" .github/workflows/deploy-staging.yml

    log_success "$PROJECT: deploy-staging.yml created"

    # ==========================================================================
    # Generate Makefile
    # ==========================================================================

    log_info "$PROJECT: Generating Makefile..."

    cat > Makefile << 'EOF'
# =============================================================================
# PROJECT_NAME - Development & Deployment Commands
# =============================================================================
# Generated by: multi-tenant-platform workflow generator
# =============================================================================

.PHONY: help dev build test clean deploy-staging deploy-production status logs

help: ## Show this help message
	@echo "PROJECT_NAME - Available commands:"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

# =============================================================================
# Development
# =============================================================================

dev: ## Start development environment
	docker compose up

build: ## Build Docker image
	docker compose build

test: ## Run tests
	@echo "Running tests..."
	# Add your test command here

clean: ## Clean up development environment
	docker compose down -v

# =============================================================================
# Deployment (triggers GitHub Actions workflows)
# =============================================================================

deploy-staging: ## Deploy to staging environment (triggers workflow)
	@echo "🚀 Triggering staging deployment..."
	gh workflow run deploy-staging.yml
	@echo "✅ Workflow triggered. Monitor: gh run watch"

deploy-production: ## Deploy to production (triggers workflow)
	@echo "🚀 Triggering production deployment..."
	@echo "Version (default: latest): "
	@read VERSION && gh workflow run deploy-production.yml -f version=$${VERSION:-latest}
	@echo "✅ Workflow triggered. Monitor: gh run watch"

# =============================================================================
# Monitoring
# =============================================================================

status: ## Check deployment status
	@echo "📊 Recent workflow runs:"
	@gh run list --limit 5

logs: ## View latest workflow logs
	@gh run view --log

watch: ## Watch latest workflow run
	@gh run watch

# =============================================================================
# Platform Integration
# =============================================================================

platform-logs: ## View container logs on production server
	@echo "📋 Viewing PROJECT_NAME logs..."
	@ssh $$SSH_USER@$$PRODUCTION_HOST "docker logs --tail 100 -f PROJECT_NAME-web"

platform-status: ## Check container status on production server
	@echo "📊 Container status:"
	@ssh $$SSH_USER@$$PRODUCTION_HOST "docker ps --filter name=PROJECT_NAME"

platform-shell: ## SSH into production server
	@ssh $$SSH_USER@$$PRODUCTION_HOST
EOF

    # Replace PROJECT_NAME placeholder
    sed -i "s/PROJECT_NAME/$PROJECT/g" Makefile

    log_success "$PROJECT: Makefile created"

    # ==========================================================================
    # Generate CLAUDE.md Documentation
    # ==========================================================================

    log_info "$PROJECT: Generating CLAUDE.md documentation..."

    # Call the CLAUDE.md generator
    if "$SCRIPT_DIR/generate-project-claude-md.sh" "$PROJECT" "CLAUDE.md" > /dev/null 2>&1; then
        log_success "$PROJECT: CLAUDE.md created"
    else
        log_warning "$PROJECT: Failed to generate CLAUDE.md (continuing anyway)"
    fi

    # ==========================================================================
    # Configure GitHub Secrets (Platform Credentials)
    # ==========================================================================

    log_info "$PROJECT: Configuring GitHub secrets..."

    # Check if gh CLI is available
    if ! command -v gh &> /dev/null; then
        log_warning "$PROJECT: gh CLI not found, skipping secret configuration"
        log_info "Install gh CLI: https://cli.github.com/"
    else
        # Required secrets for deployment
        REQUIRED_SECRETS=("SSH_PRIVATE_KEY" "SSH_USER" "PRODUCTION_HOST")

        # Try to get secrets from environment or SSH config
        declare -A SECRET_VALUES=(
            ["SSH_USER"]="${PLATFORM_SSH_USER:-ec2-user}"
            ["PRODUCTION_HOST"]="${PLATFORM_PRODUCTION_HOST:-13.62.136.72}"
            ["SSH_PRIVATE_KEY"]="${PLATFORM_SSH_PRIVATE_KEY:-}"
        )

        # If SSH_PRIVATE_KEY not in env, try to read from default location
        if [ -z "${SECRET_VALUES[SSH_PRIVATE_KEY]}" ]; then
            if [ -f ~/.ssh/wsl2.pem ]; then
                SECRET_VALUES["SSH_PRIVATE_KEY"]=$(cat ~/.ssh/wsl2.pem)
                log_info "$PROJECT: Using SSH key from ~/.ssh/wsl2.pem"
            elif [ -f ~/.ssh/id_rsa ]; then
                SECRET_VALUES["SSH_PRIVATE_KEY"]=$(cat ~/.ssh/id_rsa)
                log_info "$PROJECT: Using SSH key from ~/.ssh/id_rsa"
            fi
        fi

        for SECRET_NAME in "${REQUIRED_SECRETS[@]}"; do
            SECRET_VALUE="${SECRET_VALUES[$SECRET_NAME]}"

            # Check if secret already exists in project repo
            if gh secret list --repo "$REPO_OWNER/$REPO_NAME" 2>/dev/null | grep -q "^$SECRET_NAME"; then
                log_success "$PROJECT: $SECRET_NAME already configured (skipping)"
                continue
            fi

            if [ -z "$SECRET_VALUE" ]; then
                log_warning "$PROJECT: No value for $SECRET_NAME"
                log_info "Set via environment: export PLATFORM_${SECRET_NAME}='value'"
                log_info "Or manually: gh secret set $SECRET_NAME --repo $REPO_OWNER/$REPO_NAME"
                continue
            fi

            # Set secret in project repository
            log_info "$PROJECT: Setting secret: $SECRET_NAME"
            if echo "$SECRET_VALUE" | gh secret set "$SECRET_NAME" --repo "$REPO_OWNER/$REPO_NAME" 2>/dev/null; then
                log_success "$PROJECT: $SECRET_NAME configured ✓"
            else
                log_warning "$PROJECT: Failed to set $SECRET_NAME (may need repo admin access)"
            fi
        done

        log_success "$PROJECT: GitHub secrets configuration complete"
    fi

    # ==========================================================================
    # Commit and Push (if changes detected)
    # ==========================================================================

    # Check for both modified and untracked files
    git add .github/workflows/ Makefile CLAUDE.md

    if ! git diff --cached --quiet; then
        log_info "$PROJECT: Committing workflow changes..."

        git commit -m "chore: Add auto-generated deployment automation

Generated by: lib/generate-project-workflows.sh
From: multi-tenant-platform projects.yml

Added:
- .github/workflows/deploy-production.yml (manual deployment)
- .github/workflows/deploy-staging.yml (automatic on push to main)
- Makefile (dev & deployment commands)
- CLAUDE.md (comprehensive development guide)

Features:
- Automatic staging deployment on push
- Manual production deployment with version control
- GitHub secrets auto-configured
- Platform integration commands
- PostgreSQL + Alembic migration workflow
- TDD and contract-driven development patterns

Documentation:
  cat CLAUDE.md          # Read comprehensive development guide

Usage:
  make help              # Show all commands
  make deploy-staging    # Trigger staging deployment
  make deploy-production # Trigger production deployment
  make status            # Check deployment status

These workflows integrate with the multi-tenant platform
deployment system (lib/deploy.sh)."

        log_info "$PROJECT: Pushing to GitHub..."
        git push origin main

        log_success "$PROJECT: Workflows pushed to GitHub"
    else
        log_info "$PROJECT: No changes to workflows"
    fi

    cd "$PLATFORM_ROOT"

    echo ""
done

log_success "Workflow generation complete!"


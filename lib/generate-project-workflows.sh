#!/bin/bash
# =============================================================================
# Generate GitHub Actions Workflows for Platform-Driven Deployment
# =============================================================================
# This script generates workflows that integrate with the platform-driven
# deployment architecture where the platform repo orchestrates all deployments.
#
# Usage:
#   ./lib/generate-project-workflows.sh [project-name]
#   ./lib/generate-project-workflows.sh --all
#
# What it generates:
#   - build-and-push.yml: Builds images and notifies platform
#   - Makefile: Platform-integrated development commands
#
# What it DOESN'T generate (handled by platform):
#   - deploy-staging.yml (replaced by platform's deploy-project.yml)
#   - deploy-production.yml (replaced by platform's deploy-project.yml)
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
    log_info "Example: $0 filter-ical"
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
        for name in projects.keys():
            print(name)
    elif project_arg in projects:
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

    if [ -z "$PROJECT_REPO" ]; then
        log_warning "$PROJECT: No repository defined, skipping"
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

    # Create .github/workflows directory
    mkdir -p .github/workflows

    # ==========================================================================
    # Generate build-and-push.yml (ONLY workflow needed in app repo)
    # ==========================================================================

    log_info "$PROJECT: Generating build-and-push.yml..."

    cat > .github/workflows/build-and-push.yml << 'EOF'
name: Build and Push Docker Images

on:
  push:
    branches: [main]
    tags: ['v*']
  workflow_dispatch:

env:
  REGISTRY: ghcr.io
  IMAGE_NAME_BACKEND: REPO_OWNER/PROJECT_NAME-backend
  IMAGE_NAME_FRONTEND: REPO_OWNER/PROJECT_NAME-frontend

jobs:
  build-and-push:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write

    steps:
      - name: Checkout repository
        uses: actions/checkout@v4

      - name: Log in to Container Registry
        uses: docker/login-action@v3
        with:
          registry: ${{ env.REGISTRY }}
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Extract metadata for backend
        id: meta-backend
        uses: docker/metadata-action@v5
        with:
          images: ${{ env.REGISTRY }}/${{ env.IMAGE_NAME_BACKEND }}
          tags: |
            type=ref,event=branch
            type=ref,event=pr
            type=semver,pattern={{version}}
            type=semver,pattern={{major}}.{{minor}}
            type=sha,prefix={{branch}}-
            type=raw,value=latest,enable={{is_default_branch}}

      - name: Extract metadata for frontend
        id: meta-frontend
        uses: docker/metadata-action@v5
        with:
          images: ${{ env.REGISTRY }}/${{ env.IMAGE_NAME_FRONTEND }}
          tags: |
            type=ref,event=branch
            type=ref,event=pr
            type=semver,pattern={{version}}
            type=semver,pattern={{major}}.{{minor}}
            type=sha,prefix={{branch}}-
            type=raw,value=latest,enable={{is_default_branch}}

      - name: Build and push backend image
        uses: docker/build-push-action@v5
        with:
          context: ./backend
          file: ./backend/Dockerfile
          push: true
          tags: ${{ steps.meta-backend.outputs.tags }}
          labels: ${{ steps.meta-backend.outputs.labels }}

      - name: Build and push frontend image
        uses: docker/build-push-action@v5
        with:
          context: ./frontend
          file: ./frontend/Dockerfile
          push: true
          tags: ${{ steps.meta-frontend.outputs.tags }}
          labels: ${{ steps.meta-frontend.outputs.labels }}

      - name: 📢 Image tags
        run: |
          echo "Backend images:"
          echo "${{ steps.meta-backend.outputs.tags }}"
          echo ""
          echo "Frontend images:"
          echo "${{ steps.meta-frontend.outputs.tags }}"
          echo ""
          echo "✅ Images pushed to GitHub Container Registry"

      - name: 🚀 Notify platform repo to deploy
        if: github.ref == 'refs/heads/main'
        env:
          GH_TOKEN: ${{ secrets.PLATFORM_DEPLOY_TOKEN }}
        run: |
          echo "📢 Notifying platform repo of new images..."
          gh api repos/REPO_OWNER/multi-tenant-platform/dispatches \
            -f event_type="new-image" \
            -f client_payload[project]="PROJECT_NAME" \
            -f client_payload[sha]="${{ github.sha }}" \
            -f client_payload[actor]="${{ github.actor }}" \
            -f client_payload[backend_tag]="latest" \
            -f client_payload[frontend_tag]="latest"
          echo "✅ Platform will deploy to staging automatically"
          echo "👀 Monitor: https://github.com/REPO_OWNER/multi-tenant-platform/actions"
EOF

    # Replace placeholders
    sed -i "s/PROJECT_NAME/$PROJECT/g" .github/workflows/build-and-push.yml
    sed -i "s/REPO_OWNER/$REPO_OWNER/g" .github/workflows/build-and-push.yml

    log_success "$PROJECT: build-and-push.yml created"

    # ==========================================================================
    # Clean up old deployment workflows (if they exist)
    # ==========================================================================

    if [ -f .github/workflows/deploy-staging.yml ]; then
        log_info "$PROJECT: Removing old deploy-staging.yml..."
        rm .github/workflows/deploy-staging.yml
        log_success "$PROJECT: Old deploy-staging.yml removed"
    fi

    if [ -f .github/workflows/deploy-production.yml ]; then
        log_info "$PROJECT: Removing old deploy-production.yml..."
        rm .github/workflows/deploy-production.yml
        log_success "$PROJECT: Old deploy-production.yml removed"
    fi

    # ==========================================================================
    # Generate Platform-Integrated Makefile
    # ==========================================================================

    log_info "$PROJECT: Generating Makefile..."

    cat > Makefile << 'EOF'
# =============================================================================
# PROJECT_NAME - Development & Deployment Commands
# =============================================================================
# Platform-Driven Deployment Architecture
# Application builds images, platform orchestrates deployment
# =============================================================================

.PHONY: help setup dev test clean deploy-staging deploy-production status

help: ## Show this help message
	@echo "PROJECT_NAME - Available commands:"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

# =============================================================================
# Development
# =============================================================================

setup: ## Install all dependencies
	@echo "📦 Setting up development environment..."
	# Add your setup commands here

dev: ## Start development environment
	@echo "🚀 Starting development..."
	docker compose up

test: ## Run tests
	@echo "🧪 Running tests..."
	# Add your test commands here

clean: ## Clean up development environment
	docker compose down -v

# =============================================================================
# Deployment (Platform-Driven)
# =============================================================================

deploy-staging: ## Deploy to staging (builds image + platform deploys)
	@echo "🎭 Deploying to staging..."
	@echo ""
	@echo "ℹ️  NOTE: Deployment is now managed by the platform repo"
	@echo ""
	@echo "📋 Checking git status..."
	@if [ -n "$$(git status --porcelain)" ]; then \
		echo "⚠️  You have uncommitted changes. Commit first:"; \
		echo "   git add . && git commit -m 'Your message'"; \
		exit 1; \
	fi
	@echo "📤 Pushing to main (triggers build + auto-deploy)..."
	@git push origin main
	@echo ""
	@echo "🔄 Build pipeline:"
	@echo "  1. Build Docker images (PROJECT_NAME repo)"
	@echo "  2. Notify platform repo"
	@echo "  3. Platform deploys to staging"
	@echo ""
	@echo "👀 Monitor build: https://github.com/REPO_OWNER/PROJECT_NAME/actions"
	@echo "👀 Monitor deploy: https://github.com/REPO_OWNER/multi-tenant-platform/actions"

deploy-production: ## Deploy to production (via platform repo)
	@echo "🚀 Deploying to production..."
	@echo ""
	@echo "ℹ️  NOTE: Production deployment is managed by platform repo"
	@echo ""
	@echo "📖 To deploy to production:"
	@echo "  1. Ensure staging is working"
	@echo "  2. cd ../multi-tenant-platform"
	@echo "  3. make promote project=PROJECT_NAME"
	@echo ""
	@echo "Or trigger manually:"
	@echo "  cd ../multi-tenant-platform"
	@echo "  make trigger-deploy project=PROJECT_NAME env=production"
	@echo ""
	@exit 1

status: ## Check deployment status
	@echo "📊 Deployment status:"
	@echo ""
	@echo "Recent builds:"
	@gh run list --limit 5 --repo REPO_OWNER/PROJECT_NAME
	@echo ""
	@echo "Recent deployments:"
	@gh run list --limit 5 --repo REPO_OWNER/multi-tenant-platform --workflow deploy-project.yml

# =============================================================================
# Monitoring
# =============================================================================

logs: ## View workflow logs
	@gh run view --log

watch: ## Watch latest workflow run
	@gh run watch
EOF

    # Replace placeholders
    sed -i "s/PROJECT_NAME/$PROJECT/g" Makefile
    sed -i "s/REPO_OWNER/$REPO_OWNER/g" Makefile

    log_success "$PROJECT: Makefile created"

    # ==========================================================================
    # Commit and Push
    # ==========================================================================

    git add .github/workflows/ Makefile

    if ! git diff --cached --quiet; then
        log_info "$PROJECT: Committing workflow changes..."

        git commit -m "refactor: Migrate to platform-driven deployment architecture

Generated by: lib/generate-project-workflows.sh
From: multi-tenant-platform projects.yml

Changes:
- Replaced deploy-staging.yml with platform-driven deployment
- Replaced deploy-production.yml with platform-driven deployment
- Updated build-and-push.yml to notify platform repo
- Updated Makefile with platform-integrated commands

Architecture:
- Application repo: Builds images and notifies platform
- Platform repo: Orchestrates all deployments
- Source of truth: Platform repo (configs, env vars)

Benefits:
- Config changes deployable without rebuilding images
- Consistent deployment across all projects
- GitOps compliance (git history tracks deployments)
- Scalable to any number of projects

Documentation:
  See: multi-tenant-platform/docs/DEPLOYMENT_ARCHITECTURE.md

Usage:
  make deploy-staging    # Push code → platform deploys
  make status            # Check deployment status

  # For production:
  cd ../multi-tenant-platform
  make promote project=$PROJECT"

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
log_info ""
log_info "Next steps:"
log_info "1. Ensure PLATFORM_DEPLOY_TOKEN secret is set in each app repo"
log_info "2. Test deployment: make deploy project=<name> env=staging"
log_info "3. Monitor: https://github.com/$REPO_OWNER/multi-tenant-platform/actions"

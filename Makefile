# =============================================================================
# Multi-Tenant Platform - Makefile
# =============================================================================
# Convenient commands for local platform management and deployment
# =============================================================================

# SSH Configuration (uses local SSH config)
SSH_KEY := ~/.ssh/wsl2.pem
SSH_USER := ec2-user
SSH_HOST := 13.62.136.72
REMOTE_PATH := /opt/multi-tenant-platform

# Colors for output
GREEN := \033[0;32m
YELLOW := \033[0;33m
RED := \033[0;31m
NC := \033[0m # No Color

.PHONY: help
help: ## Show this help message
	@echo "$(GREEN)Multi-Tenant Platform Management$(NC)"
	@echo ""
	@echo "Usage: make [target]"
	@echo ""
	@echo "$(YELLOW)Platform Deployment:$(NC)"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  $(GREEN)%-25s$(NC) %s\n", $$1, $$2}'

# =============================================================================
# LOCAL TESTING
# =============================================================================

.PHONY: test
test: ## Run all platform tests locally
	@echo "$(YELLOW)Running platform tests...$(NC)"
	./lib/test-platform.sh

.PHONY: test-nginx
test-nginx: ## Test nginx configuration locally
	@echo "$(YELLOW)Testing nginx configuration...$(NC)"
	docker run --rm \
		-v $(PWD)/platform/nginx/nginx.conf:/etc/nginx/nginx.conf:ro \
		-v $(PWD)/platform/nginx/includes:/etc/nginx/includes:ro \
		-v $(PWD)/platform/nginx/conf.d:/etc/nginx/conf.d:ro \
		nginx:alpine nginx -t

.PHONY: test-staging
test-staging: ## Test nginx in staging mode (port 8443)
	@echo "$(YELLOW)Starting staging nginx on port 8443...$(NC)"
	./lib/test-nginx-staging.sh start
	@echo "$(GREEN)Test at: https://localhost:8443$(NC)"
	@echo "Run 'make stop-staging' when done"

.PHONY: stop-staging
stop-staging: ## Stop staging nginx container
	@echo "$(YELLOW)Stopping staging nginx...$(NC)"
	./lib/test-nginx-staging.sh stop

.PHONY: validate
validate: ## Validate all hosted projects are accessible
	@echo "$(YELLOW)Validating all projects...$(NC)"
	@ssh -i $(SSH_KEY) $(SSH_USER)@$(SSH_HOST) "cd $(REMOTE_PATH) && ./lib/validate-all-projects.sh"

.PHONY: generate-configs
generate-configs: ## Generate nginx configs from projects.yml
	@echo "$(YELLOW)Generating nginx configurations...$(NC)"
	python3 lib/generate-nginx-configs.py

# =============================================================================
# REMOTE STAGING MANAGEMENT
# =============================================================================

.PHONY: staging-start
staging-start: ## Start staging nginx on production server (port 8443)
	@echo "$(YELLOW)Starting remote staging nginx on port 8443...$(NC)"
	@ssh -i $(SSH_KEY) $(SSH_USER)@$(SSH_HOST) \
		"cd $(REMOTE_PATH) && docker compose -f platform/docker-compose.platform.yml up -d nginx-staging"
	@echo "$(GREEN)✅ Staging running at: https://$(SSH_HOST):8443$(NC)"

.PHONY: staging-stop
staging-stop: ## Stop staging nginx on production server
	@echo "$(YELLOW)Stopping remote staging nginx...$(NC)"
	@ssh -i $(SSH_KEY) $(SSH_USER)@$(SSH_HOST) \
		"docker rm -f platform-nginx-staging"

.PHONY: staging-logs
staging-logs: ## View staging nginx logs
	@ssh -i $(SSH_KEY) $(SSH_USER)@$(SSH_HOST) "docker logs -f --tail 50 platform-nginx-staging"

.PHONY: staging-test
staging-test: ## Test staging nginx on production server
	@echo "$(YELLOW)Testing staging nginx...$(NC)"
	@curl -k -sI https://$(SSH_HOST):8443 | head -10 || echo "$(RED)Failed to connect$(NC)"

# =============================================================================
# PRODUCTION DEPLOYMENT
# =============================================================================

.PHONY: deploy-nginx
deploy-nginx: ## Deploy nginx safely (staging-first with validation)
	@echo "$(YELLOW)Safe deployment: staging → test → production$(NC)"
	@ssh -i $(SSH_KEY) $(SSH_USER)@$(SSH_HOST) "cd $(REMOTE_PATH) && ./lib/deploy-platform-safe.sh nginx"

.PHONY: deploy-nginx-force
deploy-nginx-force: ## Deploy nginx with automatic promotion (skip manual approval)
	@echo "$(YELLOW)Force deploying platform nginx...$(NC)"
	@ssh -i $(SSH_KEY) $(SSH_USER)@$(SSH_HOST) "cd $(REMOTE_PATH) && ./lib/deploy-platform-safe.sh nginx --force"

.PHONY: deploy-nginx-legacy
deploy-nginx-legacy: ## Deploy nginx the old way (direct to production, riskier)
	@echo "$(RED)⚠️  Legacy deployment - no staging validation!$(NC)"
	@ssh -i $(SSH_KEY) $(SSH_USER)@$(SSH_HOST) "cd $(REMOTE_PATH) && ./lib/deploy-platform.sh nginx"

.PHONY: deploy-monitoring
deploy-monitoring: ## Deploy monitoring stack (Prometheus, Grafana, Alertmanager)
	@echo "$(YELLOW)Deploying monitoring stack...$(NC)"
	@ssh -i $(SSH_KEY) $(SSH_USER)@$(SSH_HOST) "cd $(REMOTE_PATH) && ./lib/deploy-platform.sh monitoring"

.PHONY: deploy-certbot
deploy-certbot: ## Deploy certbot for SSL certificate management
	@echo "$(YELLOW)Deploying certbot...$(NC)"
	@ssh -i $(SSH_KEY) $(SSH_USER)@$(SSH_HOST) "cd $(REMOTE_PATH) && ./lib/deploy-platform.sh certbot"

.PHONY: deploy-all
deploy-all: ## Deploy entire platform (nginx, monitoring, certbot)
	@echo "$(YELLOW)Deploying entire platform...$(NC)"
	@ssh -i $(SSH_KEY) $(SSH_USER)@$(SSH_HOST) "cd $(REMOTE_PATH) && ./lib/deploy-platform.sh all"

.PHONY: deploy-quick
deploy-quick: ## Quick deployment: pull changes and reload nginx (zero-downtime)
	@echo "$(YELLOW)Quick deployment (pull + reload nginx)...$(NC)"
	@ssh -i $(SSH_KEY) $(SSH_USER)@$(SSH_HOST) "cd $(REMOTE_PATH) && git pull origin main && docker exec platform-nginx nginx -t && docker exec platform-nginx nginx -s reload && echo '$(GREEN)✅ Nginx reloaded successfully$(NC)'"

# =============================================================================
# PROJECT DEPLOYMENT (Platform-Driven)
# =============================================================================

.PHONY: deploy
deploy: ## Deploy project (usage: make deploy project=filter-ical env=staging)
	@test -n "$(project)" || (echo "$(RED)❌ Missing project=<name>$(NC)"; echo "Usage: make deploy project=filter-ical env=staging"; exit 1)
	@test -n "$(env)" || (echo "$(RED)❌ Missing env=<staging|production>$(NC)"; exit 1)
	@echo "$(YELLOW)🚀 Deploying $(project) to $(env)...$(NC)"
	@ssh -i $(SSH_KEY) $(SSH_USER)@$(SSH_HOST) "cd /opt/multi-tenant-platform && git pull origin main && PLATFORM_ROOT=/opt/multi-tenant-platform ENVIRONMENT=$(env) ./lib/deploy.sh $(project) $(env)"

.PHONY: redeploy
redeploy: ## Redeploy with current configs (usage: make redeploy project=filter-ical env=staging)
	@test -n "$(project)" || (echo "$(RED)❌ Missing project=<name>$(NC)"; exit 1)
	@test -n "$(env)" || (echo "$(RED)❌ Missing env=<staging|production>$(NC)"; exit 1)
	@echo "$(YELLOW)🔄 Redeploying $(project) $(env) with current configs...$(NC)"
	@ssh -i $(SSH_KEY) $(SSH_USER)@$(SSH_HOST) "cd $(REMOTE_PATH) && cd configs/$(project) && ENVIRONMENT=$(env) docker-compose pull && cd $(REMOTE_PATH) && PLATFORM_ROOT=$(REMOTE_PATH) ENVIRONMENT=$(env) ./lib/deploy.sh $(project) $(env)"

.PHONY: trigger-deploy
trigger-deploy: ## Trigger deployment via GitHub Actions (usage: make trigger-deploy project=filter-ical env=staging)
	@test -n "$(project)" || (echo "$(RED)❌ Missing project=<name>$(NC)"; exit 1)
	@test -n "$(env)" || (echo "$(RED)❌ Missing env=<staging|production>$(NC)"; exit 1)
	@echo "$(YELLOW)🚀 Triggering deployment via GitHub Actions...$(NC)"
	@gh workflow run deploy-project.yml \
		-f project=$(project) \
		-f environment=$(env) \
		--repo duersjefen/multi-tenant-platform
	@echo "$(GREEN)✅ Workflow triggered$(NC)"
	@if [ "$(env)" = "staging" ]; then \
		echo ""; \
		echo "$(YELLOW)ℹ️  Staging deployment will auto-queue production (requires approval)$(NC)"; \
		echo "$(YELLOW)Approve with: make approve-production project=$(project)$(NC)"; \
	fi
	@echo "$(YELLOW)👀 Monitor at: https://github.com/duersjefen/multi-tenant-platform/actions$(NC)"

.PHONY: promote
promote: ## Promote staging config to production (usage: make promote project=filter-ical)
	@test -n "$(project)" || (echo "$(RED)❌ Missing project=<name>$(NC)"; exit 1)
	@echo "$(YELLOW)📈 Promoting $(project) staging → production$(NC)"
	@echo ""
	@echo "This will:"
	@echo "  1. Copy staging env vars → production env vars"
	@echo "  2. Commit and push (triggers staging deploy)"
	@echo "  3. Production deployment auto-queues (requires approval)"
	@echo ""
	@read -p "Continue? [y/N] " confirm; \
	if [ "$$confirm" != "y" ] && [ "$$confirm" != "Y" ]; then \
		echo "$(YELLOW)Cancelled$(NC)"; \
		exit 0; \
	fi
	@if [ ! -f configs/$(project)/.env.staging ]; then \
		echo "$(RED)❌ configs/$(project)/.env.staging not found$(NC)"; \
		exit 1; \
	fi
	@echo "$(YELLOW)Copying staging config to production...$(NC)"
	@cp configs/$(project)/.env.staging configs/$(project)/.env.production
	@git add configs/$(project)/.env.production
	@git commit -m "Promote $(project): staging → production" || (echo "$(YELLOW)No changes to commit$(NC)"; exit 0)
	@git push origin main
	@echo "$(GREEN)✅ Promotion committed$(NC)"
	@echo ""
	@echo "$(YELLOW)🔄 Continuous deployment pipeline starting...$(NC)"
	@echo "  1. Deploy to staging ✅"
	@echo "  2. Auto-queue production ⏸️  (waiting for approval)"
	@echo ""
	@echo "$(YELLOW)Approve with: make approve-production project=$(project)$(NC)"
	@echo "$(YELLOW)Or monitor at: https://github.com/duersjefen/multi-tenant-platform/actions$(NC)"

.PHONY: approve-production
approve-production: ## Approve pending production deployment (usage: make approve-production project=filter-ical)
	@test -n "$(project)" || (echo "$(RED)❌ Missing project=<name>$(NC)"; exit 1)
	@echo "$(YELLOW)🔍 Looking for pending production deployments for $(project)...$(NC)"
	@echo ""
	@gh run list --repo duersjefen/multi-tenant-platform \
		--workflow "Deploy Project" \
		--status waiting \
		--limit 10 \
		--json databaseId,displayTitle,createdAt,url \
		--jq '.[] | "\(.databaseId)\t\(.displayTitle)\t\(.createdAt)"' | \
		grep -i "$(project)" | head -5 || (echo "$(YELLOW)No pending deployments found for $(project)$(NC)"; exit 1)
	@echo ""
	@read -p "Enter run ID to approve (or 'q' to quit): " run_id; \
	if [ "$$run_id" = "q" ]; then \
		echo "$(YELLOW)Cancelled$(NC)"; \
		exit 0; \
	fi; \
	echo "$(YELLOW)Watching deployment $$run_id (will prompt for approval)...$(NC)"; \
	gh run watch $$run_id --repo duersjefen/multi-tenant-platform

.PHONY: deployment-status
deployment-status: ## Show deployment status for project (usage: make deployment-status project=filter-ical env=staging)
	@test -n "$(project)" || (echo "$(RED)❌ Missing project=<name>$(NC)"; exit 1)
	@test -n "$(env)" || (echo "$(RED)❌ Missing env=<staging|production>$(NC)"; exit 1)
	@echo "$(YELLOW)📊 Deployment status: $(project) ($(env))$(NC)"
	@ssh -i $(SSH_KEY) $(SSH_USER)@$(SSH_HOST) \
		"cd $(REMOTE_PATH) && ./lib/deployment-status.sh $(project) $(env)"

# =============================================================================
# ROLLBACK & RECOVERY
# =============================================================================

.PHONY: rollback-nginx
rollback-nginx: ## Rollback nginx to previous version
	@echo "$(RED)Rolling back nginx...$(NC)"
	@ssh -i $(SSH_KEY) $(SSH_USER)@$(SSH_HOST) <<-'ENDSSH'
		cd $(REMOTE_PATH)
		# Find latest backup
		BACKUP=$$(docker images --format "{{.Repository}}:{{.Tag}}" | grep platform-nginx-backup | head -1)
		if [ -z "$$BACKUP" ]; then
			echo "$(RED)❌ No backup found$(NC)"
			exit 1
		fi
		echo "$(YELLOW)Restoring from: $$BACKUP$(NC)"
		# Stop current nginx
		docker stop platform-nginx && docker rm platform-nginx
		# Start from backup
		docker run -d \
			--name platform-nginx \
			--restart unless-stopped \
			--network platform \
			-p 80:80 -p 443:443/tcp -p 443:443/udp \
			-v /opt/multi-tenant-platform/platform/nginx/nginx.conf:/etc/nginx/nginx.conf:ro \
			-v /opt/multi-tenant-platform/platform/nginx/includes:/etc/nginx/includes:ro \
			-v /opt/multi-tenant-platform/platform/nginx/conf.d:/etc/nginx/conf.d:ro \
			-v platform-certbot-certs:/etc/letsencrypt:ro \
			-v platform-certbot-www:/var/www/certbot:ro \
			-v platform-nginx-logs:/var/log/nginx \
			$$BACKUP
		echo "$(GREEN)✅ Nginx rolled back successfully$(NC)"
	ENDSSH

.PHONY: list-backups
list-backups: ## List available nginx backup images
	@echo "$(YELLOW)Available nginx backups:$(NC)"
	@ssh -i $(SSH_KEY) $(SSH_USER)@$(SSH_HOST) \
		"docker images --format 'table {{.Repository}}\t{{.Tag}}\t{{.CreatedAt}}\t{{.Size}}' | grep -E '(REPOSITORY|nginx-backup)'"

# =============================================================================
# MONITORING & LOGS
# =============================================================================

.PHONY: logs-nginx
logs-nginx: ## Tail nginx logs (live)
	@ssh -i $(SSH_KEY) $(SSH_USER)@$(SSH_HOST) "docker logs -f --tail 100 platform-nginx"

.PHONY: logs-prometheus
logs-prometheus: ## Tail Prometheus logs
	@ssh -i $(SSH_KEY) $(SSH_USER)@$(SSH_HOST) "docker logs -f --tail 100 platform-prometheus"

.PHONY: logs-grafana
logs-grafana: ## Tail Grafana logs
	@ssh -i $(SSH_KEY) $(SSH_USER)@$(SSH_HOST) "docker logs -f --tail 100 platform-grafana"

.PHONY: status
status: ## Show status of all platform containers
	@echo "$(YELLOW)Platform container status:$(NC)"
	@ssh -i $(SSH_KEY) $(SSH_USER)@$(SSH_HOST) \
		"docker ps --filter 'name=platform-' --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'"

.PHONY: health
health: ## Check health of all platform services
	@echo "$(YELLOW)Platform health check:$(NC)"
	@ssh -i $(SSH_KEY) $(SSH_USER)@$(SSH_HOST) "docker inspect platform-nginx platform-prometheus platform-grafana --format='{{.Name}}: {{if .State.Health}}{{.State.Health.Status}}{{else}}no healthcheck{{end}}'"

# =============================================================================
# SSH & REMOTE ACCESS
# =============================================================================

.PHONY: ssh
ssh: ## SSH into production server
	@ssh -i $(SSH_KEY) $(SSH_USER)@$(SSH_HOST)

.PHONY: ssh-nginx
ssh-nginx: ## Open shell in nginx container
	@ssh -i $(SSH_KEY) $(SSH_USER)@$(SSH_HOST) "docker exec -it platform-nginx /bin/sh"

.PHONY: sync-to-remote
sync-to-remote: ## Sync local changes to production server (dangerous!)
	@echo "$(RED)⚠️  This will overwrite files on production!$(NC)"
	@read -p "Are you sure? [y/N] " -n 1 -r; \
	if [[ $$REPLY =~ ^[Yy]$$ ]]; then \
		echo ""; \
		rsync -avz --exclude='.git' --exclude='node_modules' \
			-e "ssh -i $(SSH_KEY)" \
			./platform/ $(SSH_USER)@$(SSH_HOST):$(REMOTE_PATH)/platform/; \
		echo "$(GREEN)✅ Files synced$(NC)"; \
	else \
		echo ""; \
		echo "$(YELLOW)Cancelled$(NC)"; \
	fi

.PHONY: pull-from-remote
pull-from-remote: ## Pull production configs to local (backup)
	@echo "$(YELLOW)Pulling production configs...$(NC)"
	@rsync -avz -e "ssh -i $(SSH_KEY)" \
		$(SSH_USER)@$(SSH_HOST):$(REMOTE_PATH)/platform/nginx/conf.d/ \
		./backups/nginx-conf.d-$$(date +%Y%m%d-%H%M%S)/
	@echo "$(GREEN)✅ Configs backed up locally$(NC)"

# =============================================================================
# GIT OPERATIONS
# =============================================================================

.PHONY: git-status
git-status: ## Check git status on production server
	@echo "$(YELLOW)Production git status:$(NC)"
	@ssh -i $(SSH_KEY) $(SSH_USER)@$(SSH_HOST) "cd $(REMOTE_PATH) && git status"

.PHONY: git-pull
git-pull: ## Pull latest changes on production server
	@echo "$(YELLOW)Pulling latest changes on production...$(NC)"
	@ssh -i $(SSH_KEY) $(SSH_USER)@$(SSH_HOST) "cd $(REMOTE_PATH) && git pull origin main"

# =============================================================================
# MAINTENANCE
# =============================================================================

.PHONY: cleanup-images
cleanup-images: ## Clean up old Docker images (keep latest 3 backups)
	@echo "$(YELLOW)Cleaning up old backup images...$(NC)"
	@ssh -i $(SSH_KEY) $(SSH_USER)@$(SSH_HOST) "docker images --format '{{.Repository}}:{{.Tag}}' | grep platform-nginx-backup | tail -n +4 | xargs -r docker rmi && echo '$(GREEN)✅ Cleanup complete$(NC)'"

.PHONY: restart-nginx
restart-nginx: ## Restart nginx container (brief downtime)
	@echo "$(YELLOW)Restarting nginx...$(NC)"
	@ssh -i $(SSH_KEY) $(SSH_USER)@$(SSH_HOST) "docker restart platform-nginx"

.PHONY: reload-nginx
reload-nginx: ## Reload nginx config (zero downtime)
	@echo "$(YELLOW)Reloading nginx configuration...$(NC)"
	@ssh -i $(SSH_KEY) $(SSH_USER)@$(SSH_HOST) \
		"docker exec platform-nginx nginx -t && docker exec platform-nginx nginx -s reload"

.PHONY: provision-ssl
provision-ssl: ## Auto-provision missing SSL certificates from projects.yml
	@echo "$(YELLOW)Provisioning SSL certificates...$(NC)"
	@ssh -i $(SSH_KEY) $(SSH_USER)@$(SSH_HOST) \
		"cd $(REMOTE_PATH) && ./lib/provision-ssl-certs.sh"

.PHONY: provision-ssl-dry-run
provision-ssl-dry-run: ## Preview SSL certificates that would be provisioned
	@echo "$(YELLOW)Checking SSL certificates (dry run)...$(NC)"
	@ssh -i $(SSH_KEY) $(SSH_USER)@$(SSH_HOST) \
		"cd $(REMOTE_PATH) && ./lib/provision-ssl-certs.sh --dry-run"

# =============================================================================
# MONITORING ACCESS
# =============================================================================

.PHONY: grafana
grafana: ## Open Grafana in browser
	@echo "$(GREEN)Opening Grafana: https://monitoring.paiss.me$(NC)"
	@xdg-open https://monitoring.paiss.me 2>/dev/null || open https://monitoring.paiss.me 2>/dev/null || \
		echo "Visit: https://monitoring.paiss.me"

.PHONY: prometheus
prometheus: ## SSH tunnel to Prometheus (localhost:9090)
	@echo "$(GREEN)Creating SSH tunnel to Prometheus...$(NC)"
	@echo "Access at: http://localhost:9090"
	@ssh -i $(SSH_KEY) -L 9090:localhost:9090 $(SSH_USER)@$(SSH_HOST)

# =============================================================================
# DEFAULT
# =============================================================================

.DEFAULT_GOAL := help

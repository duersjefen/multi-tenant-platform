# =============================================================================
# Multi-Tenant Platform - Makefile
# =============================================================================
# Safe infrastructure management commands
# =============================================================================

.PHONY: help deploy-nginx deploy-platform restart-nginx test-nginx status logs logs-nginx

.DEFAULT_GOAL := help

# Load EC2 instance ID from .env.ec2
-include .env.ec2

# Region configuration
REGION := eu-north-1

##
## 🚀 Deployment Commands
##

deploy-nginx: ## Deploy nginx config changes (safest way to update routing)
	@echo "🔄 Deploying nginx configuration changes..."
	@echo ""
	@if [ ! -f .env.ec2 ]; then \
		echo "❌ .env.ec2 not found"; \
		echo "   Create it with: EC2_INSTANCE_ID=i-xxxxxxxxxxxxx"; \
		exit 1; \
	fi
	@if [ -z "$(EC2_INSTANCE_ID)" ]; then \
		echo "❌ EC2_INSTANCE_ID not set in .env.ec2"; \
		exit 1; \
	fi
	@echo "Instance: $(EC2_INSTANCE_ID)"
	@echo "Region: $(REGION)"
	@echo ""
	@COMMAND_ID=$$(aws ssm send-command \
		--region $(REGION) \
		--instance-ids $(EC2_INSTANCE_ID) \
		--document-name "AWS-RunShellScript" \
		--comment "Deploy nginx config changes" \
		--parameters 'commands=[ \
			"set -e", \
			"echo \"📥 Pulling latest nginx configs...\"", \
			"cd /opt/platform", \
			"git pull origin main", \
			"echo \"🔍 Testing nginx config syntax...\"", \
			"cd platform", \
			"docker-compose exec -T nginx nginx -t || (echo \"❌ Nginx config test failed!\" && exit 1)", \
			"echo \"✅ Nginx config syntax valid\"", \
			"echo \"🔄 Reloading nginx...\"", \
			"docker-compose exec -T nginx nginx -s reload", \
			"echo \"✅ Nginx reloaded successfully!\"" \
		]' \
		--output text \
		--query 'Command.CommandId'); \
	echo ""; \
	echo "✅ Deployment command sent!"; \
	echo "Command ID: $$COMMAND_ID"; \
	echo "⏳ Waiting for deployment to complete..."; \
	echo ""; \
	aws ssm wait command-executed \
		--region $(REGION) \
		--command-id $$COMMAND_ID \
		--instance-id $(EC2_INSTANCE_ID); \
	echo "✅ Nginx configuration deployed!"; \
	echo ""; \
	echo "🔍 Verifying nginx is responding..."; \
	if curl -f -s -I https://paiss.me > /dev/null 2>&1; then \
		echo "✅ Nginx is healthy!"; \
	else \
		echo "⚠️  Warning: Could not verify nginx health"; \
		echo "   Check logs with: make logs-nginx"; \
	fi

deploy-platform: ## Deploy full platform (nginx + postgres + certbot)
	@echo "🚀 Deploying full platform..."
	@echo ""
	@if [ ! -f .env.ec2 ]; then \
		echo "❌ .env.ec2 not found"; \
		exit 1; \
	fi
	@if [ -z "$(EC2_INSTANCE_ID)" ]; then \
		echo "❌ EC2_INSTANCE_ID not set in .env.ec2"; \
		exit 1; \
	fi
	@./scripts/deploy-platform.sh $(EC2_INSTANCE_ID)

restart-nginx: ## Emergency nginx restart (use only if reload fails)
	@echo "⚠️  Emergency nginx restart"
	@echo ""
	@if [ ! -f .env.ec2 ]; then \
		echo "❌ .env.ec2 not found"; \
		exit 1; \
	fi
	@if [ -z "$(EC2_INSTANCE_ID)" ]; then \
		echo "❌ EC2_INSTANCE_ID not set in .env.ec2"; \
		exit 1; \
	fi
	@echo "Instance: $(EC2_INSTANCE_ID)"
	@echo "Region: $(REGION)"
	@echo ""
	@COMMAND_ID=$$(aws ssm send-command \
		--region $(REGION) \
		--instance-ids $(EC2_INSTANCE_ID) \
		--document-name "AWS-RunShellScript" \
		--comment "Emergency nginx restart" \
		--parameters 'commands=[ \
			"set -e", \
			"cd /opt/platform/platform", \
			"docker-compose restart nginx", \
			"echo \"⏳ Waiting for nginx to be ready...\"", \
			"sleep 5", \
			"docker-compose ps nginx", \
			"echo \"✅ Nginx restarted!\"" \
		]' \
		--output text \
		--query 'Command.CommandId'); \
	echo ""; \
	echo "✅ Restart command sent!"; \
	echo "Command ID: $$COMMAND_ID"; \
	echo "⏳ Waiting for restart to complete..."; \
	echo ""; \
	aws ssm wait command-executed \
		--region $(REGION) \
		--command-id $$COMMAND_ID \
		--instance-id $(EC2_INSTANCE_ID); \
	echo "✅ Restart complete!"

test-nginx: ## Test nginx config syntax on server
	@echo "🔍 Testing nginx configuration..."
	@echo ""
	@if [ ! -f .env.ec2 ]; then \
		echo "❌ .env.ec2 not found"; \
		exit 1; \
	fi
	@if [ -z "$(EC2_INSTANCE_ID)" ]; then \
		echo "❌ EC2_INSTANCE_ID not set in .env.ec2"; \
		exit 1; \
	fi
	@aws ssm send-command \
		--region $(REGION) \
		--instance-ids $(EC2_INSTANCE_ID) \
		--document-name "AWS-RunShellScript" \
		--comment "Test nginx config" \
		--parameters 'commands=[ \
			"cd /opt/platform/platform", \
			"docker-compose exec -T nginx nginx -t" \
		]' \
		--output text \
		--query 'Command.CommandId' > /dev/null
	@echo "✅ Config test command sent"
	@echo "💡 View results with: make logs-nginx"

##
## 📊 Monitoring Commands
##

status: ## Check platform services health
	@echo "📊 Platform Status"
	@echo "══════════════════"
	@echo ""
	@if [ ! -f .env.ec2 ]; then \
		echo "❌ .env.ec2 not found"; \
		exit 1; \
	fi
	@if [ -z "$(EC2_INSTANCE_ID)" ]; then \
		echo "❌ EC2_INSTANCE_ID not set in .env.ec2"; \
		exit 1; \
	fi
	@aws ssm send-command \
		--region $(REGION) \
		--instance-ids $(EC2_INSTANCE_ID) \
		--document-name "AWS-RunShellScript" \
		--comment "Check platform status" \
		--parameters 'commands=[ \
			"cd /opt/platform/platform", \
			"echo \"Platform Services:\"", \
			"docker-compose ps", \
			"echo \"\"", \
			"echo \"All Platform Containers:\"", \
			"docker ps --filter \"name=platform\" --format \"table {{.Names}}\t{{.Status}}\t{{.Ports}}\"" \
		]' \
		--output text \
		--query 'Command.CommandId' > /dev/null
	@echo "✅ Status check command sent"
	@echo "💡 Connect interactively: aws ssm start-session --target $(EC2_INSTANCE_ID) --region $(REGION)"

logs: ## View platform logs (connect via SSM)
	@echo "🔍 Connecting to platform logs..."
	@echo ""
	@if [ ! -f .env.ec2 ]; then \
		echo "❌ .env.ec2 not found"; \
		exit 1; \
	fi
	@if [ -z "$(EC2_INSTANCE_ID)" ]; then \
		echo "❌ EC2_INSTANCE_ID not set in .env.ec2"; \
		exit 1; \
	fi
	@echo "💡 Press Ctrl+C to exit"
	@echo ""
	@aws ssm start-session \
		--target $(EC2_INSTANCE_ID) \
		--region $(REGION) \
		--document-name AWS-StartInteractiveCommand \
		--parameters command="cd /opt/platform/platform && docker-compose logs -f"

logs-nginx: ## View nginx logs (connect via SSM)
	@echo "🔍 Connecting to nginx logs..."
	@echo ""
	@if [ ! -f .env.ec2 ]; then \
		echo "❌ .env.ec2 not found"; \
		exit 1; \
	fi
	@if [ -z "$(EC2_INSTANCE_ID)" ]; then \
		echo "❌ EC2_INSTANCE_ID not set in .env.ec2"; \
		exit 1; \
	fi
	@echo "💡 Press Ctrl+C to exit"
	@echo ""
	@aws ssm start-session \
		--target $(EC2_INSTANCE_ID) \
		--region $(REGION) \
		--document-name AWS-StartInteractiveCommand \
		--parameters command="docker logs -f nginx-platform"

##
## 📚 Help
##

help: ## Show this help message
	@echo ""
	@echo "🌐 Multi-Tenant Platform Management"
	@echo "════════════════════════════════════"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "📖 Most common: make deploy-nginx"
	@echo "📖 Full docs: cat CLAUDE.md"
	@echo ""

#!/bin/bash
# =============================================================================
# Setup PLATFORM_DEPLOY_TOKEN for Project Repositories
# =============================================================================
# This script configures the GitHub secret that allows app repos to trigger
# platform deployments via repository_dispatch events.
#
# Usage:
#   ./lib/setup-project-token.sh [project-name]
#   ./lib/setup-project-token.sh --all
# =============================================================================

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}ℹ${NC}  $1"; }
log_success() { echo -e "${GREEN}✅${NC} $1"; }
log_warning() { echo -e "${YELLOW}⚠️${NC}  $1"; }
log_error() { echo -e "${RED}❌${NC} $1"; }

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

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
# Verify GitHub CLI Authentication
# =============================================================================

log_info "Checking GitHub CLI authentication..."

if ! gh auth status &>/dev/null; then
    log_error "Not authenticated with GitHub CLI"
    log_info "Run: gh auth login"
    exit 1
fi

# Check token scopes
TOKEN_SCOPES=$(gh auth status 2>&1 | grep "Token scopes:")
if [[ ! "$TOKEN_SCOPES" =~ "repo" ]]; then
    log_error "GitHub token missing required 'repo' scope"
    log_info "Re-authenticate with: gh auth refresh -s repo"
    exit 1
fi

log_success "GitHub CLI authenticated with repo scope"

# =============================================================================
# Get Token
# =============================================================================

log_info "Getting GitHub token..."
TOKEN=$(gh auth token)

if [ -z "$TOKEN" ]; then
    log_error "Failed to retrieve GitHub token"
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
# Setup Token for Each Project
# =============================================================================

SUCCESS_COUNT=0
SKIP_COUNT=0
FAIL_COUNT=0

for PROJECT in $PROJECTS; do
    log_info "Setting up token for: $PROJECT"

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

    # Extract repository
    PROJECT_REPO=$(echo "$PROJECT_CONFIG" | python3 -c "import sys, json; print(json.load(sys.stdin).get('repository', ''))")

    if [ -z "$PROJECT_REPO" ]; then
        log_warning "$PROJECT: No repository defined, skipping"
        SKIP_COUNT=$((SKIP_COUNT + 1))
        continue
    fi

    # Extract repository owner and name
    REPO_OWNER=$(echo "$PROJECT_REPO" | sed 's|https://github.com/||' | cut -d'/' -f1)
    REPO_NAME=$(echo "$PROJECT_REPO" | sed 's|https://github.com/||' | cut -d'/' -f2)
    REPO_FULL="$REPO_OWNER/$REPO_NAME"

    log_info "$PROJECT: Repository: $REPO_FULL"

    # Check if repo exists
    if ! gh repo view "$REPO_FULL" &>/dev/null; then
        log_warning "$PROJECT: Repository not found or inaccessible, skipping"
        SKIP_COUNT=$((SKIP_COUNT + 1))
        continue
    fi

    # Set the secret
    if echo "$TOKEN" | gh secret set PLATFORM_DEPLOY_TOKEN --repo "$REPO_FULL" >/dev/null 2>&1; then
        log_success "$PROJECT: PLATFORM_DEPLOY_TOKEN configured"
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    else
        log_error "$PROJECT: Failed to set token"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi

    echo ""
done

# =============================================================================
# Summary
# =============================================================================

log_info "Setup complete!"
echo ""
log_info "Summary:"
log_info "  ✅ Success: $SUCCESS_COUNT"
log_info "  ⏭️  Skipped: $SKIP_COUNT"
log_info "  ❌ Failed:  $FAIL_COUNT"
echo ""

if [ $SUCCESS_COUNT -gt 0 ]; then
    log_success "Projects can now trigger platform deployments!"
    log_info "Test by pushing to main branch in any configured project"
fi

if [ $FAIL_COUNT -gt 0 ]; then
    exit 1
fi

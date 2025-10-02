#!/bin/bash
# =============================================================================
# Generate CLAUDE.md Documentation from Template
# =============================================================================
# This script generates project-specific CLAUDE.md documentation based on
# the comprehensive template and project configuration from projects.yml.
#
# Usage:
#   ./lib/generate-project-claude-md.sh <project-name> <output-file>
#
# Examples:
#   ./lib/generate-project-claude-md.sh filter-ical /tmp/CLAUDE.md
#   ./lib/generate-project-claude-md.sh gabs-massage ./CLAUDE.md
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

# =============================================================================
# Parse Arguments
# =============================================================================

PROJECT_NAME="${1:-}"
OUTPUT_FILE="${2:-CLAUDE.md}"

if [ -z "$PROJECT_NAME" ]; then
    log_error "Usage: $0 <project-name> [output-file]"
    log_info "Example: $0 filter-ical ./CLAUDE.md"
    exit 1
fi

# Convert OUTPUT_FILE to absolute path (before changing directories)
if [[ "$OUTPUT_FILE" != /* ]]; then
    OUTPUT_FILE="$(pwd)/$OUTPUT_FILE"
fi

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATE_FILE="$PLATFORM_ROOT/templates/CLAUDE.md.template"

# Verify template exists
if [ ! -f "$TEMPLATE_FILE" ]; then
    log_error "Template not found: $TEMPLATE_FILE"
    exit 1
fi

# =============================================================================
# Extract Project Configuration from projects.yml
# =============================================================================

log_info "Reading project configuration from projects.yml..."

cd "$PLATFORM_ROOT"

# Extract project config using Python
PROJECT_CONFIG=$(python3 - "$PROJECT_NAME" <<'PYTHON'
import yaml
import sys
import json

try:
    with open('config/projects.yml', 'r') as f:
        config = yaml.safe_load(f)

    project_name = sys.argv[1]

    if project_name not in config.get('projects', {}):
        print(f"ERROR: Project '{project_name}' not found in projects.yml", file=sys.stderr)
        sys.exit(1)

    project = config['projects'][project_name]

    # Extract configuration
    result = {
        'name': project.get('name', project_name),
        'repository': project.get('repository', ''),
        'backend_port': 3000,  # Default
        'frontend_port': 8080,  # Default
        'domains': []
    }

    # Extract ports from containers
    containers = project.get('containers', {})
    for container_name, container_config in containers.items():
        port = container_config.get('port')
        if port:
            if 'backend' in container_name.lower() or 'api' in container_name.lower():
                result['backend_port'] = port
            elif 'frontend' in container_name.lower() or 'web' in container_name.lower():
                result['frontend_port'] = port

    # Extract domains
    domains_config = project.get('domains', {})
    if 'production' in domains_config:
        prod_domains = domains_config['production']
        if isinstance(prod_domains, list):
            result['domains'] = prod_domains
        else:
            result['domains'] = [prod_domains]

    # Extract repository owner and name
    if result['repository']:
        repo_parts = result['repository'].replace('https://github.com/', '').split('/')
        if len(repo_parts) >= 2:
            result['repo_owner'] = repo_parts[0]
            result['repo_name'] = repo_parts[1]

    print(json.dumps(result))

except Exception as e:
    print(f"Error: {e}", file=sys.stderr)
    sys.exit(1)
PYTHON
)

if [ $? -ne 0 ]; then
    log_error "Failed to read project configuration"
    exit 1
fi

# Parse JSON output
PROJECT_DISPLAY_NAME=$(echo "$PROJECT_CONFIG" | python3 -c "import sys, json; print(json.load(sys.stdin).get('name', ''))")
REPOSITORY=$(echo "$PROJECT_CONFIG" | python3 -c "import sys, json; print(json.load(sys.stdin).get('repository', ''))")
BACKEND_PORT=$(echo "$PROJECT_CONFIG" | python3 -c "import sys, json; print(json.load(sys.stdin).get('backend_port', 3000))")
FRONTEND_PORT=$(echo "$PROJECT_CONFIG" | python3 -c "import sys, json; print(json.load(sys.stdin).get('frontend_port', 8080))")
DOMAIN=$(echo "$PROJECT_CONFIG" | python3 -c "import sys, json; domains = json.load(sys.stdin).get('domains', []); print(domains[0] if domains else '')")
REPO_OWNER=$(echo "$PROJECT_CONFIG" | python3 -c "import sys, json; print(json.load(sys.stdin).get('repo_owner', ''))")
REPO_NAME=$(echo "$PROJECT_CONFIG" | python3 -c "import sys, json; print(json.load(sys.stdin).get('repo_name', ''))")

log_info "Project: $PROJECT_DISPLAY_NAME"
log_info "Repository: $REPOSITORY"
log_info "Backend port: $BACKEND_PORT"
log_info "Frontend port: $FRONTEND_PORT"
log_info "Primary domain: $DOMAIN"

# =============================================================================
# Generate CLAUDE.md from Template
# =============================================================================

log_info "Generating CLAUDE.md from template..."

# Get current date
GENERATION_DATE=$(date +%Y-%m-%d)

# Read template and replace placeholders
CLAUDE_CONTENT=$(cat "$TEMPLATE_FILE")

# Replace all placeholders
CLAUDE_CONTENT="${CLAUDE_CONTENT//\{\{PROJECT_NAME\}\}/$PROJECT_NAME}"
CLAUDE_CONTENT="${CLAUDE_CONTENT//\{\{PROJECT_DISPLAY_NAME\}\}/$PROJECT_DISPLAY_NAME}"
CLAUDE_CONTENT="${CLAUDE_CONTENT//\{\{BACKEND_PORT\}\}/$BACKEND_PORT}"
CLAUDE_CONTENT="${CLAUDE_CONTENT//\{\{FRONTEND_PORT\}\}/$FRONTEND_PORT}"
CLAUDE_CONTENT="${CLAUDE_CONTENT//\{\{DOMAIN\}\}/$DOMAIN}"
CLAUDE_CONTENT="${CLAUDE_CONTENT//\{\{REPO_OWNER\}\}/$REPO_OWNER}"
CLAUDE_CONTENT="${CLAUDE_CONTENT//\{\{REPO_NAME\}\}/$REPO_NAME}"
CLAUDE_CONTENT="${CLAUDE_CONTENT//\{\{GENERATION_DATE\}\}/$GENERATION_DATE}"

# Write output file
echo "$CLAUDE_CONTENT" > "$OUTPUT_FILE"

log_success "CLAUDE.md generated: $OUTPUT_FILE"

# =============================================================================
# Summary
# =============================================================================

echo ""
log_info "Documentation generated successfully!"
log_info "Output: $OUTPUT_FILE"
log_info "Customizations applied:"
echo "  - Project: $PROJECT_NAME ($PROJECT_DISPLAY_NAME)"
echo "  - Backend: http://localhost:$BACKEND_PORT"
echo "  - Frontend: http://localhost:$FRONTEND_PORT"
echo "  - Domain: https://$DOMAIN"
echo ""

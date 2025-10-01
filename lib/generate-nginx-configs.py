#!/usr/bin/env python3
"""
=============================================================================
Nginx Configuration Generator
=============================================================================
Generates nginx server blocks from projects.yml
Ensures consistency and eliminates manual config drift

Usage:
    ./lib/generate-nginx-configs.py [--dry-run] [--project PROJECT_NAME]

Options:
    --dry-run       Show what would be generated without writing files
    --project NAME  Generate config for specific project only

Examples:
    ./lib/generate-nginx-configs.py                    # Generate all configs
    ./lib/generate-nginx-configs.py --dry-run          # Preview changes
    ./lib/generate-nginx-configs.py --project filter-ical  # One project only
=============================================================================
"""

import yaml
import sys
import os
from pathlib import Path
from typing import Dict, List, Any

# Colors for output
GREEN = '\033[0;32m'
YELLOW = '\033[1;33m'
BLUE = '\033[0;34m'
NC = '\033[0m'  # No Color

class NginxConfigGenerator:
    def __init__(self, platform_root: Path):
        self.platform_root = platform_root
        self.config_file = platform_root / "config" / "projects.yml"
        self.output_dir = platform_root / "platform" / "nginx" / "conf.d"
        self.is_first_server_block = True  # Track if this is the first HTTPS server block

    def load_projects(self) -> Dict[str, Any]:
        """Load and parse projects.yml"""
        with open(self.config_file) as f:
            return yaml.safe_load(f)

    def generate_server_block(self, project_name: str, project: Dict, environment: str) -> str:
        """Generate an nginx server block for a project environment"""

        # Get domains for this environment
        if environment == "production":
            domains = project["domains"]["production"]
        else:
            domains = project["domains"]["staging"]["domains"]

        # Primary domain
        primary_domain = domains[0] if isinstance(domains, list) else domains

        # Server name (all domains)
        server_names = " ".join(domains) if isinstance(domains, list) else primary_domain

        # Container configuration
        containers = project["containers"]

        # Determine backend and frontend container names
        backend_container = None
        frontend_container = None

        for container_key, container_config in containers.items():
            container_name = container_config["name"]
            if environment == "staging":
                container_name = f"{container_name}-staging"

            if "backend" in container_key.lower():
                backend_container = {
                    "name": container_name,
                    "port": container_config["port"]
                }
            elif "frontend" in container_key.lower() or "web" in container_key.lower():
                frontend_container = {
                    "name": container_name,
                    "port": container_config["port"]
                }

        # Get nginx config
        nginx_config = project.get("nginx", {})
        api_locations = nginx_config.get("api_locations", [])
        rate_limit = nginx_config.get("rate_limit", {})

        # Determine if we should use reuseport (only for first server block)
        quic_listener = "listen 443 quic reuseport;  # HTTP/3 support (reuseport only on first block)"
        if not self.is_first_server_block:
            quic_listener = "listen 443 quic;  # HTTP/3 support"
        else:
            self.is_first_server_block = False  # Mark that we've used reuseport

        # Generate configuration
        config = f"""# =============================================================================
# {project['name']} - {environment.upper()}
# =============================================================================
server {{
    listen 443 ssl;
    {quic_listener}
    http2 on;
    server_name {server_names};

    # SSL certificates
    ssl_certificate /etc/letsencrypt/live/{primary_domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/{primary_domain}/privkey.pem;

    # Include security headers
    include /etc/nginx/includes/security-headers.conf;

    # Logs
    access_log /var/log/nginx/{project_name}-{environment}.access.log detailed;
    error_log /var/log/nginx/{project_name}-{environment}.error.log warn;
"""

        # Add backend routes if backend exists
        if backend_container and api_locations:
            api_pattern = "|".join(api_locations)
            burst = rate_limit.get("burst", 20)

            config += f"""
    # ==========================================================================
    # BACKEND ROUTES (API)
    # ==========================================================================
    location ~ ^/({api_pattern}) {{
        # Rate limiting for API
        limit_req zone=api burst={burst} nodelay;

        # Dynamic backend resolution
        set $backend_host "{backend_container['name']}";
        set $backend_port "{backend_container['port']}";
        proxy_pass http://$backend_host:$backend_port;

        # Include standard proxy headers
        include /etc/nginx/includes/proxy-headers.conf;

        # API-specific timeouts
        proxy_connect_timeout {nginx_config.get('proxy_connect_timeout', '60s')};
        proxy_send_timeout {nginx_config.get('proxy_timeout', '60s')};
        proxy_read_timeout {nginx_config.get('proxy_timeout', '60s')};
    }}
"""

        # Add frontend routes
        if frontend_container:
            rate_zone = rate_limit.get("zone", "general")
            burst = rate_limit.get("burst", 50) if not backend_container else 50

            config += f"""
    # ==========================================================================
    # FRONTEND ROUTES
    # ==========================================================================
    location / {{
        # Rate limiting
        limit_req zone={rate_zone} burst={burst} nodelay;

        # Dynamic frontend resolution
        set $frontend_host "{frontend_container['name']}";
        set $frontend_port "{frontend_container['port']}";
        proxy_pass http://$frontend_host:$frontend_port;

        # Include standard proxy headers
        include /etc/nginx/includes/proxy-headers.conf;

        # SPA fallback
        proxy_intercept_errors on;
        error_page 404 = @frontend_fallback;
    }}

    # SPA fallback - serve index.html for client-side routes
    location @frontend_fallback {{
        set $frontend_host "{frontend_container['name']}";
        set $frontend_port "{frontend_container['port']}";
        proxy_pass http://$frontend_host:$frontend_port/index.html;
        include /etc/nginx/includes/proxy-headers.conf;
    }}

    # ==========================================================================
    # STATIC ASSETS (with caching)
    # ==========================================================================
    location ~* \\.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)$ {{
        set $frontend_host "{frontend_container['name']}";
        set $frontend_port "{frontend_container['port']}";
        proxy_pass http://$frontend_host:$frontend_port;
        include /etc/nginx/includes/proxy-headers.conf;

        # Cache static assets
        proxy_cache_valid 200 7d;
        add_header Cache-Control "public, max-age=604800, immutable";
    }}
"""

        config += "}\n"

        return config

    def generate_http_redirect(self, domains: List[str], primary_domain: str) -> str:
        """Generate HTTP to HTTPS redirect block"""
        server_names = " ".join(domains) if isinstance(domains, list) else domains

        return f"""# =============================================================================
# HTTP → HTTPS REDIRECT
# =============================================================================
server {{
    listen 80;
    server_name {server_names};

    # ACME challenge for SSL renewal
    location /.well-known/acme-challenge/ {{
        root /var/www/certbot;
    }}

    # Redirect all other traffic to HTTPS
    location / {{
        return 301 https://$host$request_uri;
    }}
}}

"""

    def generate_project_config(self, project_name: str, project: Dict) -> str:
        """Generate complete nginx config for a project"""
        config = f"""# =============================================================================
# {project['name']} - Nginx Configuration
# =============================================================================
# AUTO-GENERATED from config/projects.yml
# DO NOT EDIT MANUALLY - Use ./lib/generate-nginx-configs.py to regenerate
# =============================================================================

"""
        # Generate production environment
        if "production" in project["domains"]:
            prod_domains = project["domains"]["production"]
            primary_domain = prod_domains[0] if isinstance(prod_domains, list) else prod_domains

            config += self.generate_http_redirect(prod_domains, primary_domain)
            config += self.generate_server_block(project_name, project, "production")
            config += "\n"

        # Generate staging environment
        if "staging" in project["domains"]:
            staging_domains = project["domains"]["staging"]["domains"]
            primary_domain = staging_domains[0] if isinstance(staging_domains, list) else staging_domains

            config += self.generate_http_redirect(staging_domains, primary_domain)
            config += self.generate_server_block(project_name, project, "staging")

        return config

    def validate_generated_configs(self) -> bool:
        """Validate that only one reuseport exists across all configs"""
        print()
        print(f"{BLUE}🔍 VALIDATING GENERATED CONFIGS{NC}")
        print("-" * 80)

        reuseport_count = 0
        reuseport_locations = []

        for conf_file in sorted(self.output_dir.glob("*.conf")):
            with open(conf_file) as f:
                lines = f.readlines()
                for line_num, line in enumerate(lines, 1):
                    if "listen 443 quic reuseport" in line:
                        reuseport_count += 1
                        reuseport_locations.append(f"{conf_file.name}:{line_num}")

        # Validation checks
        all_passed = True

        # Check 1: Exactly one reuseport
        if reuseport_count == 1:
            print(f"{GREEN}✅ reuseport check: Found exactly 1 occurrence{NC}")
            print(f"   Location: {reuseport_locations[0]}")
        else:
            print(f"{YELLOW}❌ reuseport check: Found {reuseport_count} occurrences (expected 1){NC}")
            for loc in reuseport_locations:
                print(f"   - {loc}")
            all_passed = False

        # Check 2: All configs have HTTP/3 support
        configs_without_http3 = []
        for conf_file in sorted(self.output_dir.glob("*.conf")):
            with open(conf_file) as f:
                content = f.read()
                if "listen 443 quic" not in content:
                    configs_without_http3.append(conf_file.name)

        if not configs_without_http3:
            print(f"{GREEN}✅ HTTP/3 check: All configs have QUIC listeners{NC}")
        else:
            print(f"{YELLOW}❌ HTTP/3 check: Missing QUIC listeners in:{NC}")
            for conf in configs_without_http3:
                print(f"   - {conf}")
            all_passed = False

        print("-" * 80)

        if all_passed:
            print(f"{GREEN}✅ All validations passed{NC}")
        else:
            print(f"{YELLOW}⚠️  Some validations failed{NC}")

        return all_passed

    def generate_all(self, dry_run: bool = False, specific_project: str = None):
        """Generate nginx configs for all projects"""
        data = self.load_projects()
        projects = data.get("projects", {})

        if specific_project and specific_project not in projects:
            print(f"❌ Project not found: {specific_project}")
            sys.exit(1)

        # Filter to specific project if requested
        if specific_project:
            projects = {specific_project: projects[specific_project]}

        print("=" * 80)
        print(f"{BLUE}🔧 NGINX CONFIGURATION GENERATOR{NC}")
        print("=" * 80)
        print(f"Projects to generate: {len(projects)}")
        if dry_run:
            print(f"{YELLOW}DRY RUN MODE - No files will be written{NC}")
        print()

        for project_name, project in projects.items():
            print(f"Generating config for: {project_name}")

            # Generate configuration
            config = self.generate_project_config(project_name, project)

            # Determine output file name
            if "domains" in project and "production" in project["domains"]:
                prod_domains = project["domains"]["production"]
                primary_domain = prod_domains[0] if isinstance(prod_domains, list) else prod_domains
                output_file = self.output_dir / f"{primary_domain.replace('www.', '')}.conf"
            else:
                output_file = self.output_dir / f"{project_name}.conf"

            if dry_run:
                print(f"  Would write to: {output_file}")
                print(f"  Config preview (first 10 lines):")
                for line in config.split("\\n")[:10]:
                    print(f"    {line}")
                print("  ...")
            else:
                # Ensure output directory exists
                self.output_dir.mkdir(parents=True, exist_ok=True)

                # Write config
                with open(output_file, 'w') as f:
                    f.write(config)

                print(f"  {GREEN}✅ Generated: {output_file}{NC}")

        print()
        print("=" * 80)
        print(f"{GREEN}✅ Configuration generation complete{NC}")
        print("=" * 80)

        if not dry_run:
            # Run validation
            validation_passed = self.validate_generated_configs()

            print()
            print("Next steps:")
            print("1. Review generated configs")
            print("2. Test: docker exec platform-nginx nginx -t")
            print("3. Deploy: ./lib/deploy-platform.sh nginx")

            if not validation_passed:
                print()
                print(f"{YELLOW}⚠️  Warning: Some validations failed. Review configs before deploying.{NC}")
                sys.exit(1)

def main():
    import argparse

    parser = argparse.ArgumentParser(description='Generate nginx configs from projects.yml')
    parser.add_argument('--dry-run', action='store_true', help='Show what would be generated without writing files')
    parser.add_argument('--project', type=str, help='Generate config for specific project only')

    args = parser.parse_args()

    # Find platform root
    script_dir = Path(__file__).parent
    platform_root = script_dir.parent

    # Generate configs
    generator = NginxConfigGenerator(platform_root)
    generator.generate_all(dry_run=args.dry_run, specific_project=args.project)

if __name__ == "__main__":
    main()

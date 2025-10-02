#!/bin/bash
# Extract all domains from projects.yml for CI/CD workflows
# Usage: ./lib/extract-domains.sh > /tmp/domains.txt

python3 << 'EOF'
import yaml

with open('config/projects.yml') as f:
    config = yaml.safe_load(f)

domains = set()
for project in config.get('projects', {}).values():
    dc = project.get('domains', {})
    if 'production' in dc:
        p = dc['production']
        domains.update(p if isinstance(p, list) else [p])
    if 'staging' in dc:
        s = dc['staging'].get('domains', [])
        domains.update(s if isinstance(s, list) else [s])

for d in sorted(domains):
    print(d)
EOF

# Git Hooks

This directory contains custom Git hooks for the multi-tenant platform.

## Installation

To enable these hooks for your local repository:

```bash
git config core.hooksPath .githooks
```

Or manually create symlinks:

```bash
ln -s ../../.githooks/pre-commit .git/hooks/pre-commit
chmod +x .git/hooks/pre-commit
```

## Available Hooks

### pre-commit

Validates nginx configurations before allowing commits:

- ✅ Ensures exactly ONE `reuseport` directive exists across all configs
- ✅ Verifies all configs have HTTP/3 (`listen 443 quic`) support
- ✅ Validates `projects.yml` YAML syntax
- ⚠️  Warns if nginx configs were hand-edited (should use auto-generation)

**Bypassing** (not recommended):
```bash
git commit --no-verify
```

## Testing Hooks

Test the pre-commit hook manually:

```bash
./.githooks/pre-commit
```

## Requirements

- `bash`
- `grep`
- `python3` (for YAML validation)
- `git`

## Troubleshooting

If hooks aren't running:
```bash
# Check if hooks path is configured
git config core.hooksPath

# Should output: .githooks
```

If not set:
```bash
git config core.hooksPath .githooks
```

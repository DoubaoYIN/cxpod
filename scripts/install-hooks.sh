#!/usr/bin/env bash
# install-hooks.sh — Install git hooks for the cxpod repo.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$REPO/.git/hooks/pre-commit"

cat > "$HOOK" <<'HOOK_EOF'
#!/usr/bin/env bash
# Auto-installed by scripts/install-hooks.sh
exec "$(git rev-parse --show-toplevel)/scripts/check-no-secrets.sh" --staged
HOOK_EOF
chmod +x "$HOOK"
echo "✅ pre-commit hook 已安装: $HOOK"

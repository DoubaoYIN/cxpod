#!/usr/bin/env bash
# check-no-secrets.sh — Refuse to commit provider files with real credentials.
#
# Rules:
#   1. providers/*.example.json may contain anything (they're templates).
#   2. Other providers/*.json must not contain non-empty `api_key`,
#      `authorization`, `token`, or `bearer_token` fields — use
#      "${ENV:VAR_NAME}" placeholders instead.
#   3. Any file (except *.example.json) matching common secret patterns
#      (sk-..., ghp_..., long hex blobs next to auth keywords) is rejected.
#
# Usage:
#   scripts/check-no-secrets.sh                  # check all tracked+staged
#   scripts/check-no-secrets.sh --staged         # check only staged files
set -euo pipefail

MODE="all"
[[ "${1:-}" == "--staged" ]] && MODE="staged"

cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)"

list_files() {
  if [[ "$MODE" == "staged" ]]; then
    git diff --cached --name-only --diff-filter=ACM
  else
    git ls-files
  fi
}

fail=0
report() { printf '❌ %s: %s\n' "$1" "$2" >&2; fail=1; }

scan_json() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  case "$f" in *.example.json) return 0 ;; esac
  python3 - "$f" <<'PYEOF' || fail=1
import json, re, sys
path = sys.argv[1]
try:
    with open(path) as fh:
        data = json.load(fh)
except Exception as e:
    print(f"⚠️  {path}: 非法 JSON ({e})", file=sys.stderr)
    sys.exit(0)

SENSITIVE = {"api_key", "authorization", "token", "bearer_token", "secret"}
PLACEHOLDER = re.compile(r'^\$\{ENV:[A-Za-z_][A-Za-z0-9_]*\}$')

def walk(node, path=""):
    ok = True
    if isinstance(node, dict):
        for k, v in node.items():
            p = f"{path}.{k}" if path else k
            if k.lower() in SENSITIVE and isinstance(v, str) and v.strip():
                if not PLACEHOLDER.match(v.strip()):
                    print(f"❌ {sys.argv[1]}: 字段 {p} 含明文凭据 (值必须是 ${{ENV:VAR}} 占位符或留空)", file=sys.stderr)
                    ok = False
            ok = walk(v, p) and ok
    elif isinstance(node, list):
        for i, v in enumerate(node):
            ok = walk(v, f"{path}[{i}]") and ok
    return ok

sys.exit(0 if walk(data) else 1)
PYEOF
}

scan_generic() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  case "$f" in
    *.example.json|*.example|scripts/check-no-secrets.sh) return 0 ;;
  esac
  # Skip binaries
  if ! LC_ALL=C grep -Iq . "$f" 2>/dev/null; then return 0; fi

  # OpenAI sk-... (20+ chars)
  if LC_ALL=C grep -nE 'sk-[A-Za-z0-9_-]{20,}' "$f" >/dev/null; then
    report "$f" "疑似 OpenAI sk- 密钥"
  fi
  # GitHub PAT
  if LC_ALL=C grep -nE 'gh[pousr]_[A-Za-z0-9]{30,}' "$f" >/dev/null; then
    report "$f" "疑似 GitHub token"
  fi
  # AWS access key
  if LC_ALL=C grep -nE 'AKIA[0-9A-Z]{16}' "$f" >/dev/null; then
    report "$f" "疑似 AWS access key"
  fi
  # Long Authorization: Bearer <token>
  if LC_ALL=C grep -niE 'authorization[[:space:]]*[:=][[:space:]]*["'\''"]?bearer[[:space:]]+[A-Za-z0-9._-]{20,}' "$f" >/dev/null; then
    report "$f" "疑似硬编码 Bearer token"
  fi
}

while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  case "$f" in
    providers/*.json) scan_json "$f" ;;
  esac
  scan_generic "$f"
done < <(list_files)

if (( fail )); then
  echo "" >&2
  echo "提示：用 \"\${ENV:VAR_NAME}\" 占位符；真实 key 优先写到 ~/.cxpod/env。" >&2
  exit 1
fi
echo "✅ 未发现明文凭据"

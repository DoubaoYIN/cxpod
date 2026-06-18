#!/usr/bin/env bash
# common.sh — shared variables and helpers for cxpod scripts
#
# Sourced by cxuse / cxnow / cxstart / cx-status. Do not execute directly.

# ─── Paths ────────────────────────────────────────────────
: "${CXPOD_HOME:=$HOME/.cxpod}"

# Resolve repo root. If the caller already exported CXPOD_REPO use it;
# otherwise probe BASH_SOURCE (works under bash) and fall back to ../..
# from the lib file when zsh sources us indirectly.
if [[ -z "${CXPOD_REPO:-}" ]]; then
  if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
    _cxpod_lib_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    CXPOD_REPO="$(cd -P "$_cxpod_lib_dir/../.." && pwd)"
    unset _cxpod_lib_dir
  else
    CXPOD_REPO="$HOME/Projects/cxpod"
  fi
fi

CXPOD_PROVIDERS_USER_DIR="$CXPOD_HOME/providers"
CXPOD_PROVIDERS_REPO_DIR="$CXPOD_REPO/providers"
CXPOD_STATE_DIR="$CXPOD_HOME/state"
CXPOD_HOMES_DIR="$CXPOD_HOME/codex-homes"
CXPOD_CURRENT_FILE="$CXPOD_HOME/current-provider"
CXPOD_STATUS_FILE="$CXPOD_HOME/cxpod-status.txt"
CXPOD_LOG_FILE="$CXPOD_HOME/log/cxpod.log"
CXPOD_ENV_FILE="$CXPOD_HOME/env"
CXPOD_AUTH_DIR="$CXPOD_HOME/codex-auth"
CXPOD_OAUTH_AUTH="$CXPOD_AUTH_DIR/oauth.json"
CXPOD_AUTH_ACCOUNTS_DIR="$CXPOD_AUTH_DIR/accounts"
CXPOD_CURRENT_AUTH_PROFILE_FILE="$CXPOD_HOME/current-auth-profile"
CXPOD_CODEX_APP_AUTH_PROFILE_FILE="$CXPOD_HOME/current-codex-app-auth-profile"
CXPOD_CONTEXT_DIR="$CXPOD_HOME/context"

CXPOD_CODEX_APP_BIN="/Applications/Codex.app/Contents/Resources/codex"
if [[ -z "${CXPOD_CODEX_BIN:-}" ]]; then
  if command -v codex >/dev/null 2>&1; then
    CXPOD_CODEX_BIN="$(command -v codex)"
  else
    CXPOD_CODEX_BIN="$CXPOD_CODEX_APP_BIN"
  fi
fi
CXPOD_USER_CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"

# ─── Logging ──────────────────────────────────────────────
ensure_runtime_dirs() {
  mkdir -p "$CXPOD_HOME" "$CXPOD_PROVIDERS_USER_DIR" "$CXPOD_STATE_DIR" \
    "$CXPOD_HOMES_DIR" "$CXPOD_AUTH_DIR" "$CXPOD_AUTH_ACCOUNTS_DIR" \
    "$CXPOD_CONTEXT_DIR" "$(dirname "$CXPOD_LOG_FILE")"
  chmod 700 "$CXPOD_HOME" "$CXPOD_PROVIDERS_USER_DIR" "$CXPOD_STATE_DIR" \
    "$CXPOD_HOMES_DIR" "$CXPOD_AUTH_DIR" "$CXPOD_AUTH_ACCOUNTS_DIR" \
    "$CXPOD_CONTEXT_DIR" "$(dirname "$CXPOD_LOG_FILE")" \
    2>/dev/null || true
  [[ -f "$CXPOD_ENV_FILE" ]] && chmod 600 "$CXPOD_ENV_FILE" 2>/dev/null || true
  [[ -f "$CXPOD_OAUTH_AUTH" ]] && chmod 600 "$CXPOD_OAUTH_AUTH" 2>/dev/null || true
  load_cxpod_env
}

load_cxpod_env() {
  [[ -f "$CXPOD_ENV_FILE" ]] || return 0
  chmod 600 "$CXPOD_ENV_FILE" 2>/dev/null || true
  set -a
  # shellcheck disable=SC1090
  source "$CXPOD_ENV_FILE"
  set +a
}

info() { printf '%s\n' "$*" >&2; }
warn() { printf '⚠️  %s\n' "$*" >&2; }
die()  { printf '❌ %s\n' "$*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "需要命令: $1"
}

require_codex_bin() {
  [[ -x "$CXPOD_CODEX_BIN" ]] && return 0
  if [[ "$CXPOD_CODEX_BIN" != */* ]] && command -v "$CXPOD_CODEX_BIN" >/dev/null 2>&1; then
    CXPOD_CODEX_BIN="$(command -v "$CXPOD_CODEX_BIN")"
    return 0
  fi
  die "找不到 Codex 本体。请安装 Codex CLI（npm i -g @openai/codex）或 Codex.app；也可设置 CXPOD_CODEX_BIN=/path/to/codex。"
}

# ─── Validation ───────────────────────────────────────────
is_valid_provider_name() {
  [[ "$1" =~ ^[A-Za-z0-9._-]+$ && "$1" != "." && "$1" != ".." ]]
}

is_valid_window_id() {
  [[ "$1" =~ ^cx-[0-9]+$ ]]
}

is_valid_auth_profile_name() {
  [[ "$1" =~ ^[A-Za-z0-9._-]+$ && "$1" != "." && "$1" != ".." ]]
}

# ─── Provider discovery ───────────────────────────────────
# User dir wins over repo dir (so users can override openai.json with secrets).
list_providers() {
  local seen=""
  local f name
  for f in "$CXPOD_PROVIDERS_USER_DIR"/*.json "$CXPOD_PROVIDERS_REPO_DIR"/*.json; do
    [[ -f "$f" ]] || continue
    name="$(basename "$f" .json)"
    [[ "$name" == *.example ]] && continue
    is_valid_provider_name "$name" || continue
    case " $seen " in *" $name "*) continue ;; esac
    seen="$seen $name"
    printf '%s\n' "$name"
  done
}

# Resolve provider id with prefix matching. "off" → "openai" if unique.
resolve_provider() {
  local q="$1"
  is_valid_provider_name "$q" || die "provider 名称非法: '$q'"
  local all
  all="$(list_providers)"
  if printf '%s\n' "$all" | grep -qx "$q"; then
    printf '%s' "$q"
    return 0
  fi
  local matches=()
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    [[ "$name" == "$q"* ]] && matches+=("$name")
  done <<< "$all"
  case ${#matches[@]} in
    0) die "未知 provider: '$q' (运行 'cxnow --list' 查看可用)" ;;
    1) printf '%s' "${matches[0]}" ;;
    *) die "provider '$q' 不唯一，匹配到: ${matches[*]}" ;;
  esac
}

# Locate the JSON file for a resolved provider name (user dir wins).
provider_file() {
  local name="$1"
  if [[ -f "$CXPOD_PROVIDERS_USER_DIR/$name.json" ]]; then
    printf '%s' "$CXPOD_PROVIDERS_USER_DIR/$name.json"
  elif [[ -f "$CXPOD_PROVIDERS_REPO_DIR/$name.json" ]]; then
    printf '%s' "$CXPOD_PROVIDERS_REPO_DIR/$name.json"
  else
    die "找不到 provider 文件: $name.json"
  fi
}

# ─── Badge formatter ──────────────────────────────────────
cxpod_badge() {
  local name="$1"
  local file emoji display
  file="$(provider_file "$name" 2>/dev/null)" || { printf '⚪ %s' "$name"; return; }
  if command -v python3 >/dev/null 2>&1; then
    while IFS= read -r line; do
      case "$line" in
        emoji=*) emoji="${line#emoji=}" ;;
        display=*) display="${line#display=}" ;;
      esac
    done < <(python3 - "$file" <<'PYEOF' 2>/dev/null || true
import json, sys
try:
    cfg = json.load(open(sys.argv[1]))
except Exception:
    cfg = {}
print("emoji=" + str(cfg.get("badge_emoji") or "⚪"))
print("display=" + str(cfg.get("display_name") or cfg.get("id") or ""))
PYEOF
)
  fi
  : "${emoji:=⚪}"
  : "${display:=$name}"
  printf '%s %s' "$emoji" "$display"
}

# ─── Atomic write ─────────────────────────────────────────
atomic_write() {
  local target="$1"; shift
  local dir tmp
  dir="$(dirname "$target")"
  mkdir -p "$dir"
  tmp="$(mktemp "$dir/.cxpod.XXXXXX")"
  cat > "$tmp"
  mv -f "$tmp" "$target"
  chmod 600 "$target" 2>/dev/null || true
}

auth_json_mode() {
  local file="$1"
  [[ -f "$file" ]] || return 1
  python3 - "$file" <<'PYEOF'
import json, sys
try:
    print(json.load(open(sys.argv[1])).get("auth_mode", ""))
except Exception:
    sys.exit(1)
PYEOF
}

copy_if_chatgpt_auth() {
  local source="$1" target="$2"
  [[ -f "$source" ]] || return 1
  [[ "$(auth_json_mode "$source" 2>/dev/null || true)" == "chatgpt" ]] || return 1
  cp "$source" "$target"
  chmod 600 "$target" 2>/dev/null || true
}

auth_profile_file() {
  local profile="$1"
  is_valid_auth_profile_name "$profile" || die "账号名称非法: '$profile'"
  printf '%s/%s.json' "$CXPOD_AUTH_ACCOUNTS_DIR" "$profile"
}

list_auth_profiles() {
  local seen="" f name
  for f in "$CXPOD_AUTH_ACCOUNTS_DIR"/*.json; do
    [[ -f "$f" ]] || continue
    name="$(basename "$f" .json)"
    is_valid_auth_profile_name "$name" || continue
    case " $seen " in *" $name "*) continue ;; esac
    seen="$seen $name"
    printf '%s\n' "$name"
  done
  if [[ -f "$CXPOD_OAUTH_AUTH" && " $seen " != *" default "* ]]; then
    printf '%s\n' "default"
  fi
}

resolve_auth_profile() {
  local q="$1"
  is_valid_auth_profile_name "$q" || die "账号名称非法: '$q'"
  local all
  all="$(list_auth_profiles)"
  if printf '%s\n' "$all" | grep -qx "$q"; then
    printf '%s' "$q"
    return 0
  fi
  local matches=()
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    [[ "$name" == "$q"* ]] && matches+=("$name")
  done <<< "$all"
  case ${#matches[@]} in
    0) die "未知 GPT 账号: '$q' (运行 'cxauth --list' 查看可用)" ;;
    1) printf '%s' "${matches[0]}" ;;
    *) die "GPT 账号 '$q' 不唯一，匹配到: ${matches[*]}" ;;
  esac
}

current_auth_profile() {
  local profile=""
  if [[ -f "$CXPOD_CURRENT_AUTH_PROFILE_FILE" ]]; then
    profile="$(tr -d '[:space:]' < "$CXPOD_CURRENT_AUTH_PROFILE_FILE")"
    if [[ -n "$profile" ]] && is_valid_auth_profile_name "$profile"; then
      printf '%s' "$profile"
      return 0
    fi
  fi
  if [[ -f "$CXPOD_AUTH_ACCOUNTS_DIR/default.json" || -f "$CXPOD_OAUTH_AUTH" ]]; then
    printf '%s' "default"
    return 0
  fi
  list_auth_profiles | head -1
}

current_codex_app_auth_profile() {
  local profile=""
  if [[ -f "$CXPOD_CODEX_APP_AUTH_PROFILE_FILE" ]]; then
    profile="$(tr -d '[:space:]' < "$CXPOD_CODEX_APP_AUTH_PROFILE_FILE")"
    if [[ -n "$profile" ]] && is_valid_auth_profile_name "$profile"; then
      printf '%s' "$profile"
      return 0
    fi
  fi
  return 1
}

select_auth_profile() {
  local requested="${1:-}" profile
  if [[ -n "$requested" ]]; then
    resolve_auth_profile "$requested"
    return 0
  fi
  profile="$(current_auth_profile 2>/dev/null || true)"
  printf '%s' "${profile:-default}"
}

set_current_auth_profile() {
  local profile="$1"
  is_valid_auth_profile_name "$profile" || die "账号名称非法: '$profile'"
  printf '%s' "$profile" | atomic_write "$CXPOD_CURRENT_AUTH_PROFILE_FILE"
}

set_current_codex_app_auth_profile() {
  local profile="$1"
  is_valid_auth_profile_name "$profile" || die "账号名称非法: '$profile'"
  printf '%s' "$profile" | atomic_write "$CXPOD_CODEX_APP_AUTH_PROFILE_FILE"
}

save_auth_profile_from_file() {
  local profile="$1" source="$2"
  is_valid_auth_profile_name "$profile" || die "账号名称非法: '$profile'"
  mkdir -p "$CXPOD_AUTH_ACCOUNTS_DIR"
  local target; target="$(auth_profile_file "$profile")"
  if ! copy_if_chatgpt_auth "$source" "$target"; then
    die "不是 Codex ChatGPT/OAuth 登录态: $source"
  fi
  if [[ "$profile" == "default" ]]; then
    cp "$target" "$CXPOD_OAUTH_AUTH"
    chmod 600 "$CXPOD_OAUTH_AUTH" 2>/dev/null || true
  fi
  set_current_auth_profile "$profile"
}

sync_oauth_authority_from_codex_home() {
  local source_home="${1:-$CXPOD_USER_CODEX_HOME}"
  local profile="${2:-}"
  [[ -n "$profile" ]] || profile="$(current_auth_profile 2>/dev/null || true)"
  [[ -n "$profile" ]] || profile="default"
  local source="$source_home/auth.json"
  [[ -f "$source" ]] || return 0
  local target; target="$(auth_profile_file "$profile")"
  if copy_if_chatgpt_auth "$source" "$target"; then
    if [[ "$profile" == "default" ]]; then
      cp "$target" "$CXPOD_OAUTH_AUTH"
      chmod 600 "$CXPOD_OAUTH_AUTH" 2>/dev/null || true
    fi
    info "🔐 已回吸 GPT 账号 '$profile' 登录态"
  fi
}

ensure_oauth_authority() {
  local profile="${1:-}"
  [[ -n "$profile" ]] || profile="$(select_auth_profile "")"
  local account_auth; account_auth="$(auth_profile_file "$profile")"
  [[ -f "$account_auth" ]] && return 0
  mkdir -p "$CXPOD_AUTH_DIR" "$CXPOD_AUTH_ACCOUNTS_DIR"
  local current="$CXPOD_USER_CODEX_HOME/auth.json"
  local legacy="$CXPOD_USER_CODEX_HOME/auth.json.chatgpt.bak"
  if [[ "$profile" == "default" && -f "$CXPOD_OAUTH_AUTH" ]]; then
    if copy_if_chatgpt_auth "$CXPOD_OAUTH_AUTH" "$account_auth"; then
      info "🔐 已迁移默认 GPT 账号: $account_auth"
      return 0
    fi
  fi
  if [[ "$profile" == "default" ]] && copy_if_chatgpt_auth "$current" "$account_auth"; then
    cp "$account_auth" "$CXPOD_OAUTH_AUTH"
    chmod 600 "$CXPOD_OAUTH_AUTH" 2>/dev/null || true
    info "🔐 已迁移当前 GPT 账号: $account_auth"
    return 0
  fi
  if [[ "$profile" == "default" ]] && copy_if_chatgpt_auth "$legacy" "$account_auth"; then
    cp "$account_auth" "$CXPOD_OAUTH_AUTH"
    chmod 600 "$CXPOD_OAUTH_AUTH" 2>/dev/null || true
    info "🔐 已迁移 GPT 账号冷备: $account_auth"
    return 0
  fi
  die "缺少 GPT 账号 '$profile' 登录态: $account_auth。请先运行: cxauth login $profile"
}

sync_auth_json() {
  local target_home="$1" kind="${2:-official}" provider_name="${3:-}" auth_profile="${4:-}"
  local target="$target_home/auth.json"
  mkdir -p "$target_home"
  chmod 700 "$target_home" 2>/dev/null || true
  case "$kind" in
    official)
      [[ -n "$auth_profile" ]] || auth_profile="$(select_auth_profile "")"
      ensure_oauth_authority "$auth_profile"
      local account_auth; account_auth="$(auth_profile_file "$auth_profile")"
      [[ -e "$target" || -L "$target" ]] && rm -f "$target"
      if [[ "$target_home" == "$CXPOD_USER_CODEX_HOME" ]]; then
        cp "$account_auth" "$target"
        chmod 600 "$target" 2>/dev/null || true
      else
        ln -s "$account_auth" "$target"
      fi
      ;;
    relay)
      [[ -n "$provider_name" ]] || die "relay auth 需要 provider 名称"
      [[ -e "$target" || -L "$target" ]] && rm -f "$target"
      if ! _write_relay_auth "$provider_name" "$target"; then
        die "无法为 provider '$provider_name' 生成 auth.json，请检查 ~/.cxpod/env 中的 API key"
      fi
      ;;
    *)
      die "未知 provider kind: $kind"
      ;;
  esac
}

# ─── CODEX_HOME per-window helpers ────────────────────────
# Each cxpod window gets its own CODEX_HOME under $CXPOD_HOMES_DIR/<id>/.
# We seed it from the user's real ~/.codex (auth.json + memories) so codex
# logs in normally, then overwrite config.toml with our isolated provider.
window_codex_home() {
  local id="$1"
  is_valid_window_id "$id" || die "window id 非法: $id"
  printf '%s/%s' "$CXPOD_HOMES_DIR" "$id"
}

seed_window_codex_home() {
  local id="$1"
  local kind="${2:-official}"
  local provider_name="${3:-}"
  local auth_profile="${4:-}"
  local home; home="$(window_codex_home "$id")"
  mkdir -p "$home"

  local item
  for item in installation_id models_cache.json; do
    if [[ -e "$CXPOD_USER_CODEX_HOME/$item" ]] && [[ ! -e "$home/$item" ]]; then
      ln -s "$CXPOD_USER_CODEX_HOME/$item" "$home/$item"
    fi
  done
  # For official providers, link to cxpod's OAuth authority.
  # For relay providers, generate an apikey-mode auth.json so codex
  # sends the provider's api_key as a Bearer token.
  sync_auth_json "$home" "$kind" "$provider_name" "$auth_profile"
  printf '%s' "$home"
}

_write_relay_auth() {
  local provider_name="$1" target="$2"
  local pfile; pfile="$(provider_file "$provider_name" 2>/dev/null)" || return 0
  require_cmd python3
  python3 - "$pfile" <<'PYEOF' | atomic_write "$target"
import json, os, re, sys

with open(sys.argv[1]) as f:
    cfg = json.load(f)

mp = cfg.get('model_provider_toml') or {}

# Support both api_key (with ${ENV:X} placeholder) and env_key (bare var name)
raw_key = mp.get('api_key', '')
env_key_name = mp.get('env_key', '')
env_re = re.compile(r'\$\{ENV:([A-Za-z_][A-Za-z0-9_]*)\}')

key = ''
if raw_key:
    m = env_re.fullmatch(raw_key)
    key = os.environ.get(m.group(1), '') if m else raw_key
elif env_key_name:
    key = os.environ.get(env_key_name, '')

if key:
    print(json.dumps({"auth_mode": "apikey", "OPENAI_API_KEY": key}))
else:
    sys.exit(1)
PYEOF
}

provider_env_names() {
  local name="$1"
  local file; file="$(provider_file "$name")"
  require_cmd python3
  python3 - "$file" <<'PYEOF'
import json, re, sys

with open(sys.argv[1]) as f:
    cfg = json.load(f)

env_re = re.compile(r'\$\{ENV:([A-Za-z_][A-Za-z0-9_]*)\}')
refs = set()

def walk(value):
    if isinstance(value, str):
        refs.update(env_re.findall(value))
    elif isinstance(value, dict):
        for item in value.values():
            walk(item)
    elif isinstance(value, list):
        for item in value:
            walk(item)

walk(cfg)
mp = cfg.get('model_provider_toml') or {}
env_key = mp.get('env_key')
if isinstance(env_key, str) and env_key:
    refs.add(env_key)
if mp.get('requires_openai_auth'):
    refs.add('OPENAI_API_KEY')
for item in sorted(refs):
    print(item)
PYEOF
}

# ─── Render config.toml for a provider ───────────────────
# Emits a minimal TOML file that selects the named provider.
# Reads the provider JSON's `model_provider_toml` block plus optional
# `default_model`. Resolves `${ENV:VAR}` placeholders in any string field.
render_config_toml() {
  local name="$1"
  local file; file="$(provider_file "$name")"
  require_cmd python3
  python3 - "$file" "$name" <<'PYEOF'
import json, os, re, sys

path, name = sys.argv[1], sys.argv[2]
with open(path) as f:
    cfg = json.load(f)

ENV_RE = re.compile(r'\$\{ENV:([A-Za-z_][A-Za-z0-9_]*)\}')

def resolve(val):
    if isinstance(val, str):
        m = ENV_RE.fullmatch(val)
        if m:
            return os.environ.get(m.group(1), '')
        return val
    if isinstance(val, dict):
        return {k: resolve(v) for k, v in val.items()}
    if isinstance(val, list):
        return [resolve(v) for v in val]
    return val

def env_ref(val):
    """Return the env var name if val is a pure ${ENV:X} placeholder."""
    if isinstance(val, str):
        m = ENV_RE.fullmatch(val)
        if m:
            return m.group(1)
    return None

raw_mp = cfg.get('model_provider_toml') or {}
mp = resolve(raw_mp)
provider_id = cfg.get('id') or name
default_model = cfg.get('default_model') or ''
kind = cfg.get('kind') or 'relay'
cxpod_only_keys = {'api_key', 'env_key', 'requires_openai_auth'}

BUILTIN = {'openai'}

def toml_escape(s):
    return '"' + str(s).replace('\\', '\\\\').replace('"', '\\"') + '"'

lines = []
if default_model:
    lines.append(f'model = {toml_escape(default_model)}')
lines.append(f'model_provider = {toml_escape(provider_id)}')
lines.append('disable_response_storage = true')

if kind != 'official' and provider_id not in BUILTIN:
    lines.append('')
    lines.append(f'[model_providers.{provider_id}]')
    for k in raw_mp:
        if k in cxpod_only_keys:
            continue
        v = mp.get(k)
        if v in (None, ''):
            continue
        if isinstance(v, bool):
            lines.append(f'{k} = {"true" if v else "false"}')
        elif isinstance(v, (int, float)):
            lines.append(f'{k} = {v}')
        else:
            lines.append(f'{k} = {toml_escape(v)}')

print('\n'.join(lines))
PYEOF
}

provider_env_assignments() {
  local name="$1"
  local file; file="$(provider_file "$name")"
  require_cmd python3
  python3 - "$file" <<'PYEOF'
import json, os, re, shlex, sys

with open(sys.argv[1]) as f:
    cfg = json.load(f)

env_re = re.compile(r'\$\{ENV:([A-Za-z_][A-Za-z0-9_]*)\}')
refs = set()

def walk(value):
    if isinstance(value, str):
        refs.update(env_re.findall(value))
    elif isinstance(value, dict):
        for item in value.values():
            walk(item)
    elif isinstance(value, list):
        for item in value:
            walk(item)

walk(cfg)
for name in sorted(refs):
    val = os.environ.get(name)
    if val:
        print(f'{name}={shlex.quote(val)}')

mp = cfg.get('model_provider_toml') or {}
env_key = mp.get('env_key')
if isinstance(env_key, str) and env_key and os.environ.get(env_key):
    print(f'{env_key}={shlex.quote(os.environ[env_key])}')
if mp.get('requires_openai_auth') and os.environ.get('OPENAI_API_KEY'):
    print(f'OPENAI_API_KEY={shlex.quote(os.environ["OPENAI_API_KEY"])}')
PYEOF
}

provider_env_file() {
  local window_id="$1"
  is_valid_window_id "$window_id" || die "window id 非法: $window_id"
  printf '%s/%s/provider.env' "$CXPOD_HOMES_DIR" "$window_id"
}

write_provider_env_file() {
  local name="$1" window_id="$2"
  local file; file="$(provider_env_file "$window_id")"
  mkdir -p "$(dirname "$file")"
  provider_env_assignments "$name" | atomic_write "$file"
  chmod 600 "$file" 2>/dev/null || true
  printf '%s' "$file"
}

# ─── State file (per-window) ──────────────────────────────
# Schema: {"window_id":"cx-1","provider":"openai","model":"gpt-5.5","updated_at":"..."}
# write_window_state merges into the existing state file so that fields
# written by other scripts (e.g. tmux_target, project_dir from cxstart)
# are not lost.
write_window_state() {
  local id="$1" provider="$2" model="${3:-}" auth_profile="${4:-}"
  is_valid_window_id "$id" || die "window id 非法: $id"
  local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local file="$CXPOD_STATE_DIR/$id.json"
  python3 - "$file" "$id" "$provider" "$model" "$auth_profile" "$ts" <<'PYEOF' | atomic_write "$file"
import json, os, sys
path, window_id, provider, model, auth_profile, ts = sys.argv[1:7]
try:
    existing = json.load(open(path)) if os.path.isfile(path) else {}
except Exception:
    existing = {}
existing.update({
    "window_id": window_id,
    "provider": provider,
    "model": model,
    "updated_at": ts,
})
if auth_profile:
    existing["auth_profile"] = auth_profile
else:
    existing.pop("auth_profile", None)
print(json.dumps(existing, ensure_ascii=False, indent=2))
PYEOF
}

read_window_state_field() {
  local id="$1" field="$2"
  local file="$CXPOD_STATE_DIR/$id.json"
  [[ -f "$file" ]] || return 1
  python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2], ''))" \
    "$file" "$field"
}

# Find the latest rollout-*.jsonl under a window's codex-home.
latest_session_file() {
  local id="$1"
  local base="$CXPOD_HOMES_DIR/$id/sessions"
  [[ -d "$base" ]] || return 1
  find "$base" -type f -name 'rollout-*.jsonl' -print0 2>/dev/null |
    xargs -0 stat -f '%m %N' 2>/dev/null |
    sort -n | tail -1 | awk '{ $1=""; sub(/^ /, ""); print }'
}

# Bridge context: extract recent conversation from rollout into cxpod's
# private context dir. AGENTS.md injection is a separate explicit opt-in.
bridge_context() {
  local window_id="$1" provider="$2"
  [[ "${CXPOD_CONTEXT_BRIDGE:-0}" == "1" ]] || return 0
  local project_dir
  project_dir="$(read_window_state_field "$window_id" "project_dir" 2>/dev/null || echo "")"
  [[ -n "$project_dir" && -d "$project_dir" ]] || return 0
  local rollout
  rollout="$(latest_session_file "$window_id" 2>/dev/null || true)"
  [[ -n "$rollout" && -f "$rollout" ]] || return 0
  local script="$CXPOD_REPO/bin/lib/extract-context.py"
  [[ -f "$script" ]] || return 0
  mkdir -p "$CXPOD_CONTEXT_DIR"
  chmod 700 "$CXPOD_CONTEXT_DIR" 2>/dev/null || true
  local out tmp
  out="$CXPOD_CONTEXT_DIR/$window_id.md"
  tmp="$out.tmp"
  if python3 "$script" "$rollout" --provider "$provider" > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$out"
    chmod 600 "$out" 2>/dev/null || true
  else
    rm -f "$tmp"
    return 1
  fi
  if [[ "${CXPOD_CONTEXT_BRIDGE_INJECT_AGENTS:-0}" == "1" ]]; then
    python3 "$script" "$rollout" --provider "$provider" --inject "$project_dir" 2>/dev/null || true
  fi
}

# Allocate the next available window id (cx-1, cx-2, ...).
allocate_window_id() {
  local n=1
  while [[ -e "$CXPOD_STATE_DIR/cx-$n.json" ]] || [[ -e "$CXPOD_HOMES_DIR/cx-$n" ]]; do
    n=$((n + 1))
  done
  printf 'cx-%d' "$n"
}

#!/usr/bin/env bash
# install.sh — One-command installer for cxpod.
set -euo pipefail

CXPOD_GIT_URL="${CXPOD_GIT_URL:-https://github.com/DoubaoYIN/cxpod.git}"
CXPOD_REPO_DIR="${CXPOD_REPO_DIR:-$HOME/Projects/cxpod}"
CXPOD_INSTALL_APP="${CXPOD_INSTALL_APP:-1}"
CXPOD_OPEN_APP="${CXPOD_OPEN_APP:-1}"
CXPOD_INSTALL_HOOKS="${CXPOD_INSTALL_HOOKS:-0}"
CXPOD_INSTALLED_APP_PATH=""

info()  { printf '  %s\n' "$*"; }
warn()  { printf '⚠️  %s\n' "$*" >&2; }
die()   { printf '❌ %s\n' "$*" >&2; exit 1; }

script_dir() {
  local src="${BASH_SOURCE[0]:-$0}"
  if [[ -f "$src" ]]; then
    while [[ -L "$src" ]]; do
      local dir
      dir="$(cd -P "$(dirname "$src")" && pwd)"
      src="$(readlink "$src")"
      [[ "$src" != /* ]] && src="$dir/$src"
    done
    cd -P "$(dirname "$src")" && pwd
  else
    pwd
  fi
}

repo_is_checkout() {
  [[ -f "$REPO/bin/cxstart" && -f "$REPO/providers/openai.json" && -d "$REPO/menubar" ]]
}

bootstrap_repo() {
  REPO="$(script_dir)"
  if repo_is_checkout; then
    return 0
  fi

  command -v git >/dev/null 2>&1 || die "一键安装需要 git。可先安装 Xcode Command Line Tools 或 Homebrew。"
  REPO="$CXPOD_REPO_DIR"
  mkdir -p "$(dirname "$REPO")"

  if [[ -d "$REPO/.git" ]]; then
    echo "更新 cxpod: $REPO"
    git -C "$REPO" pull --ff-only
  elif [[ -e "$REPO" ]]; then
    die "$REPO 已存在但不是 Git 仓库。请移动它，或设置 CXPOD_REPO_DIR 指向其他目录。"
  else
    echo "下载 cxpod 到: $REPO"
    git clone --depth 1 "$CXPOD_GIT_URL" "$REPO"
  fi

  repo_is_checkout || die "仓库不完整: $REPO"
}

prompt_yes() {
  local message="$1" ans
  [[ "${CXPOD_ASSUME_YES:-0}" == "1" ]] && return 0
  [[ -r /dev/tty ]] || return 1
  printf '%s [Y/n] ' "$message" > /dev/tty
  read -r ans < /dev/tty || return 1
  [[ -z "$ans" || "$ans" == "y" || "$ans" == "Y" ]]
}

brew_package_for() {
  case "$1" in
    python3) printf 'python' ;;
    *) printf '%s' "$1" ;;
  esac
}

check_deps() {
  local missing=() optional_missing=()
  for name in tmux python3 bash; do
    if command -v "$name" >/dev/null 2>&1; then
      info "✅ $name ($(command -v "$name"))"
    else
      info "❌ $name 未找到"
      missing+=("$name")
    fi
  done
  for name in fzf swift; do
    if command -v "$name" >/dev/null 2>&1; then
      info "✅ $name ($(command -v "$name"))"
    else
      info "⚪ $name 未找到（可选）"
      optional_missing+=("$name")
    fi
  done

  if (( ${#missing[@]} == 0 )); then
    return 0
  fi

  if command -v brew >/dev/null 2>&1 && prompt_yes "是否用 Homebrew 安装缺失依赖：${missing[*]}？"; then
    local packages=() dep
    for dep in "${missing[@]}"; do
      packages+=("$(brew_package_for "$dep")")
    done
    brew install "${packages[@]}"
    check_deps
    return
  fi

  echo ""
  echo "请先安装必要依赖："
  echo "  brew install tmux python"
  exit 1
}

pick_bin_dir() {
  if [[ -n "${CXPOD_BIN_DIR:-}" ]]; then
    BIN_DIR="$CXPOD_BIN_DIR"
  elif [[ -d "$HOME/.local/bin" ]] && [[ ":$PATH:" == *":$HOME/.local/bin:"* ]]; then
    BIN_DIR="$HOME/.local/bin"
  elif [[ -d "/opt/homebrew/bin" && -w "/opt/homebrew/bin" ]]; then
    BIN_DIR="/opt/homebrew/bin"
  elif [[ -d "/usr/local/bin" && -w "/usr/local/bin" ]]; then
    BIN_DIR="/usr/local/bin"
  else
    BIN_DIR="$HOME/.local/bin"
  fi
  mkdir -p "$BIN_DIR"
}

install_cli_links() {
  local cmds=(cxstart cxuse cxnow cx-status cx-app-switch)
  for cmd in "${cmds[@]}"; do
    local src="$REPO/bin/$cmd"
    local dest="$BIN_DIR/$cmd"
    if [[ -L "$dest" ]]; then
      rm "$dest"
    elif [[ -e "$dest" ]]; then
      warn "$dest 已存在且不是软链接，跳过"
      continue
    fi
    ln -s "$src" "$dest"
    info "🔗 $cmd -> $dest"
  done
}

seed_user_config() {
  mkdir -p "$HOME/.cxpod/providers" "$HOME/.cxpod/log"
  chmod 700 "$HOME/.cxpod" "$HOME/.cxpod/providers" "$HOME/.cxpod/log" 2>/dev/null || true
  if [[ ! -f "$HOME/.cxpod/providers/relay.example.json" ]]; then
    cp "$REPO/providers/relay.example.json" "$HOME/.cxpod/providers/" 2>/dev/null || true
    chmod 600 "$HOME/.cxpod/providers/relay.example.json" 2>/dev/null || true
  fi
}

install_menubar_app() {
  [[ "$CXPOD_INSTALL_APP" == "1" ]] || return 0
  if ! command -v swift >/dev/null 2>&1; then
    warn "未找到 swift，跳过菜单栏 app 构建；CLI 已可用。"
    return 0
  fi

  local install_dir="${CXPOD_INSTALL_DIR:-}"
  if [[ -z "$install_dir" ]]; then
    if [[ -d "/Applications" && -w "/Applications" ]]; then
      install_dir="/Applications"
    else
      install_dir="$HOME/Applications"
    fi
  fi
  mkdir -p "$install_dir"

  echo "构建并安装菜单栏 app..."
  local args=(--install)
  [[ "$CXPOD_OPEN_APP" == "1" ]] || args+=(--no-restart)
  if CXPOD_INSTALL_DIR="$install_dir" bash "$REPO/menubar/build.sh" "${args[@]}"; then
    CXPOD_INSTALLED_APP_PATH="$install_dir/CxPod.app"
    info "📍 CxPod.app: $CXPOD_INSTALLED_APP_PATH"
  else
    warn "菜单栏 app 构建失败；CLI 工具不受影响。"
  fi
}

bootstrap_repo

echo "检查依赖:"
check_deps
echo ""

pick_bin_dir
echo "CLI 安装目录: $BIN_DIR"
install_cli_links
echo ""

if [[ "$CXPOD_INSTALL_HOOKS" == "1" && -d "$REPO/.git" ]]; then
  bash "$REPO/scripts/install-hooks.sh"
fi
echo ""

seed_user_config
install_menubar_app
echo ""

if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
  warn "$BIN_DIR 不在当前 PATH 中。请添加到 ~/.zshrc 或 ~/.bashrc："
  echo "  export PATH=\"$BIN_DIR:\$PATH\""
  echo ""
fi

echo "✅ cxpod 安装完成"
echo ""
echo "下一步："
echo "  1. 先确认 Codex.app / Codex CLI 已登录。"
echo "  2. 启动会话：cxstart -d ~/my-project -p openai"
echo "  3. 查看会话：cxnow --list"
if [[ -n "$CXPOD_INSTALLED_APP_PATH" && -d "$CXPOD_INSTALLED_APP_PATH" ]]; then
  echo "  4. 打开菜单栏：open \"$CXPOD_INSTALLED_APP_PATH\""
else
  echo "  4. 菜单栏 app 可稍后安装：bash \"$REPO/menubar/build.sh\" --install"
fi

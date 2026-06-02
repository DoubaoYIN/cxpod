#!/usr/bin/env bash
# uninstall.sh — Remove cxpod symlinks from PATH dirs.
#
# Does NOT remove ~/.cxpod/ by default (your providers + sessions live there).
# Pass --purge to wipe ~/.cxpod/ as well.
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
PURGE=0
[[ "${1:-}" == "--purge" ]] && PURGE=1

CMDS=(cxstart cxuse cxnow cx-status cx-app-switch)
SEARCH_DIRS=(
  "${CXPOD_BIN_DIR:-}"
  "$HOME/.local/bin"
  "/usr/local/bin"
  "/opt/homebrew/bin"
)

removed=0
for dir in "${SEARCH_DIRS[@]}"; do
  [[ -z "$dir" ]] && continue
  for cmd in "${CMDS[@]}"; do
    link="$dir/$cmd"
    if [[ -L "$link" ]]; then
      target="$(readlink "$link")"
      case "$target" in
        "$REPO/bin/$cmd"|*/cxpod/bin/$cmd)
          rm "$link"
          echo "🗑  removed $link"
          removed=$((removed + 1))
          ;;
      esac
    fi
  done
done

if (( removed == 0 )); then
  echo "(没有找到 cxpod 软链接)"
fi

if (( PURGE )); then
  echo ""
  read -r -p "⚠️  将删除 ~/.cxpod/（含 providers、state、session homes）。确认？(y/N) " ans
  if [[ "$ans" == "y" || "$ans" == "Y" ]]; then
    rm -rf "$HOME/.cxpod"
    echo "🗑  ~/.cxpod removed"
  else
    echo "已取消 --purge"
  fi
else
  echo ""
  echo "ℹ️  ~/.cxpod/ 保留（含你的 providers 和 session 数据）。"
  echo "   要一并删除请运行：  $0 --purge"
fi

echo "✅ 卸载完成"

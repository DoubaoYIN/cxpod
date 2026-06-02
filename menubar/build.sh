#!/usr/bin/env bash
# build.sh — compile CxpodMenuBar and wrap it in a .app bundle.
# Output: menubar/build/CxPod.app
set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"
APP_NAME="CxPod"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
EXEC_NAME="CxpodMenuBar"
if [[ -n "${CXPOD_INSTALL_DIR:-}" ]]; then
  INSTALL_DIR="$CXPOD_INSTALL_DIR"
elif [[ -d "/Applications" && -w "/Applications" ]]; then
  INSTALL_DIR="/Applications"
else
  INSTALL_DIR="$HOME/Applications"
fi
INSTALL_APP_DIR="$INSTALL_DIR/$APP_NAME.app"
INSTALL_APP=0
RESTART_APP=1

info() { printf '\033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '\033[33m⚠\033[0m  %s\n' "$*" >&2; }

usage() {
  cat <<EOF
Usage: $(basename "$0") [--install] [--no-restart]

Options:
  --install     Install $APP_NAME.app into $INSTALL_DIR, replacing the running app
  --no-restart  Do not reopen the app after --install
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install|install) INSTALL_APP=1 ;;
    --no-restart) RESTART_APP=0 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

info "swift build -c release"
cd "$SCRIPT_DIR"
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)/$EXEC_NAME"
[[ -f "$BIN_PATH" ]] || { echo "找不到二进制: $BIN_PATH" >&2; exit 1; }

if [[ ! -f "$SCRIPT_DIR/Resources/AppIcon.icns" || ! -f "$SCRIPT_DIR/Resources/MenuBarIcon.pdf" || "$SCRIPT_DIR/Scripts/generate_icons.swift" -nt "$SCRIPT_DIR/Resources/AppIcon.icns" ]]; then
  info "生成图标资源"
  swift "$SCRIPT_DIR/Scripts/generate_icons.swift"
  iconutil -c icns "$SCRIPT_DIR/Resources/AppIcon.iconset" -o "$SCRIPT_DIR/Resources/AppIcon.icns"
fi

info "打包 $APP_NAME.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/$EXEC_NAME"
cp "$SCRIPT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$SCRIPT_DIR/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
cp "$SCRIPT_DIR/Resources/MenuBarIcon.pdf" "$APP_DIR/Contents/Resources/MenuBarIcon.pdf"

codesign --force --sign - "$APP_DIR" >/dev/null 2>&1 || true

echo
info "构建完成: $APP_DIR"
echo
echo "运行:   open \"$APP_DIR\""
echo "安装:   $(basename "$0") --install"

if [[ "$INSTALL_APP" -eq 1 ]]; then
  info "安装到 $INSTALL_APP_DIR"
  if pgrep -x "$EXEC_NAME" >/dev/null 2>&1; then
    pkill -x "$EXEC_NAME" || true
    sleep 0.5
  fi
  rm -rf "$INSTALL_APP_DIR"
  ditto "$APP_DIR" "$INSTALL_APP_DIR"
  codesign --force --sign - "$INSTALL_APP_DIR" >/dev/null 2>&1 || true
  if [[ "$RESTART_APP" -eq 1 ]]; then
    open "$INSTALL_APP_DIR"
    info "已重启 $APP_NAME"
  else
    warn "已安装但未重启"
  fi
fi

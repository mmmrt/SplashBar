#!/bin/zsh
# SplashMLX 构建脚本
#  1) 编译 makeicons.swift，生成菜单栏三态图标 + 应用图标(AppIcon.icns)
#  2) 编译 main.swift 成常驻菜单栏的 .app（无窗口、无 Dock 图标）
set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$HOME/Applications/SplashMLX.app"
BIN_DIR="$APP_DIR/Contents/MacOS"
RES_DIR="$APP_DIR/Contents/Resources"
OBJ_DIR="$SRC_DIR/.build"
SDK="$(xcrun --show-sdk-path)"

# 先退掉正在运行的实例，再重建。
# 原因：对一个**正在运行**的 .app 执行 rm -rf 时，macOS 会把整个 bundle 挪进废纸篓，
# 而旧进程继续从废纸篓里那份二进制运行 —— 结果就是"代码改了、也重新构建了、菜单栏却毫无变化"，
# 而且从 ~/Applications 完全看不出异常（那里确实是新的）。pkill 一次就不会踩。
if pgrep -f "$APP_DIR/Contents/MacOS/" >/dev/null 2>&1; then
  echo "[0/7] quit the running instance (otherwise the old bundle ends up in the Trash)"
  pkill -f "$APP_DIR/Contents/MacOS/" 2>/dev/null || true
  sleep 1
fi

echo "[1/7] clean previous build"
rm -rf "$OBJ_DIR" "$APP_DIR"
mkdir -p "$OBJ_DIR" "$BIN_DIR" "$RES_DIR"

echo "[2/7] compile icon generator"
xcrun swiftc -O -swift-version 5 -sdk "$SDK" \
  -target arm64-apple-macosx13.0 \
  -o "$OBJ_DIR/makeicons" "$SRC_DIR/makeicons.swift"

echo "[3/7] generate icons"
"$OBJ_DIR/makeicons" "$OBJ_DIR" | sed 's/^/      /'
iconutil -c icns "$OBJ_DIR/AppIcon.iconset" -o "$RES_DIR/AppIcon.icns"
cp "$OBJ_DIR"/menubar_*.png "$RES_DIR/"

echo "[4/7] compile main app (AppKit)"
xcrun swiftc -O -swift-version 5 -sdk "$SDK" \
  -target arm64-apple-macosx13.0 \
  -o "$BIN_DIR/SplashMLX" "$SRC_DIR/main.swift"

echo "[5/7] assemble .app bundle"
cp "$SRC_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"
chmod +x "$BIN_DIR/SplashMLX"

echo "[6/7] clear quarantine + ad-hoc sign"
xattr -dr com.apple.quarantine "$APP_DIR" 2>/dev/null || true
codesign --force --sign - --deep "$APP_DIR" 2>/dev/null || \
  echo "      codesign skipped (app still runs locally)"

echo "[7/7] clean intermediates"
rm -rf "$OBJ_DIR"

echo
echo "✅ Build complete: $APP_DIR"
echo "   resources: $(ls "$RES_DIR" | wc -l | tr -d ' ') files"
echo "   launch: open ~/Applications/SplashMLX.app"

#!/bin/zsh
# SplashBar 构建脚本
#  1) 编译 makeicons.swift，生成菜单栏三态图标 + 应用图标(AppIcon.icns)
#  2) 编译 main.swift 成常驻菜单栏的 .app（无窗口、无 Dock 图标）
set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$HOME/Applications/SplashBar.app"
BIN_DIR="$APP_DIR/Contents/MacOS"
RES_DIR="$APP_DIR/Contents/Resources"
OBJ_DIR="$SRC_DIR/.build"
SDK="$(xcrun --show-sdk-path)"

echo "[1/7] 清理旧产物"
rm -rf "$OBJ_DIR" "$APP_DIR"
mkdir -p "$OBJ_DIR" "$BIN_DIR" "$RES_DIR"

echo "[2/7] 编译图标生成器"
xcrun swiftc -O -swift-version 5 -sdk "$SDK" \
  -target arm64-apple-macosx13.0 \
  -o "$OBJ_DIR/makeicons" "$SRC_DIR/makeicons.swift"

echo "[3/7] 生成图标"
"$OBJ_DIR/makeicons" "$OBJ_DIR" | sed 's/^/      /'
iconutil -c icns "$OBJ_DIR/AppIcon.iconset" -o "$RES_DIR/AppIcon.icns"
cp "$OBJ_DIR"/menubar_*.png "$RES_DIR/"

echo "[4/7] 编译主程序 (AppKit)"
xcrun swiftc -O -swift-version 5 -sdk "$SDK" \
  -target arm64-apple-macosx13.0 \
  -o "$BIN_DIR/SplashBar" "$SRC_DIR/main.swift"

echo "[5/7] 组装 .app 包"
cp "$SRC_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"
chmod +x "$BIN_DIR/SplashBar"

echo "[6/7] 清除隔离属性 + 临时签名"
xattr -dr com.apple.quarantine "$APP_DIR" 2>/dev/null || true
codesign --force --sign - --deep "$APP_DIR" 2>/dev/null || \
  echo "      跳过签名（不影响本机运行）"

echo "[7/7] 清理中间产物"
rm -rf "$OBJ_DIR"

echo
echo "✅ 构建完成: $APP_DIR"
echo "   资源: $(ls "$RES_DIR" | wc -l | tr -d ' ') 个"
echo "   启动: open ~/Applications/SplashBar.app"

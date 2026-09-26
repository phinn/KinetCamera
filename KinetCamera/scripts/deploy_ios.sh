#!/bin/bash
# KinetCamera iOS 真机部署:构建 → 安装 → 启动
set -e
UDID="00008140-000603E91A44801C"
cd "$(dirname "$0")/.."
xcodebuild -project KinetCamera.xcodeproj -scheme KinetCameraiOS \
  -destination "id=$UDID" -allowProvisioningUpdates build
APP=$(ls -d ~/Library/Developer/Xcode/DerivedData/KinetCamera-*/Build/Products/Debug-iphoneos/KinetCamera.app | head -1)
xcrun devicectl device install app --device "$UDID" "$APP"
xcrun devicectl device process launch --device "$UDID" com.kinet.KinetCamera.iOS
echo "✅ 已部署并启动"

#!/bin/bash
# Damagochi.app 번들을 build/ 아래에 만든다.
#
#   scripts/build-app.sh          빌드만 (현재 Mac 아키텍처, 임시 서명)
#   scripts/build-app.sh --run    빌드 후 (실행 중이면 종료하고) 다시 실행
#
# 환경 변수 (배포용 빌드는 scripts/release.sh 가 설정한다):
#   VERSION        앱 버전 (기본 0.1.0)
#   UNIVERSAL=1    Apple Silicon + Intel 유니버설 바이너리
#   SIGN_IDENTITY  코드 서명 인증서 이름 (기본 "-" = 임시 서명)
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  swift build -c release --arch arm64 --arch x86_64
  BIN=".build/apple/Products/Release/Damagochi"
else
  swift build -c release
  BIN=".build/release/Damagochi"
fi

APP="build/Damagochi.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Damagochi"
cp -R Resources/sprites "$APP/Contents/Resources/sprites"
cp Resources/claude-statusline-hook.sh "$APP/Contents/Resources/"

# 아이콘 (.icns)
if [[ -f Resources/icon_1024.png ]]; then
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s Resources/icon_1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) Resources/icon_1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Damagochi</string>
  <key>CFBundleDisplayName</key><string>다마고치</string>
  <key>CFBundleIdentifier</key><string>com.canine89.damagochi</string>
  <key>CFBundleExecutable</key><string>Damagochi</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

if [[ "$SIGN_IDENTITY" == "-" ]]; then
  codesign --force --sign - "$APP" >/dev/null 2>&1
else
  # 공증에는 hardened runtime 과 보안 타임스탬프가 필요하다
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
fi
echo "built $APP ($VERSION, $(lipo -archs "$APP/Contents/MacOS/Damagochi"))"

if [[ "${1:-}" == "--run" ]]; then
  pkill -x Damagochi 2>/dev/null || true
  sleep 0.3
  open "$APP"
  echo "launched"
fi

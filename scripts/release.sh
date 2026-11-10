#!/bin/bash
# 배포용 파일을 만든다: 유니버설 빌드 → Developer ID 서명 → DMG → 공증 → 스테이플
#                      → 자동 업데이트용 ZIP + appcast.xml (Sparkle EdDSA 서명)
#
#   scripts/release.sh 0.2.0                   전체 과정
#   scripts/release.sh 0.2.0 --skip-notarize   서명·DMG 까지만 (로컬 점검용, 배포 금지)
#
# 결과물 (dist/):
#   Damagochi-<버전>.dmg   사람이 내려받아 설치하는 파일
#   Damagochi-<버전>.zip   설치된 앱이 자동 업데이트로 받는 파일
#   appcast.xml            새 버전 정보. 앱은 releases/latest/download/appcast.xml 을 읽는다
#
# 환경 변수:
#   SIGN_IDENTITY    서명 인증서 (기본: 키체인의 첫 "Developer ID Application")
#   NOTARY_PROFILE   notarytool 키체인 프로필 이름 (기본: damagochi-notary)
#   SPARKLE_ACCOUNT  업데이트 서명 키의 키체인 계정 (기본: damagochi)
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?버전을 지정하세요. 예: scripts/release.sh 0.2.0}"
SKIP_NOTARIZE=0
[[ "${2:-}" == "--skip-notarize" ]] && SKIP_NOTARIZE=1

SIGN_IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning \
  | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)}"
if [[ -z "$SIGN_IDENTITY" ]]; then
  echo "error: 키체인에서 'Developer ID Application' 인증서를 찾지 못했습니다." >&2
  exit 1
fi
NOTARY_PROFILE="${NOTARY_PROFILE:-damagochi-notary}"
SPARKLE_ACCOUNT="${SPARKLE_ACCOUNT:-damagochi}"
SPARKLE_BIN=".build/artifacts/sparkle/Sparkle/bin"
REPO_URL="https://github.com/Canine89/damagochi"

swift package resolve >/dev/null

# 업데이트 서명 키가 앱에 넣은 공개키와 짝인지 먼저 확인한다.
# 짝이 아닌 키로 서명하면 이미 설치된 앱들이 업데이트를 거부한다.
EXPECTED_KEY="$(sed -n 's/^SPARKLE_PUBLIC_KEY="\(.*\)"$/\1/p' scripts/build-app.sh)"
ACTUAL_KEY="$("$SPARKLE_BIN/generate_keys" --account "$SPARKLE_ACCOUNT" -p 2>/dev/null | tail -1 || true)"
if [[ -z "$EXPECTED_KEY" || "$EXPECTED_KEY" != "$ACTUAL_KEY" ]]; then
  echo "error: Sparkle 서명 키가 맞지 않습니다 (키체인 계정 '$SPARKLE_ACCOUNT')." >&2
  echo "  앱의 공개키   : ${EXPECTED_KEY:-없음}" >&2
  echo "  키체인 공개키 : ${ACTUAL_KEY:-없음}" >&2
  echo "  백업해 둔 키가 있으면: $SPARKLE_BIN/generate_keys --account $SPARKLE_ACCOUNT -f <파일>" >&2
  exit 1
fi

echo "==> 빌드 · 서명 ($SIGN_IDENTITY)"
export BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
VERSION="$VERSION" UNIVERSAL=1 SIGN_IDENTITY="$SIGN_IDENTITY" scripts/build-app.sh
APP="build/Damagochi.app"
codesign --verify --deep --strict "$APP"

echo "==> DMG 생성"
DMG="dist/Damagochi-$VERSION.dmg"
ZIP="dist/Damagochi-$VERSION.zip"
STAGE="$(mktemp -d)"
ditto "$APP" "$STAGE/Damagochi.app"
ln -s /Applications "$STAGE/Applications"          # 끌어다 놓기 설치용
mkdir -p dist
rm -f "$DMG" "$ZIP" dist/appcast.xml
hdiutil create -volname "Damagochi" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
rm -rf "$STAGE"

if [[ "$SKIP_NOTARIZE" == "1" ]]; then
  echo "==> 공증 건너뜀. $DMG 는 로컬 점검용입니다 (다른 Mac 에서는 Gatekeeper 가 막습니다)."
  exit 0
fi

echo "==> 공증 (Apple 서버에 업로드, 보통 1~5분)"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"

echo "==> 자동 업데이트용 ZIP · appcast"
# DMG 공증으로 안에 든 앱도 함께 승인되므로, 앱에도 티켓을 붙여 오프라인에서도 열리게 한다
xcrun stapler staple "$APP" || echo "warning: 앱 스테이플 실패 (온라인 확인으로 동작하므로 배포에는 지장 없음)"
ditto -c -k --keepParent "$APP" "$ZIP"
SIGNATURE="$("$SPARKLE_BIN/sign_update" --account "$SPARKLE_ACCOUNT" "$ZIP")"     # sparkle:edSignature="…" length="…"
[[ "$SIGNATURE" == *edSignature* ]] || { echo "error: 업데이트 서명 실패" >&2; exit 1; }
cat > dist/appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Damagochi</title>
    <item>
      <title>$VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <link>$REPO_URL/releases/tag/v$VERSION</link>
      <sparkle:version>$BUILD_NUMBER</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
      <enclosure url="$REPO_URL/releases/download/v$VERSION/Damagochi-$VERSION.zip" $SIGNATURE type="application/octet-stream"/>
    </item>
  </channel>
</rss>
XML

cat <<DONE

완료: $DMG, $ZIP, dist/appcast.xml (build $BUILD_NUMBER)
GitHub 릴리스 올리기 (세 파일을 모두 올려야 자동 업데이트가 동작합니다):
  git tag v$VERSION && git push origin v$VERSION
  gh release create v$VERSION "$DMG" "$ZIP" dist/appcast.xml --title "Damagochi $VERSION" --generate-notes
DONE

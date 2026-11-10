#!/bin/bash
# 배포용 DMG 를 만든다: 유니버설 빌드 → Developer ID 서명 → DMG → 공증 → 스테이플.
#
#   scripts/release.sh 0.1.0                   전체 과정
#   scripts/release.sh 0.1.0 --skip-notarize   서명·DMG 까지만 (로컬 점검용, 배포 금지)
#
# 환경 변수:
#   SIGN_IDENTITY    서명 인증서 (기본: 키체인의 첫 "Developer ID Application")
#   NOTARY_PROFILE   notarytool 키체인 프로필 이름 (기본: damagochi-notary)
#                    최초 1회 등록: xcrun notarytool store-credentials damagochi-notary \
#                                     --apple-id <Apple ID> --team-id <팀 ID> --password <앱 암호>
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?버전을 지정하세요. 예: scripts/release.sh 0.1.0}"
SKIP_NOTARIZE=0
[[ "${2:-}" == "--skip-notarize" ]] && SKIP_NOTARIZE=1

SIGN_IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning \
  | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)}"
if [[ -z "$SIGN_IDENTITY" ]]; then
  echo "error: 키체인에서 'Developer ID Application' 인증서를 찾지 못했습니다." >&2
  exit 1
fi
NOTARY_PROFILE="${NOTARY_PROFILE:-damagochi-notary}"

echo "==> 빌드 · 서명 ($SIGN_IDENTITY)"
VERSION="$VERSION" UNIVERSAL=1 SIGN_IDENTITY="$SIGN_IDENTITY" scripts/build-app.sh
codesign --verify --deep --strict build/Damagochi.app

echo "==> DMG 생성"
DMG="dist/Damagochi-$VERSION.dmg"
STAGE="$(mktemp -d)"
ditto build/Damagochi.app "$STAGE/Damagochi.app"
ln -s /Applications "$STAGE/Applications"          # 끌어다 놓기 설치용
mkdir -p dist
rm -f "$DMG"
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

cat <<DONE

완료: $DMG
GitHub 릴리스 올리기:
  git tag v$VERSION && git push origin v$VERSION
  gh release create v$VERSION "$DMG" --title "Damagochi $VERSION" --generate-notes
DONE

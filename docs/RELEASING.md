# 배포 가이드 (관리자용)

서명·공증된 앱을 GitHub 릴리스에 올리는 절차입니다. 새로 설치하는 사람은 DMG를 내려받고, 이미 설치한 사람은 앱이 자동으로 새 버전을 알려 줍니다.

## 한 번만 하는 준비

### 1. Developer ID 인증서

키체인에 `Developer ID Application` 인증서가 있어야 합니다.

```bash
security find-identity -v -p codesigning | grep "Developer ID Application"
```

### 2. 공증용 자격 증명

[account.apple.com](https://account.apple.com) → 로그인 및 보안 → **앱 암호**에서 암호를 하나 만든 뒤, 키체인에 프로필로 저장합니다.

```bash
xcrun notarytool store-credentials damagochi-notary \
  --apple-id "<Apple ID 이메일>" \
  --team-id "<팀 ID>" \
  --password "<앱 암호>"
```

이미 다른 이름으로 저장해 둔 프로필이 있으면 새로 만들 필요 없이 실행할 때 `NOTARY_PROFILE=<이름>`으로 지정합니다.

### 3. 자동 업데이트 서명 키 (Sparkle)

업데이트 파일은 EdDSA 키로 서명하고, 설치된 앱은 그 서명을 확인한 뒤에만 업데이트합니다. 개인키는 이 Mac의 키체인(계정 `damagochi`)에 있고, 짝이 되는 공개키는 `scripts/build-app.sh`의 `SPARKLE_PUBLIC_KEY`에 들어 있습니다.

**개인키를 잃어버리면 이미 설치된 앱들에 업데이트를 보낼 수 없습니다.** 반드시 백업해 두세요.

```bash
# 백업 (파일을 안전한 곳에 보관하고, 저장소에는 절대 올리지 않습니다)
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account damagochi -x damagochi-sparkle-key.txt

# 다른 Mac 에서 복원
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account damagochi -f damagochi-sparkle-key.txt
```

`.build/artifacts`가 없으면 `swift package resolve`를 먼저 실행합니다.

## 릴리스 만들기

```bash
scripts/release.sh 0.2.0
```

이 스크립트가 차례로 수행하는 일:

1. 업데이트 서명 키가 앱의 공개키와 짝인지 확인 (아니면 중단)
2. Apple Silicon + Intel 유니버설 바이너리 빌드
3. Developer ID로 서명 (Sparkle 내부 실행 파일부터 안쪽 → 바깥 순서, hardened runtime)
4. `Applications` 바로가기가 들어 있는 DMG 생성 후 서명
5. Apple 공증 서버에 제출하고 완료까지 대기 (보통 1~5분), DMG와 앱에 스테이플
6. 자동 업데이트용 ZIP을 만들어 EdDSA로 서명하고 `appcast.xml` 생성

결과물은 `dist/` 아래 세 파일입니다.

| 파일 | 용도 |
|---|---|
| `Damagochi-<버전>.dmg` | 새로 설치하는 사람이 내려받는 파일 |
| `Damagochi-<버전>.zip` | 설치된 앱이 자동 업데이트로 받는 파일 |
| `appcast.xml` | 새 버전 정보. 앱은 `releases/latest/download/appcast.xml`을 읽습니다 |

공증 없이 서명과 DMG 생성까지만 점검하려면 `--skip-notarize`를 붙입니다. 이렇게 만든 파일은 배포하면 안 됩니다.

## GitHub에 올리기

**세 파일을 모두 올려야 자동 업데이트가 동작합니다.**

```bash
git tag v0.2.0
git push origin v0.2.0
gh release create v0.2.0 dist/Damagochi-0.2.0.dmg dist/Damagochi-0.2.0.zip dist/appcast.xml \
  --title "Damagochi 0.2.0" --generate-notes
```

릴리스가 "latest"로 표시되면 설치된 앱들이 다음 확인 때(하루 한 번, 또는 메뉴의 **업데이트 확인**) 새 버전을 알게 됩니다. 사전 릴리스(pre-release)나 초안(draft)은 `latest`가 아니므로 사용자에게 나가지 않습니다.

## 올리기 전 점검

- [ ] `.build/release/Damagochi --simulate` 가 `SIMULATION OK`
- [ ] `build/Damagochi.app/Contents/MacOS/Damagochi --dump` 에 세션·사용량이 나옴
- [ ] DMG를 열어 응용 프로그램 폴더에 설치한 뒤 실행해 봄
- [ ] `spctl --assess --type open --context context:primary-signature -v dist/Damagochi-<버전>.dmg` 결과가 `accepted`
- [ ] `dist/appcast.xml`의 `sparkle:version`이 이전 릴리스보다 큼 (빌드 시각이라 보통 자동으로 커짐)

## 업데이트가 사용자에게 가지 않을 때

- **appcast.xml을 안 올림**: 릴리스 자산에 `appcast.xml`이 있는지 확인합니다.
- **빌드 번호가 커지지 않음**: 앱은 `CFBundleVersion`(빌드 시각)으로 새 버전인지 판단합니다. `BUILD_NUMBER`를 직접 지정했다면 이전보다 큰 값이어야 합니다.
- **서명 키 불일치**: 다른 Mac에서 배포했다면 위의 복원 절차로 같은 키를 가져와야 합니다.
- **0.1.0 사용자**: 0.1.0에는 자동 업데이트 기능이 없어서 한 번은 직접 새 버전을 받아야 합니다.

## 공증이 실패할 때

제출 결과에 나오는 ID로 상세 로그를 확인합니다.

```bash
xcrun notarytool log <제출 ID> --keychain-profile <프로필 이름>
```

흔한 원인:

- **hardened runtime 누락**: `scripts/build-app.sh`가 `SIGN_IDENTITY` 없이 실행되면 임시 서명만 합니다. 반드시 `scripts/release.sh`로 빌드하세요.
- **자격 증명 오류**: 앱 암호가 만료됐거나 팀 ID가 다릅니다. `store-credentials`를 다시 실행합니다.
- **약관 미동의**: Apple Developer 사이트에 새 약관 동의 요청이 있으면 제출이 거부됩니다.

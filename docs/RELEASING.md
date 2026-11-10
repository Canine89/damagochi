# 배포 가이드 (관리자용)

서명·공증된 DMG를 만들어 GitHub 릴리스에 올리는 절차입니다. 사용자는 이 파일을 내려받아 바로 실행할 수 있습니다.

## 한 번만 하는 준비

### 1. Developer ID 인증서

키체인에 `Developer ID Application` 인증서가 있어야 합니다.

```bash
security find-identity -v -p codesigning | grep "Developer ID Application"
```

### 2. 공증용 자격 증명 등록

[account.apple.com](https://account.apple.com) → 로그인 및 보안 → **앱 암호**에서 암호를 하나 만든 뒤, 키체인에 프로필로 저장합니다. 프로필 이름은 `damagochi-notary`로 맞춥니다.

```bash
xcrun notarytool store-credentials damagochi-notary \
  --apple-id "<Apple ID 이메일>" \
  --team-id "<팀 ID>" \
  --password "<앱 암호>"
```

팀 ID는 위 `find-identity` 출력에서 인증서 이름 끝의 괄호 안 값입니다. 다른 프로필 이름을 쓰려면 실행할 때 `NOTARY_PROFILE=<이름>`을 지정합니다.

## 릴리스 만들기

```bash
scripts/release.sh 0.1.0
```

이 스크립트가 차례로 수행하는 일:

1. Apple Silicon + Intel 유니버설 바이너리 빌드
2. Developer ID로 서명 (hardened runtime, 보안 타임스탬프)
3. `Applications` 바로가기가 들어 있는 DMG 생성 후 서명
4. Apple 공증 서버에 제출하고 완료까지 대기 (보통 1~5분)
5. 공증 티켓을 DMG에 스테이플하고 Gatekeeper 통과 여부 확인

결과물은 `dist/Damagochi-0.1.0.dmg`입니다.

공증 없이 서명과 DMG 생성까지만 점검하려면 `--skip-notarize`를 붙입니다. 이렇게 만든 파일은 배포하면 안 됩니다.

```bash
scripts/release.sh 0.1.0 --skip-notarize
```

## GitHub에 올리기

```bash
git tag v0.1.0
git push origin v0.1.0
gh release create v0.1.0 dist/Damagochi-0.1.0.dmg \
  --title "Damagochi 0.1.0" --generate-notes
```

README의 설치 안내는 `releases/latest`를 가리키므로, 릴리스를 올리면 따로 고칠 것이 없습니다.

## 올리기 전 점검

- [ ] `.build/release/Damagochi --simulate` 가 `SIMULATION OK`
- [ ] `build/Damagochi.app/Contents/MacOS/Damagochi --dump` 에 세션·사용량이 나옴
- [ ] DMG를 열어 응용 프로그램 폴더에 설치한 뒤 실행해 봄
- [ ] `spctl --assess --type open --context context:primary-signature -v dist/Damagochi-<버전>.dmg` 결과가 `accepted`

## 공증이 실패할 때

제출 결과에 나오는 ID로 상세 로그를 확인합니다.

```bash
xcrun notarytool log <제출 ID> --keychain-profile damagochi-notary
```

흔한 원인:

- **hardened runtime 누락**: `scripts/build-app.sh`가 `SIGN_IDENTITY` 없이 실행되면 임시 서명만 합니다. 반드시 `scripts/release.sh`로 빌드하세요.
- **자격 증명 오류**: 앱 암호가 만료됐거나 팀 ID가 다릅니다. `store-credentials`를 다시 실행합니다.
- **약관 미동의**: Apple Developer 사이트에 새 약관 동의 요청이 있으면 제출이 거부됩니다.

## 버전 올릴 때

버전은 `scripts/release.sh`에 넘기는 인자로 정해집니다. 빌드 번호는 빌드 시각으로 자동 생성되므로 따로 관리하지 않습니다.

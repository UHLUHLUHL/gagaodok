# 가가오독

수학 학습용 AI 채팅 앱입니다. 카카오톡 UI를 그대로 옮겨서, 프로필별로 다른
말투의 상대와 대화하듯 문제를 풀 수 있습니다. 맥 앱과 안드로이드 앱을 같은
저장소에서 함께 관리합니다.

## 다운로드

| | 파일 | 요구 사항 |
|---|---|---|
| 🖥️ Mac | [KakaoSapiens.zip](https://github.com/UHLUHLUHL/gagaodok/releases/latest/download/KakaoSapiens.zip) | macOS 14(Sonoma)+, 인텔·애플실리콘 모두 |
| 📱 Android | [gagaodok.apk](https://github.com/UHLUHLUHL/gagaodok/releases/latest/download/gagaodok.apk) | Android 8.0+ |

설치·초기 설정은 [설치방법.txt](설치방법.txt)를 보십시오. 둘 다 API 키(Gemini)를
직접 발급받아 등록해야 동작합니다 — 앱에 내장된 키는 없습니다.

## 구조

| | 맥 (Swift) | 안드로이드 (Kotlin) |
|---|---|---|
| 위치 | `Sources/KakaoSapiens/` | `android/` |
| 빌드 | `swift build` 또는 `./build_app.sh` | `./gradlew assembleDebug` |
| 실행 | `./run.sh` | Android Studio 또는 `./gradlew installDebug` |

두 플랫폼이 같은 기능을 유지해야 하는 구조입니다. 어디에 무엇이 있는지는
[ARCHITECTURE.md](ARCHITECTURE.md)를, 왜 지금 구조로 나눴는지는
[REFACTOR.md](REFACTOR.md)를 보십시오.

## 같이 볼 문서

- [ARCHITECTURE.md](ARCHITECTURE.md) — 하고 싶은 일별로 열어야 할 파일 찾기
- [REFACTOR.md](REFACTOR.md) — 서비스 파일을 왜, 어떻게 나눴는지
- [TOKEN_COST.md](TOKEN_COST.md) — 대화가 길어질수록 요금이 왜 오르는지, 고칠 곳
- [MAC_BACKPORT.md](MAC_BACKPORT.md) — 안드로이드에서 먼저 고친 것 중 맥에 옮긴 기록
- [android/MEASURED.md](android/MEASURED.md) — 원조 카카오톡 캡처에서 화소로 잰 치수

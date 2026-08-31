# 인수인계 — 원격 방 적용 (사전지식 없는 작업자용)

## 이 문서를 읽는 사람에게

이 문서는 **이 프로젝트를 전혀 모르는 작업자**가 남은 작업을 끝까지 수행할 수
있도록 쓴 것이다. 이전 대화를 볼 수 없다고 가정한다. 필요한 배경, 읽어야 할
문서, 지켜야 할 규칙, 이미 검증된 것과 아직 아닌 것, 그리고 넘어지기 쉬운 자리를
모두 적었다.

- 작성일: 2026-08-31
- 작성: Claude Code
- 직전 커밋: `26183c8` (복구 회전 + 실기기 양방향 shadow 복사)
- 다음 작업: **원격 방 적용** — 설계는
  [2026-08-31-remote-room-apply-design.md](2026-08-31-remote-room-apply-design.md)에
  있고 이 문서는 그 설계를 실행하기 위한 배경과 절차다.

---

## 0. 가장 먼저 할 일

1. `git status --short --branch`로 현재 상태를 확인한다.
2. 이 저장소의 규칙 파일을 읽는다. **읽지 않고 시작하지 않는다.**
   - `CLAUDE.md` (repo 루트) — Claude Code용 프로젝트 규칙
   - `AGENTS.md` (repo 루트) — Codex용 프로젝트 규칙
   - 사용자의 전역 규칙 파일이 있다면 그것도 함께 적용된다. 두 파일은 서로를
     대체하지 않고 **함께** 적용된다.
3. 설계 문서 [2026-08-31-remote-room-apply-design.md](2026-08-31-remote-room-apply-design.md)를
   읽는다. 무엇을 만들지, 무엇을 만들지 **않을지**가 거기 있다.
4. 직전 커밋 메시지를 읽는다. 왜 지금 구조가 이런지가 적혀 있다.

```bash
git log -1 --format=%B 26183c8
```

---

## 1. 이 프로젝트가 무엇인가

**가가오독**은 카카오톡 모양의 AI 대화 앱이다. 세 곳에서 돌아간다.

| 플랫폼 | 경로 | 비고 |
| --- | --- | --- |
| macOS (Swift/SwiftUI) | `Sources/KakaoSapiens/` | 멘토 모드 기준 |
| Android 폰 | `android/` (`phone` variant) | 챗봇 모드 기준 |
| Android 태블릿 | `android/` (`tabletMentor` variant) | 멘토 모드 |
| Cloudflare Worker + D1 + R2 | `cloudflare/sync-worker/` | 동기화 서버 |

지금 진행 중인 일은 **기기 간 동기화**다. 대화는 기기에서 E2EE로 암호화되고
서버는 평문을 볼 수 없다. 서버가 보는 평문은 동기화에 필요한 식별자·순번·시각뿐이다.

### 중요한 구분 — 이걸 섞으면 안 된다

- **멘토 모드 vs 챗봇 모드**
- **폰 vs 태블릿**
- **로컬 저장 메시지 / API로 보내는 context / 압축 요약 / Obsidian 내보내기 /
  동기화 payload** — 다섯 개는 서로 다른 데이터 흐름이다. 하나를 고치면서 다른
  것을 건드리면 안 된다.

---

## 2. 읽어야 할 문서 (순서대로)

### 필수

| 문서 | 왜 필요한가 |
| --- | --- |
| `CLAUDE.md`, `AGENTS.md` | 작업 규칙·권한·검증 요구 |
| `docs/2026-08-31-remote-room-apply-design.md` | **다음 작업의 설계** |
| `docs/CROSS_DEVICE_SYNC_USER_DECISIONS.md` | 확정된 17개 제품 결정. 특히 3·5·6·7·8·9·14·15 |
| `docs/PHASE1_CANONICAL_SCHEMA_DRAFT.md` | 대화 scope, entity identity, 공간 경계 |
| `docs/PHASE1_WORKER_API_DRAFT.md` | operation·error·인증 계약 |

### 필요할 때 해당 절만

| 문서 | 언제 |
| --- | --- |
| `docs/CROSS_DEVICE_SYNC_AGREEMENT.md` | 단계별 gate와 안전 조건을 확인할 때 |
| `docs/PHASE2_SYNTHETIC_SYNC_TEST_PLAN.md` | 이미 닫힌 Phase 2 gate 목록 |
| `docs/2026-08-31-real-sync-activation-handoff.md` | 이번 작업 직전의 상태 |
| `docs/2026-08-27-sync-encryption-proposal.md` | E2EE 키 유도·AAD 계약 |
| `docs/SYNC_IMPLEMENTATION_SURFACE_MAP.md` | 어떤 파일이 무엇을 담당하는지 |
| `docs/PHASE1_INTEGRATION_ACCEPTANCE_MATRIX.md` | 수용 기준 대조 |

**문서를 처음부터 끝까지 읽지 말 것.** 규칙상 아키텍처·비용·동기화 설계 문서는
인용된 절만 연다. 저장소 전체를 훑지 않는다.

### 새 문서를 쓸 때

모든 마크다운 문서는 `docs/` 아래에 둔다. 루트에 남는 예외는 `AGENTS.md`,
`CLAUDE.md`, `README.md` 뿐이다. `reference/` 아래 외부 자료는 재정리하지 않는다.

---

## 3. 지금까지 무엇이 되어 있는가

### 3.1 동기화의 현재 상태

```
Mac ──(암호화 operation)──▶ Worker/D1/R2 ──(change feed)──▶ 폰·태블릿
폰  ──(암호화 operation)──▶ Worker/D1/R2 ──(change feed)──▶ Mac·태블릿
```

**양방향 전송과 복호화는 실기기에서 검증됐다.** 아직 안 된 것은 **받은 것을
화면에 보이게 하는 것**이다. 지금은 개수와 hash만 확인하고 버린다.

### 3.2 실기기 검증 결과 (2026-08-31)

| 방향 | 방 | 결과 |
| --- | --- | --- |
| Mac → 폰·태블릿 | "테스트2" (`90B3EE60-2244-4838-9C1E-10A27295F6EB`, 말풍선 7, turn 3) | 두 기기 모두 7/7 복호화, hash 일치 |
| 폰 → Mac | "역방향테스트" (`4A285016-86DB-4CF5-A970-9D07C6D7C2D2`, 말풍선 32, turn 18) | 32/32 복호화, hash `3a97538628446318…` 일치 |

계정은 `AA009023-9B15-4261-BC05-F905E0BC5EF6`이고 활성 기기 5개, 복구 문구
버전 2다. 첨부는 아직 복사하지 않으며 미복사 개수만 보고한다.

### 3.3 관련 코드 위치

**Worker** (`cloudflare/sync-worker/`)

| 파일 | 역할 |
| --- | --- |
| `src/index.ts` | 라우팅 |
| `src/routes/changes.ts` | `GET /v1/sync/changes` — 받는 쪽이 쓰는 feed |
| `src/routes/bootstrap.ts` | `GET /v1/sync/bootstrap` |
| `src/routes/operations.ts`, `src/handlers/operationRequest.ts` | 쓰기 |
| `src/sync/projection.ts` | **wire 모양을 결정한다. 반드시 읽을 것** |
| `src/contracts/operation.ts` | operation·entity 계약 |
| `src/auth/deviceToken.ts` | 인증과 **공간 쓰기 경계** |

**macOS** (`Sources/KakaoSapiens/Services/`)

| 파일 | 역할 |
| --- | --- |
| `SyncE2EE.swift` | 키 유도, AAD, seal/open |
| `SyncShadowImporter.swift` | 로컬 대화 → 암호화 operation |
| `SyncShadowUploadCoordinator.swift` | 올리고 원격과 대조 |
| `SyncShadowReader.swift` | **다른 기기 방 읽기 — 적용 단계의 출발점** |
| `SyncPullCoordinator.swift`, `SyncReplicaStore.swift` | pull과 불투명 replica |
| `SyncSecretStore.swift` | Keychain의 master key·device token |
| `SyncConnectionState.swift` | **실제 account/device id가 여기 있다** |

**Android** (`android/app/src/main/java/com/sapiens/gagaodok/`)

| 파일 | 역할 |
| --- | --- |
| `sync/SyncE2EE.kt` | Swift와 대칭 |
| `sync/SyncShadowVerifier.kt` | **받은 것 복호화 — 적용 단계의 출발점** |
| `sync/SyncShadowWriter.kt`, `sync/SyncShadowWriteModel.kt` | 자기 공간 쓰기 |
| `sync/SyncPullCoordinator.kt`, `sync/SyncReplicaStore.kt` | pull과 replica |
| `data/ChatStore.kt` | **사용자 대화 저장소 — 적용 코드가 건드리면 안 된다** |
| `ui/screens/SyncSettingsSection.kt` | 동기화 설정 화면 |

---

## 4. 반드시 지켜야 할 규칙

### 4.1 승인 없이 하지 않는 것

- 설치, deploy, 원격 migration, 실제 데이터 업로드·조회
- app-data 삭제, 의존성 추가
- **commit, push, merge, branch·worktree 생성**
- Cloudflare deploy, `--remote` 명령, APK 설치, GitHub Release 발행

읽기·설명·검토·진단은 자유롭게 한다. 수정 요청은 범위 안의 로컬 편집과
비파괴적 확인까지를 승인한 것으로 본다.

### 4.2 남의 작업을 건드리지 않는다

현재 작업트리에 다음이 남아 있다. **전부 사용자나 다른 작업자의 것이다.**
수정·stage·삭제하지 않는다.

```
 M package_for_sharing.sh
 M tools/costsim.py
?? KakaoSapiens-backup-20260814-110708/
?? docs/2026-08-27-deferred-followups-memo.md
?? docs/CODEX_WORK_LOG.md
?? docs/installation/dist-설치방법.txt
?? exec-34b9ed07-11b9-454b-89d3-c768f9a79aa9.png
?? tools/__pycache__/, tools/tests/__pycache__/
```

### 4.3 실제 사용자 데이터

기본적으로 본문 전체를 열거나 출력하지 않는다. 개수·크기·ID·최소 샘플부터 본다.
대화 내용 분석이 명시적으로 요청됐고 내용을 보지 않고는 불가능할 때만, **필요한
turn·field만** 골라 읽는다. 그 경우에도 사용자에게 보여주는 출력에 본문 전체를
싣지 않는다.

로컬 대화 파일 위치:
- macOS: `~/Library/Application Support/KakaoSapiens/rooms_list.json`,
  `room_<UUID>_messages.json`
- Android: 앱 내부 저장소 (release 빌드라 adb로 읽을 수 없다)

### 4.4 보고

- **실제로 실행한 검사만 보고한다.**
- **빌드 성공은 동작 확인이 아니다.** 컴파일·빌드·설치·화면 확인은 서로 다른
  상태이며 구분해서 보고한다.
- UI 흐름을 실제로 실행할 수 없으면 "검증했다"고 쓰지 않는다. 미검증이라고 적고
  무엇을 더 확인해야 하는지 남긴다.
- 비용·시간·성능 수치를 지어내지 않는다.

---

## 5. 검증 방법

### 5.1 Worker

```bash
cd cloudflare/sync-worker && npm test -- --run
```

```bash
cd cloudflare/sync-worker && npm run typecheck
```

전부 local workerd/Miniflare에서 돈다. **원격 binding에 대고 돌리지 않는다.**
현재 기준값: **41 files / 901 tests 통과.**

### 5.2 macOS Swift

```bash
sh tools/test_swift_sync_coordinators.sh
```

```bash
swift build
```

`Package.swift`에 test target이 없어서 각 suite를 `@main` 실행 파일로 컴파일한다.
**새 Swift 시험을 추가하면 이 스크립트에 컴파일 블록도 함께 추가해야 한다.**
안 하면 시험이 존재만 하고 영영 돌지 않는다.

### 5.3 Android

Gradle이 쓰는 JVM을 먼저 확인한다. **JDK 17**이어야 한다.

```bash
cd android && ./gradlew --version
```

```bash
cd android && ./gradlew testPhoneDebugUnitTest testTabletMentorDebugUnitTest
```

```bash
cd android && ./gradlew compilePhoneDebugKotlin compileTabletMentorDebugKotlin
```

현재 기준값: **phone 337 / tabletMentor 337 통과, failures 0.**
variant는 `phone`과 `tabletMentor` 둘뿐이다. macOS 빌드는 건너뛴다.

`./gradlew test...`가 "BUILD SUCCESSFUL"만 찍고 시험이 안 돌 수 있다. 실제 개수는
XML에서 확인한다.

```bash
cd android && python3 -c "import xml.etree.ElementTree as ET,glob;print(sum(int(ET.parse(p).getroot().get('tests')) for p in glob.glob('app/build/test-results/testPhoneDebugUnitTest/*.xml')))"
```

### 5.4 마무리

```bash
git diff --check
```

그 뒤 diff를 좁게 검토한다.

---

## 6. 실기기 작업 (G4 이후, 승인 필요)

### 6.1 adb

`adb`가 PATH에 없다. 절대 경로를 쓴다.

```bash
~/Library/Android/sdk/platform-tools/adb devices -l
```

기기 이름에 공백이 있어 `-s`가 동작하지 않는다. **`-t <transport_id>`를 쓴다.**
transport_id는 `devices -l` 출력에 있고 재연결하면 바뀐다.

기기: 폰 `SM-S938N` (`com.sapiens.gagaodok`), 태블릿 `SM-X910`
(`com.sapiens.gagaodok.tabletmentor`). 둘 다 무선 연결이다.

### 6.2 설치 (승인 필요)

APK를 만들고 **기존 설치본과 서명이 같은지 먼저 확인한다.**

```bash
cd android && ./gradlew assemblePhoneRelease assembleTabletMentorRelease
```

```bash
~/Library/Android/sdk/build-tools/35.0.0/apksigner verify --print-certs android/app/build/outputs/apk/phone/release/app-phone-release.apk
```

기준 서명: `5cf3ebed1bd3ec740602649460856769723b42356cff7eb69ad2d2e10292a7b4`

데이터 보존 설치는 `install -r`이다. **uninstall·clear·downgrade 금지.**

```bash
~/Library/Android/sdk/platform-tools/adb -t 17828 install -r android/app/build/outputs/apk/phone/release/app-phone-release.apk
```

설치 뒤 `firstInstallTime`이 보존됐는지 확인한다(보존되면 업데이트, 바뀌면
새 설치라 데이터가 날아간 것이다).

```bash
~/Library/Android/sdk/platform-tools/adb -t 17828 shell dumpsys package com.sapiens.gagaodok | grep -E 'firstInstallTime|lastUpdateTime'
```

### 6.3 macOS 설치 (승인 필요)

```bash
./build_app.sh
```

이 스크립트는 `/Applications/가가오독.app`을 **교체한다.** 번들만 교체하므로
Keychain과 `~/Library/Application Support`의 앱 데이터는 보존된다. 설치 뒤:

```bash
codesign --verify --deep --strict "/Applications/가가오독.app"
```

### 6.4 Cloudflare (승인 필요)

합성 전용 환경만 쓴다. **production 자원을 만들지 않는다.**

- 설정 파일: `cloudflare/sync-worker/wrangler.synthetic.jsonc` (git 추적 안 됨)
- `wrangler.jsonc`는 **local 안전 장치**다. 원격을 가리키도록 고치지 않는다.
- 현재 배포 version: `ea3cb84d-ab85-4ec6-9f68-a36a4d637298`
- 엔드포인트: `https://gagaodok-sync-synthetic.gagaodok-sync-worker.workers.dev`

읽기 전용 원격 조회조차 `--remote`라서 승인이 필요하다.

```bash
cd cloudflare/sync-worker && npx wrangler d1 execute gagaodok-sync-synthetic --remote --config wrangler.synthetic.jsonc --command "SELECT ..." --json
```

---

## 7. 넘어지기 쉬운 자리 — 실제로 넘어진 것들

직전 작업에서 결함 셋이 나왔다. **셋 다 화면상 정상으로 보였다.** 같은 종류를
계속 의심해야 한다.

### 7.1 합성 환경 파일의 account_id는 합류 전 것이다

기기가 페어링으로 다른 계정에 합류하면 **실제 계정은 connection state에
기록된다.** `sync-synthetic.json`에는 합류 전 자기 계정이 그대로 남는다.

scope key는 account에서 유도되므로 틀린 쪽을 읽으면 아무도 못 여는 키가 되는데,
**신원·순서·내용 hash는 전부 정상으로 보인다.** 복구 문구에서는 더 나쁘다 —
account가 복구 AAD에 들어가므로 정작 복구가 필요한 순간에 master key가 안 열린다.

**항상 connection state를 우선하고 환경 파일은 fallback으로만 쓴다.**

- macOS: `SyncConnectionStateStore` → `configuration.accountID` (대문자 ID)
- Android: `SyncConnectionStateStore` → `configuration.accountId` (소문자 d)

### 7.2 wire 필드 이름은 D1 컬럼 이름이 아니다

`src/sync/projection.ts`의 `wireFieldName()`이 **`_enc` 접미사를 뗀다.**

| D1 컬럼 | wire 필드 |
| --- | --- |
| `text_enc` | `text` |
| `sender_enc` | `sender` |
| `kind_enc` | `kind` |

컬럼 이름으로 찾으면 아무것도 없고, 그것은 **"봉인된 것이 없는 행"과 구분되지
않는다.** 이 결함으로 실기기에서 복호화가 0/7이 나왔다.

### 7.3 worldline은 wire에서 이름이 다르다

`worldline_key`는 **저장 키**이고 wire identity에는 nullable **`worldline_id`**로
나간다. null worldline은 저장 키에서 `""`, wire에서 `null`이다.

저장 키 이름을 읽으면 null이 나오는데, 지금 행들에 worldline이 없어서 **우연히
맞았을 뿐**이다. 실제 worldline이 있는 행에서는 엉뚱한 키를 유도해 조용히 깨진다.

### 7.4 room 행은 worldline scope로 봉인하면 안 된다

room의 identity에는 worldline 성분이 없다. 그래서 **읽는 쪽은 방 제목을 항상
null-worldline scope로 유도한다.** 단톡방이라고 제목을 worldline scope로 봉인하면
아무도 열 수 없는 제목이 된다.

- 방 제목: null-worldline scope
- 말풍선·turn: 그 대화의 worldline scope

### 7.5 fixture를 손으로 만들면 시험이 거짓말을 한다

7.2와 7.3을 교차 언어 시험이 놓쳤다. **fixture를 손으로 만들면서 잘못된 가정을
그대로 넣었기 때문이다.** 양쪽이 똑같이 틀린 채 사이좋게 통과했다.

지금 구조는 이렇다. **유지할 것.**

1. `SyncShadowWriterFixtureTest`(Kotlin)가 writer의 실제 출력을
   `android/app/src/test/resources/kotlin-shadow-operations.json`에 쓴다.
2. Worker 시험(`test/kotlin-shadow-contract.spec.ts`,
   `test/swift-shadow-contract.spec.ts`)이 그것을 재생하고, **실제 change feed의
   identity·projection 필드 이름과 ciphertext 값까지** 대조한다.
3. 반대편 언어의 시험이 그 fixture를 소비해 복호화한다.

새 wire 필드를 다루게 되면 **반드시 실제 feed와 대조하는 pin을 추가한다.**
직접 확인하는 방법: fixture를 일부러 틀린 이름으로 바꿔 시험이 **실패하는지**
확인한다. 실패하지 않으면 그 시험은 아무것도 지키지 않는 것이다.

### 7.6 개수 일치는 성공이 아니다

개수가 맞아도 순서가 뒤집혔거나 다른 방 행이 섞였을 수 있다. **내용 hash를 함께
본다.** hash는 말풍선의 신원과 순서로만 계산하므로 본문을 드러내지 않는다.

**복호화 성공과 hash 일치는 서로 다른 사실이다.** 따로 보고한다. 실제로 hash는
맞고 복호화만 0인 상황이 두 번 있었고, 그 조합이 원인을 찾는 결정적 단서였다.

### 7.7 진단을 남겨라

`SyncShadowVerifier`와 `SyncShadowReader`는 첫 실패 이유를 비밀 아닌 말로 보고한다
(`acct=… space=… fail=open` 형태). 밖에서 보면 똑같은 "0 opened"인 실패들이
이걸로 구분된다. **적용 단계에도 같은 진단을 넣을 것.**

---

## 8. 다음 작업 — 무엇을 만드는가

설계 전문은 [2026-08-31-remote-room-apply-design.md](2026-08-31-remote-room-apply-design.md)에
있다. 요지만 옮긴다.

### 8.1 핵심 안전 규칙

> **적용 대상은 이 기기가 소유하지 않은 공간의 방뿐이다.**

대화는 공간이 소유하고(`conversation_scope = (space_id, room_id, worldline_id?)`),
다른 공간에 대신 쓰는 delegated writer는 v1에 없다. 따라서 원격 방의 로컬 파일은
애초에 존재하지 않으며 **기존 대화에 병합할 일이 없다.** 병합 알고리즘이 없으면
병합 버그도 없다.

자기 공간 행은 읽고 대조만 하고 **절대 적용하지 않는다.**

### 8.2 저장 위치

원격 방은 `sync/remote/` 아래 **별도 저장소**에 둔다. 기존 `ChatStore`의 파일,
검색 색인, 저장 스케줄러를 건드리지 않는다. 원격 적용 코드에 사용자 대화 파일로
가는 **경로 자체를 두지 않는다.**

화면에서만 두 목록을 합쳐 보여준다(결정 7번이 출처 표시를 요구한다).

### 8.3 노출 규칙

| 원격 방의 공간 | Mac | 폰 | 태블릿 |
| --- | --- | --- | --- |
| `PHONE_SPACE` | **숨김** (결정 3) | 자기 것 | **숨김** (결정 3) |
| `MAC_SPACE` | 자기 것 | 보임 | **숨김** (결정 5) |
| `TABLET_SPACE` | 보임 | 보임 | 자기 것 |

**따라서 표시까지 확인할 수 있는 조합은 Mac 방 → 폰 하나뿐이다.**
폰 방 "역방향테스트"는 복호화가 확인됐지만 **Mac 화면에 보이면 안 된다.**
백업은 되고 표시는 안 되는 것이 결정 3이다.

### 8.4 읽기 전용

결정 15번이 첫 테스트에서 수정·삭제를 막고, §8.1에 따라 이어 쓰기도 v1에 없다.
원격 저장소에 **쓰기 API를 두지 않는다.** 입력창을 숨기는 것은 UI 결정이고,
쓰기 API가 없는 것은 구조적 사실이다.

### 8.5 절차

1. pull (기존 `SyncPullCoordinator`, 변경 없음)
2. 선별 — 소유하지 않은 공간 + 노출 규칙 통과
3. 복호화 — 행이 적힌 공간으로 scope key 유도
4. 조립 — `bubble_order` 정렬 후 **원자적 교체**(임시 파일 + rename)
5. 대조 — 개수와 hash를 쓴 기기 값과 비교, 불일치는 화면에 남긴다

**전부 열리지 않으면 방을 적용하지 않는다.** 부분 적용된 방은 사용자에게 잘린
대화로 보이고 그것은 데이터 손실처럼 읽힌다.

### 8.6 gate

- [ ] **G1** 조립기와 원격 저장소 — 합성 fixture로 선별·복호화·조립·원자적 교체
- [ ] **G2** 소유 공간 불변식 — 자기 공간 행이 적용되지 않음을 시험으로 고정
- [ ] **G3** 노출 규칙 — §8.3 표의 아홉 칸을 각각 시험으로 고정
- [ ] **G4** 실기기 적용 — Mac 방 "테스트2"를 폰에 **(승인 필요)**
- [ ] **G5** 화면 표시 — 출처 표시, 읽기 전용, 결정 8번의 1회 안내
- [ ] **G6** 범위 확대 — 방 하나가 성공한 뒤에만

**G1~G3은 합성 자료뿐이고 실기기·실데이터가 없어 승인 없이 진행할 수 있다.**
G4부터 사용자 승인이 필요하다.

### 8.7 이 작업이 승인하지 않는 것

- 다른 공간의 방에 이어 쓰기 (delegated writer 계약 없음)
- 폰 방을 Mac·태블릿에 표시 / Mac 방을 태블릿에 표시
- 원격 방의 수정·삭제
- 첨부 복사 (미복사 개수만 보고)
- 자동 동기화 — 모든 적용은 버튼 뒤에 둔다
- OS 알림 (결정 14)

---

## 9. 그 밖에 열려 있는 것

이번 작업 범위는 아니지만 기록해 둔다.

- **첨부 복사 경로가 없다.** `create_attachment` + R2 업로드 + `complete`가
  계약에는 있지만 importer/writer에 없다. 지금은 미복사 개수만 보고한다.
- **중복 기기 등록.** 계정 `AA009023`에 폰 2건·태블릿 2건이 있다. 이전 합성
  시험의 잔여물이며 실제 데이터는 아니다. "이 기기 연결 해제"가 원격 revoke까지
  지원하면 정리 대상이다.
- **복구 회전 확인 상태가 저장되지 않는다.** 앱을 다시 켜면 회전 카드가 발급 전
  상태로 보인다. 화면만 봐서는 회전이 됐는지 알 수 없다.
- **24시간 초과 orphan R2 삭제**는 원격 근거가 없다. 현재 근거는 local 시험뿐이다.
- `docs/2026-08-27-deferred-followups-memo.md`에 더 미뤄 둔 항목들이 있다.
  (untracked 파일이므로 건드리지 말 것.)

---

## 10. 작업 습관

- 원인을 짚기 전에 고치지 않는다. 가장 그럴듯한 원인부터 검증한다.
- **같은 가설이나 같은 해결책이 두 번 실패하면 반복을 멈춘다.** 새 증거로 가설을
  바꾼다. 이번 작업에서 실제로 두 번 빗나간 뒤 진단을 넣어서야 원인을 찾았다.
- 증상이 사라진 것은 원인을 고친 것이 아니다. 왜 그랬는지 설명하지 못하면 아직
  안 고친 것이다.
- 저장소 전체 덤프, 긴 로그, lockfile, 생성물을 출력하지 않는다.
- 커밋 메시지가 인수인계 문서다. 요약 한 줄 + 빈 줄 + 상세 본문을 쓰고, **다음
  작업자가 이 대화를 전혀 못 본다고 가정하고** 무엇을 왜 바꿨는지, 남은 것이
  무엇인지 적는다. 커밋만 하고 push는 하지 않는다.

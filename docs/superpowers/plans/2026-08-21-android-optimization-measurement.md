# Android 최적화 측정 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Android phone COMPANION 모드의 비용·캐시·프롬프트 구성 데이터를 사용자가 정한 측정 회차별로 개인정보 없이 집계하고 설정에서 관리·내보낸다.

**Architecture:** `OptimizationMeasurementStore`가 활성 회차와 완료 회차를 앱 내부 JSON으로 보존하고, 순수 reducer가 요청·캐시 관측값을 집계한다. 기존 AI 요청 경로는 프롬프트를 변경하지 않고 관측값만 전달하며, 내보내기는 저장된 회차와 측정 구간의 메시지 간격을 익명 v2 JSON으로 변환한다.

**Tech Stack:** Kotlin, kotlinx.serialization, Jetpack Compose, Android MediaStore, JUnit 4, Gradle phone flavor

**Spec:** `docs/superpowers/specs/2026-08-21-android-optimization-measurement-design.md`

## Global Constraints

- Android `phone` 변형의 `COMPANION` 모드만 계측한다.
- 멘토, tabletMentor, macOS, Obsidian, 필기 흐름은 변경하지 않는다.
- 대화 원문, 첨부 내용·파일명, 방·캐릭터 이름, UUID, API 키, 절대 시각, 프롬프트 원문은 내보내지 않는다.
- 추가 API 호출, 백그라운드 타이머, 모델 요청 본문 변경을 만들지 않는다.
- 기존 토큰 장부와 내보내기 v1 코드가 있는 설치 데이터는 그대로 읽는다.
- 측정 회차는 사용자가 명시적으로 삭제하기 전까지 보존한다.

---

### Task 1: 회차 상태와 집계 reducer

**Files:**
- Create: `android/app/src/main/java/com/sapiens/gagaodok/data/OptimizationMeasurementStore.kt`
- Create: `android/app/src/test/java/com/sapiens/gagaodok/OptimizationMeasurementTest.kt`
- Modify: `android/app/src/main/java/com/sapiens/gagaodok/GagaodokApp.kt`

**Interfaces:**
- Produces: `OptimizationMeasurementStore.start(policy)`, `stop()`, `clear()`, `observeRequest(observation)`, `observeCache(observation)`, `state: StateFlow<MeasurementLedger>`
- Produces: serializable `MeasurementPolicy`, `RequestObservation`, `CacheObservation`, `CacheDecision`, `TokenBucket`, `MeasurementRun`

- [ ] **Step 1: Write failing reducer and persistence compatibility tests**

Test start→stop→restart preservation, inactive no-op, token buckets at 4095/4096/4599/4600/8192/16384, cache-decision counters, and decoding `{}` as an empty schema-v1 ledger.

- [ ] **Step 2: Run the focused test and verify unresolved measurement symbols**

Run:

```bash
cd android
JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home \
ANDROID_HOME=/Users/dlgksdnf/Library/Android/sdk \
./gradlew :app:testPhoneDebugUnitTest --tests com.sapiens.gagaodok.OptimizationMeasurementTest
```

Expected: FAIL because `OptimizationMeasurementStore` and measurement models do not exist.

- [ ] **Step 3: Implement minimal serializable ledger and file-backed store**

Use an injected `File` and clock for JVM tests and `get(context)` for production. Mutations are synchronized, update `StateFlow`, and persist on the IO scope. `start` returns the existing active run instead of creating a duplicate; `stop` moves it to completed runs.

- [ ] **Step 4: Run the focused test and verify PASS**

- [ ] **Step 5: Register one store instance in `GagaodokApp`**

Add `lateinit var optimizationMeasurement` initialized after `usage`.

### Task 2: COMPANION 요청·캐시 관측 연결

**Files:**
- Modify: `android/app/src/main/java/com/sapiens/gagaodok/service/AIServiceConversation.kt`
- Modify: `android/app/src/main/java/com/sapiens/gagaodok/service/AIServicePrefixCache.kt`
- Modify: `android/app/src/main/java/com/sapiens/gagaodok/service/AIService.kt`
- Test: `android/app/src/test/java/com/sapiens/gagaodok/OptimizationMeasurementTest.kt`

**Interfaces:**
- Consumes: Task 1 observation methods
- Produces: `PromptTokenBreakdown` containing stable system, persona, digest, verbatim, repetition-guidance, and attachment estimates

- [ ] **Step 1: Add failing tests for policy snapshot and decision mapping**

Assert current constants 4,600/900/300/2,000 are copied into a run and every cache branch maps to a stable enum.

- [ ] **Step 2: Run focused tests and verify FAIL**

- [ ] **Step 3: Add observation calls without changing request JSON**

At COMPANION request completion, mirror server usage numbers into the active run. In `refreshPrefixCache`, record `BELOW_MINIMUM`, `NOT_BURST`, `CACHE_CURRENT`, `TAIL_TOO_SMALL`, `CREATE_ATTEMPT`, `CREATE_SUCCESS`, `HTTP_FAILURE`, or `LOCAL_FAILURE`. Record estimates only; never persist strings or response bodies.

- [ ] **Step 4: Compare request body tests before and after and run focused tests**

Run existing request-body and cache-policy unit tests plus `OptimizationMeasurementTest`; expected PASS with unchanged request JSON assertions.

### Task 3: 개인정보 없는 v2 분석 JSON

**Files:**
- Modify: `android/app/src/main/java/com/sapiens/gagaodok/service/UsagePatternExport.kt`
- Modify: `android/app/src/test/java/com/sapiens/gagaodok/UsagePatternExportTest.kt`

**Interfaces:**
- Consumes: `MeasurementLedger`, rooms, messages, usage ledger
- Produces: `buildOptimizationExport(...): String` with `schemaVersion = 2`, overall snapshot, active run if present, and completed runs

- [ ] **Step 1: Write failing v2 privacy and time-window tests**

Use secret message text, room title, UUID, API key-shaped text, and fixed epoch timestamps. Assert none appear in JSON; assert only messages inside each run window contribute to gap buckets; assert active export does not stop the run.

- [ ] **Step 2: Run `UsagePatternExportTest` and verify FAIL**

- [ ] **Step 3: Implement v2 DTO conversion**

Export runs as `run-1`, `run-2`; export duration only; anonymize rooms independently within each run; include policy, counters, histograms, token breakdowns, and current cumulative usage summary.

- [ ] **Step 4: Run both focused test classes and verify PASS**

### Task 4: 데이터 설정 영역 통합

**Files:**
- Modify: `android/app/src/main/java/com/sapiens/gagaodok/ui/screens/SettingsScreen.kt`

**Interfaces:**
- Consumes: measurement `state`, `start`, `stop`, `clear`, v2 exporter
- Produces: one phone `데이터` section with API summary, room details, measurement controls, export, and destructive confirmations

- [ ] **Step 1: Extract small composables inside `SettingsScreen.kt`**

Create `DataSettingsSection`, `MeasurementControls`, and confirmation dialogs while preserving the existing colors and typography.

- [ ] **Step 2: Move existing API and room usage UI into the data section**

Keep model, appearance, and API-key sections in their current order outside it. Keep tabletMentor behavior unchanged using `BuildConfig.TABLET_MENTOR`.

- [ ] **Step 3: Wire measurement controls and unified export**

Show start, stop, restart, active duration/request count, export during or after measurement, clear-measurement confirmation, and usage-reset confirmation with explicit copy that their data sets are independent.

- [ ] **Step 4: Compile phone debug and fix only affected UI errors**

Run `:app:compilePhoneDebugKotlin`; expected PASS.

### Task 5: Full verification and device flow

**Files:**
- Verify: `android/app/build/outputs/apk/phone/release/app-phone-release.apk`

- [ ] **Step 1: Run formatting/static check and all phone unit tests**

Run `git diff --check` and `:app:testPhoneDebugUnitTest`; expected PASS.

- [ ] **Step 2: Build phone release once**

Run `:app:assemblePhoneRelease`; expected signed release APK.

- [ ] **Step 3: Compare installed and new APK certificate SHA-256**

Pull the installed base APK and compare `apksigner verify --print-certs`. Stop before installation if they differ.

- [ ] **Step 4: Preserve-data install and real flow test**

When signatures match, run `adb install -r`, then verify start → one real COMPANION request → intermediate export → stop → restart → export. Confirm the first export does not stop measurement and previous runs remain.

- [ ] **Step 5: Pull JSON and run privacy/schema checks**

Use `jq` to list keys and totals, confirm no absolute timestamps or identifiers, and report that measured optimization conclusions require 2~3 days of normal use.

- [ ] **Step 6: Commit and push the completed branch without merging main**

Stage only in-scope files, commit in Korean-facing documentation-compatible state, and push `codex/persona-repetition-control`.

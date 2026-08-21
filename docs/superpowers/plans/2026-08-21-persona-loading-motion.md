# Persona Loading Motion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 승인된 Figma의 대화 신호 로딩 모션을 Android phone COMPANION 말투 조사와 최초 규칙 생성 흐름에 구현한다.

**Architecture:** 처리 문구를 UI에서 직접 추측하지 않도록 `busy`와 기존 progress 문자열을 순수 프레젠테이션 모델로 변환한다. Compose 컴포넌트는 이 모델만 받아 앱 토큰으로 카드와 1.2초 벡터 모션을 그리며, 화면은 phone COMPANION일 때만 새 컴포넌트를 선택한다.

**Tech Stack:** Kotlin, Jetpack Compose, Compose Animation, Compose Canvas, JUnit 4, Gradle 8.9/JDK 17

**Spec:** `docs/superpowers/specs/2026-08-21-persona-loading-motion-design.md`

## Global Constraints

- Android `phone` 변형의 `COMPANION`에만 적용한다.
- 멘토, `tabletMentor`, macOS, Obsidian 흐름을 변경하지 않는다.
- 외부 애니메이션/아이콘 의존성을 추가하지 않는다.
- Figma의 76×36 신호, 72dp 카드, 1.2초 네 상태와 앱 라이트/다크 토큰을 유지한다.
- 단위 테스트는 구현 전에 실패를 확인하고, 최종 phone 관련 테스트와 release 빌드는 JDK 17에서 수행한다.

---

### Task 1: 로딩 프레젠테이션 모델

**Files:**
- Create: `android/app/src/main/java/com/sapiens/gagaodok/ui/components/PersonaLoadingPresentation.kt`
- Create: `android/app/src/test/java/com/sapiens/gagaodok/PersonaLoadingPresentationTest.kt`

**Interfaces:**
- Consumes: `busy: String`, `progress: String?`
- Produces: `personaLoadingPresentation(busy: String, progress: String?): PersonaLoadingPresentation?`

- [x] **Step 1: Write the failing test**

```kotlin
@Test fun `조사는 도착한 절에 맞는 실제 단계를 보여준다`() {
    assertEquals(PersonaLoadingStage.SOURCE, personaLoadingPresentation("lookup", null)?.stage)
    assertEquals(PersonaLoadingStage.COLLECT, personaLoadingPresentation("lookup", "대사를 모으고 있습니다… 12줄")?.stage)
    assertEquals(PersonaLoadingStage.SYNTHESIZE, personaLoadingPresentation("lookup", "말투 규칙을 적고 있습니다…")?.stage)
}

@Test fun `최초 규칙 생성은 규칙 단계이고 다른 작업은 대상이 아니다`() {
    assertEquals(PersonaLoadingStage.SYNTHESIZE, personaLoadingPresentation("analyze", null)?.stage)
    assertNull(personaLoadingPresentation("refine", null))
}
```

- [x] **Step 2: Run test to verify it fails**

Run: `JAVA_HOME=<jdk17> ./gradlew :app:testPhoneDebugUnitTest --tests '*PersonaLoadingPresentationTest'`

Expected: FAIL because the presentation model does not exist.

- [x] **Step 3: Write minimal implementation**

```kotlin
internal enum class PersonaLoadingStage { SOURCE, VERIFY, COLLECT, SYNTHESIZE }

internal data class PersonaLoadingPresentation(
    val stage: PersonaLoadingStage,
    val title: String,
    val detail: String
)

internal fun personaLoadingPresentation(busy: String, progress: String?): PersonaLoadingPresentation? =
    when (busy) {
        "analyze" -> synthesizePresentation
        "lookup" -> lookupPresentation(progress)
        else -> null
    }
```

- [x] **Step 4: Run test to verify it passes**

Run the same focused test. Expected: PASS.

### Task 2: 대화 신호 Compose 컴포넌트

**Files:**
- Create: `android/app/src/main/java/com/sapiens/gagaodok/ui/components/PersonaLoadingSignal.kt`
- Modify: `android/app/src/main/java/com/sapiens/gagaodok/ui/components/PersonaLoadingPresentation.kt`

**Interfaces:**
- Consumes: `PersonaLoadingPresentation`
- Produces: `@Composable internal fun PersonaLoadingSignal(presentation: PersonaLoadingPresentation, modifier: Modifier = Modifier)`

- [x] **Step 1: Add a failing test for the four hand-checked motion moments**

```kotlin
assertEquals(PersonaSignalFrame(0f, 1f), personaSignalFrame(0f))
assertEquals(PersonaSignalFrame(28f, 1f), personaSignalFrame(.25f))
assertEquals(PersonaSignalFrame(56f, 1f), personaSignalFrame(.50f))
assertEquals(PersonaSignalFrame(28f, .35f), personaSignalFrame(.75f))
```

- [x] **Step 2: Run the focused test and observe the missing motion model failure**

- [x] **Step 3: Implement the visual component**

```kotlin
internal data class PersonaSignalFrame(val x: Float, val scale: Float)

internal fun personaSignalFrame(fraction: Float): PersonaSignalFrame = when {
    fraction < .25f -> PersonaSignalFrame(0f, 1f)
    fraction < .50f -> PersonaSignalFrame(28f, 1f)
    fraction < .75f -> PersonaSignalFrame(56f, 1f)
    else -> PersonaSignalFrame(28f, .35f)
}

@Composable
internal fun PersonaLoadingSignal(
    presentation: PersonaLoadingPresentation,
    modifier: Modifier = Modifier
) {
    val fraction by rememberInfiniteTransition(label = "persona-signal")
        .animateFloat(
            initialValue = 0f,
            targetValue = 1f,
            animationSpec = infiniteRepeatable(tween(1200, easing = LinearEasing)),
            label = "persona-signal-fraction"
        )
    val frame = personaSignalFrame(fraction)
    Row(
        modifier
            .fillMaxWidth()
            .height(72.dp)
            .background(KakaoTheme.colors.sunken, RoundedCornerShape(18.dp))
            .padding(16.dp)
            .semantics(mergeDescendants = true) { liveRegion = LiveRegionMode.Polite },
        verticalAlignment = Alignment.CenterVertically
    ) {
        PersonaSignalCanvas(frame, Modifier.size(76.dp, 36.dp))
        Column(Modifier.padding(start = 14.dp)) {
            Text(presentation.title, fontSize = 14.sp, fontWeight = FontWeight.Medium)
            Text(presentation.detail, style = KakaoText.caption)
        }
    }
}
```

- [x] **Step 4: Run the focused test and compile the phone debug Kotlin sources**

Run: `JAVA_HOME=<jdk17> ./gradlew :app:testPhoneDebugUnitTest --tests '*PersonaLoadingPresentationTest' :app:compilePhoneDebugKotlin`

Expected: PASS.

### Task 3: COMPANION phone 화면 연결

**Files:**
- Modify: `android/app/src/main/java/com/sapiens/gagaodok/ui/screens/PersonaEditorScreen.kt`
- Test: `android/app/src/test/java/com/sapiens/gagaodok/PersonaLoadingPresentationTest.kt`

**Interfaces:**
- Consumes: `BuildConfig.TABLET_MENTOR`, `ChatMode.COMPANION`, `busy`, `progress`
- Produces: `shouldUsePersonaLoadingSignal(isTabletMentor: Boolean, mode: ChatMode): Boolean`과 조건부 화면 연결

- [x] **Step 1: Add a failing eligibility test**

```kotlin
assertTrue(shouldUsePersonaLoadingSignal(isTabletMentor = false, mode = ChatMode.COMPANION))
assertFalse(shouldUsePersonaLoadingSignal(isTabletMentor = true, mode = ChatMode.COMPANION))
assertFalse(shouldUsePersonaLoadingSignal(isTabletMentor = false, mode = ChatMode.MATH_MENTOR))
```

- [x] **Step 2: Run the focused test and verify the missing function failure**

- [x] **Step 3: Implement minimal gating and replace only lookup/analyze feedback**

```kotlin
if (shouldUsePersonaLoadingSignal(BuildConfig.TABLET_MENTOR, mode)) {
    personaLoadingPresentation("lookup", progress)?.let { PersonaLoadingSignal(it) }
} else {
    BusyLine(progress ?: "자료를 찾고 있습니다…")
}
```

Keep `refine` and preview feedback unchanged.

- [x] **Step 4: Run the focused test and phone unit-test suite**

Run: `JAVA_HOME=<jdk17> ./gradlew :app:testPhoneDebugUnitTest`

Expected: PASS.

### Task 4: Build and visual verification

**Files:**
- Modify only if verification finds a defect in the files above.

**Interfaces:**
- Consumes: completed phone COMPANION implementation
- Produces: tested release APK and verification evidence

- [x] **Step 1: Build the phone release once**

Run: `JAVA_HOME=<jdk17> ./gradlew :app:assemblePhoneRelease`

Expected: BUILD SUCCESSFUL and a phone release APK.

- [x] **Step 2: Check connected devices**

Run: `$ANDROID_SDK_ROOT/platform-tools/adb devices`

If no device is listed, record that runtime animation verification could not be performed. Do not claim installation or real-device verification.

Verification note: 연결된 기기/에뮬레이터가 없어 설치, TalkBack, 애니메이션 배율 0× 실동작은 확인하지 못했다.

- [x] **Step 3: Compare source geometry with Figma**

Verify the card is 72dp high, signal canvas is 76×36dp, yellow comes from `editConfirm`, and the timing keyframes are 0/300/600/900–1200ms.

- [ ] **Step 4: Commit and push without merging main**

```bash
git add docs/superpowers android/app/src/main android/app/src/test
git commit -m "feat(android): add persona loading signal"
git push origin codex/persona-repetition-control
```

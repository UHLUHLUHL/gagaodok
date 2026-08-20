# 무한 필기 캔버스 구현 계획

> **에이전트 작업자용:** 이 계획은 작업별로 `superpowers:executing-plans`를 사용해 순서대로 구현한다. 각 단계는 체크박스로 추적하며, 기능 코드를 쓰기 전에 반드시 실패하는 테스트를 먼저 확인한다.

**목표:** 태블릿 멘토 모드의 필기를 무한 벡터 캔버스로 전환하고, 화면·지우개·PNG 출력이 같은 좌표와 굵기 규칙을 사용하게 하며, 첨부파일만 있는 메시지도 원래 지점에서 다시 보낼 수 있게 한다.

**구조:** 필기 문서는 버전이 있는 월드 좌표와 뷰포트를 저장한다. 좌표 변환·입력 분류·출력 범위 계산은 Android UI와 분리된 순수 Kotlin 모듈에서 담당하고, Compose 캔버스와 PNG 생성기는 같은 변환 및 고정 굵기 규칙을 사용한다. 메시지 재전송은 ViewModel의 단일 `resendFromMessage` 경로로 통합한다.

**기술 스택:** Kotlin, Jetpack Compose, Android `MotionEvent`, Android Canvas/Bitmap, kotlinx.serialization, JUnit 4, Gradle/JDK 17

**설계 문서:** `docs/superpowers/specs/2026-08-20-infinite-ink-canvas-design.md`

## 전역 제약

- 변경 대상은 Android `tabletMentor` 기능이며 휴대폰 전용 UX는 바꾸지 않는다.
- S Pen/스타일러스만 필기·지우기를 수행한다. 한 손가락은 이동, 두 손가락은 이동·확대/축소만 수행한다.
- 펜과 지우개 굵기는 필압과 무관한 고정 월드 단위이며 서로 독립적이다.
- 패널 크기 변경은 뷰포트에 보이는 영역만 바꾸고 기존 획의 크기·위치를 바꾸지 않는다.
- 저장 중에는 전체 캔버스 비트맵을 만들지 않는다. PNG는 첨부 시에만 만들며 긴 변은 최대 4096px이다.
- 기존 정규화 좌표 문서는 손실 없이 한 번 변환하고, 비정상 좌표나 뷰포트는 안전한 기본값으로 복구한다.
- Java/JVM은 17을 사용한다: `JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home`.
- 사용자에게 보여주는 설계·계획·결과 문서는 한국어로 작성한다.

---

### 작업 1: 월드 좌표 문서와 레거시 변환

**파일:**
- 수정: `android/app/src/main/java/com/sapiens/gagaodok/model/InkDocument.kt`
- 생성: `android/app/src/main/java/com/sapiens/gagaodok/service/InkCoordinateSpace.kt`
- 수정: `android/app/src/main/java/com/sapiens/gagaodok/data/InkStore.kt`
- 생성: `android/app/src/test/java/com/sapiens/gagaodok/InkCoordinateSpaceTest.kt`

**인터페이스:**
- 생성: `InkViewport(centerX: Float, centerY: Float, zoom: Float)`
- 생성: `InkDocument.coordinateSpaceVersion: Int`, `InkDocument.viewport: InkViewport`
- 생성: `InkCoordinateSpace.toCurrent(document: InkDocument): InkDocument`
- 생성: `InkCoordinateSpace.legacyPointToWorld(point: InkPoint): InkPoint`

- [ ] **1단계: 변환 실패 테스트 작성**

```kotlin
@Test fun `버전 없는 정규화 좌표를 기본 월드 캔버스로 한 번 변환한다`() {
    val old = document(version = 0, points = listOf(InkPoint(0.5f, 0.25f, 0.9f, 1L)))
    val migrated = InkCoordinateSpace.toCurrent(old)
    assertEquals(1, migrated.coordinateSpaceVersion)
    assertEquals(800f, migrated.strokes.single().points.single().x, 0.001f)
    assertEquals(300f, migrated.strokes.single().points.single().y, 0.001f)
}

@Test fun `비정상 뷰포트와 좌표는 유한한 기본값으로 복구한다`() {
    val broken = document(version = 1, viewport = InkViewport(Float.NaN, 0f, 0f))
    val repaired = InkCoordinateSpace.toCurrent(broken)
    assertTrue(repaired.viewport.zoom.isFinite())
    assertTrue(repaired.strokes.flatMap { it.points }.all { it.x.isFinite() && it.y.isFinite() })
}
```

- [ ] **2단계: 실패 확인**

실행: `JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home ./gradlew :app:testTabletMentorDebugUnitTest --tests '*InkCoordinateSpaceTest'`

기대 결과: `InkViewport`, `coordinateSpaceVersion`, `InkCoordinateSpace`가 없어 컴파일 실패한다.

- [ ] **3단계: 최소 모델과 변환 구현**

```kotlin
@Serializable data class InkViewport(val centerX: Float = 800f, val centerY: Float = 600f, val zoom: Float = 1f)

@Serializable data class InkDocument(
    // 기존 필드 유지
    val coordinateSpaceVersion: Int = 0,
    val viewport: InkViewport = InkViewport(),
    val strokes: List<InkStroke> = emptyList()
)

object InkCoordinateSpace {
    const val CURRENT_VERSION = 1
    const val LEGACY_WIDTH = 1600f
    const val LEGACY_HEIGHT = 1200f
    fun toCurrent(document: InkDocument): InkDocument {
        if (document.coordinateSpaceVersion >= CURRENT_VERSION) return document.sanitized()
        return document.copy(
            coordinateSpaceVersion = CURRENT_VERSION,
            viewport = InkViewport(),
            strokes = document.strokes.map { stroke ->
                stroke.copy(points = stroke.points.map(::legacyPointToWorld))
            }
        ).sanitized()
    }
}
```

`InkStore.load()`에서 디코딩 직후 `InkCoordinateSpace.toCurrent`를 적용하고, 실제 변환된 문서가 있으면 원자적 저장 경로로 갱신한다. 획 ID·순서·색·시각·지우개 상태는 유지한다.

- [ ] **4단계: 테스트 통과 확인**

실행: 위 테스트 명령. 기대 결과: 모든 `InkCoordinateSpaceTest` 통과.

- [ ] **5단계: 커밋**

```bash
git add android/app/src/main/java/com/sapiens/gagaodok/model/InkDocument.kt android/app/src/main/java/com/sapiens/gagaodok/service/InkCoordinateSpace.kt android/app/src/main/java/com/sapiens/gagaodok/data/InkStore.kt android/app/src/test/java/com/sapiens/gagaodok/InkCoordinateSpaceTest.kt
git commit -m "feat: migrate ink documents to world coordinates"
```

### 작업 2: 뷰포트 변환과 제스처 수학

**파일:**
- 생성: `android/app/src/main/java/com/sapiens/gagaodok/service/InkViewportTransform.kt`
- 생성: `android/app/src/test/java/com/sapiens/gagaodok/InkViewportTransformTest.kt`

**인터페이스:**
- 생성: `InkViewportTransform.worldToScreen(point, viewport, size): InkPoint2D`
- 생성: `InkViewportTransform.screenToWorld(point, viewport, size): InkPoint2D`
- 생성: `InkViewportTransform.pan(viewport, screenDx, screenDy): InkViewport`
- 생성: `InkViewportTransform.zoomAt(viewport, factor, focalScreen, size): InkViewport`
- 생성: `InkViewportTransform.hoverDiameter(worldWidth, zoom): Float`

- [ ] **1단계: 왕복·리사이즈·초점 보존 실패 테스트 작성**

```kotlin
@Test fun `월드와 화면 좌표는 왕복해 원래 점으로 돌아온다`() {
    val viewport = InkViewport(800f, 600f, 2f)
    val world = InkPoint2D(900f, 650f)
    val screen = InkViewportTransform.worldToScreen(world, viewport, InkPoint2D(1000f, 700f))
    assertEquals(world, InkViewportTransform.screenToWorld(screen, viewport, InkPoint2D(1000f, 700f)))
}
@Test fun `패널 크기가 바뀌어도 월드 점과 확대율은 변하지 않는다`() {
    val viewport = InkViewport(800f, 600f, 1.5f)
    val point = InkPoint2D(900f, 700f)
    InkViewportTransform.worldToScreen(point, viewport, InkPoint2D(600f, 400f))
    InkViewportTransform.worldToScreen(point, viewport, InkPoint2D(900f, 700f))
    assertEquals(InkViewport(800f, 600f, 1.5f), viewport)
}
@Test fun `두 손가락 확대의 초점 월드 좌표는 화면의 같은 위치에 남는다`() {
    val size = InkPoint2D(1000f, 700f)
    val focal = InkPoint2D(300f, 200f)
    val before = InkViewport(800f, 600f, 1f)
    val world = InkViewportTransform.screenToWorld(focal, before, size)
    val after = InkViewportTransform.zoomAt(before, 2f, focal, size)
    assertEquals(world, InkViewportTransform.screenToWorld(focal, after, size))
}
@Test fun `지우개 호버 지름은 월드 굵기 곱하기 확대율이다`() { assertEquals(36f, hoverDiameter(18f, 2f), 0.001f) }
```

- [ ] **2단계: 실패 확인**

실행: `... ./gradlew :app:testTabletMentorDebugUnitTest --tests '*InkViewportTransformTest'`

기대 결과: 변환 객체가 없어 실패한다.

- [ ] **3단계: 순수 변환 구현**

```kotlin
data class InkPoint2D(val x: Float, val y: Float)

object InkViewportTransform {
    const val MIN_ZOOM = 0.2f
    const val MAX_ZOOM = 8f
    fun screenToWorld(point: InkPoint2D, viewport: InkViewport, size: InkPoint2D): InkPoint2D
    fun worldToScreen(point: InkPoint2D, viewport: InkViewport, size: InkPoint2D): InkPoint2D
    fun pan(viewport: InkViewport, screenDx: Float, screenDy: Float): InkViewport
    fun zoomAt(viewport: InkViewport, factor: Float, focalScreen: InkPoint2D, size: InkPoint2D): InkViewport
}
```

화면 중심을 뷰포트 중심에 대응시키고, 이동량은 `zoom`으로 나눈 월드 거리로 환산한다. `zoomAt`은 확대 전 초점의 월드 좌표와 확대 후 초점의 월드 좌표 차이만큼 중심을 보정한다.

- [ ] **4단계: 테스트 통과 확인 및 커밋**

```bash
JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home ./gradlew :app:testTabletMentorDebugUnitTest --tests '*InkViewportTransformTest'
git add android/app/src/main/java/com/sapiens/gagaodok/service/InkViewportTransform.kt android/app/src/test/java/com/sapiens/gagaodok/InkViewportTransformTest.kt
git commit -m "feat: add infinite canvas viewport math"
```

### 작업 3: 스타일러스·손가락 입력 분리와 월드 스트로크

**파일:**
- 수정: `android/app/src/main/java/com/sapiens/gagaodok/service/InkInputMode.kt`
- 수정: `android/app/src/main/java/com/sapiens/gagaodok/service/InkStrokeMath.kt`
- 생성: `android/app/src/main/java/com/sapiens/gagaodok/service/InkGestureRouter.kt`
- 수정: `android/app/src/test/java/com/sapiens/gagaodok/InkInputModeTest.kt`
- 수정: `android/app/src/test/java/com/sapiens/gagaodok/InkStrokeMathTest.kt`
- 생성: `android/app/src/test/java/com/sapiens/gagaodok/InkGestureRouterTest.kt`

**인터페이스:**
- 생성: `InkGestureIntent` (`STROKE`, `PAN`, `PAN_ZOOM`, `HOVER`, `IGNORE`)
- 생성: `InkGestureRouter.classify(action, toolTypes, pointerCount, eraser): InkGestureIntent`
- 교체: `InkStrokeMath.worldPoint(screenX, screenY, viewport, surfaceSize, timeMillis): InkPoint`
- 변경: `InkStrokeMath.shouldKeep`은 월드 거리와 고정 최소 화면 간격을 사용하며 압력 변화만으로 점을 추가하지 않는다.

- [ ] **1단계: 입력 분류와 고정 굵기 실패 테스트 작성**

```kotlin
@Test fun `스타일러스만 스트로크로 분류한다`() {
    assertEquals(InkGestureIntent.STROKE, InkGestureRouter.classify(MotionEvent.ACTION_DOWN, intArrayOf(MotionEvent.TOOL_TYPE_STYLUS), 1))
    assertEquals(InkGestureIntent.PAN, InkGestureRouter.classify(MotionEvent.ACTION_DOWN, intArrayOf(MotionEvent.TOOL_TYPE_FINGER), 1))
    assertEquals(InkGestureIntent.IGNORE, InkGestureRouter.classify(MotionEvent.ACTION_DOWN, intArrayOf(MotionEvent.TOOL_TYPE_UNKNOWN), 1))
}
@Test fun `두 손가락은 이동 확대이고 획을 만들지 않는다`() {
    assertEquals(InkGestureIntent.PAN_ZOOM, InkGestureRouter.classify(MotionEvent.ACTION_MOVE, intArrayOf(MotionEvent.TOOL_TYPE_FINGER, MotionEvent.TOOL_TYPE_FINGER), 2))
}
@Test fun `호버는 접촉과 별도 상태로 분류한다`() {
    assertEquals(InkGestureIntent.HOVER, InkGestureRouter.classify(MotionEvent.ACTION_HOVER_MOVE, intArrayOf(MotionEvent.TOOL_TYPE_STYLUS), 1))
}
@Test fun `필압만 바뀐 같은 위치 표본은 추가하지 않는다`() {
    assertFalse(InkStrokeMath.shouldKeep(InkPoint(2f, 2f, .1f, 0), InkPoint(2f, 2f, 1f, 1)))
}
```

- [ ] **2단계: 실패 확인**

실행: `... ./gradlew :app:testTabletMentorDebugUnitTest --tests '*InkGestureRouterTest' --tests '*InkStrokeMathTest' --tests '*InkInputModeTest'`

- [ ] **3단계: 입력 분류와 월드 표본 구현**

`MotionEvent`의 도구 유형과 포인터 수를 먼저 분류한다. 스타일러스 스트로크 시작 시 `StrokeStyle`을 고정하고, 이후 이동 이벤트에서 압력은 저장 호환성만 위해 기록하되 렌더 굵기에는 사용하지 않는다. 손가락·팜 이벤트는 `InkStroke`를 만들 수 없는 별도 분기로 보낸다.

- [ ] **4단계: 테스트 통과 확인 및 커밋**

```bash
JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home ./gradlew :app:testTabletMentorDebugUnitTest --tests '*InkGestureRouterTest' --tests '*InkStrokeMathTest' --tests '*InkInputModeTest'
git add android/app/src/main/java/com/sapiens/gagaodok/service android/app/src/test/java/com/sapiens/gagaodok/InkGestureRouterTest.kt android/app/src/test/java/com/sapiens/gagaodok/InkStrokeMathTest.kt android/app/src/test/java/com/sapiens/gagaodok/InkInputModeTest.kt
git commit -m "feat: route stylus and touch ink gestures"
```

### 작업 4: Compose 무한 캔버스와 지우개 호버

**파일:**
- 생성: `android/app/src/main/java/com/sapiens/gagaodok/ui/screens/InkCanvasState.kt`
- 수정: `android/app/src/main/java/com/sapiens/gagaodok/ui/screens/InkPanel.kt`
- 생성: `android/app/src/test/java/com/sapiens/gagaodok/InkCanvasStateTest.kt`

**인터페이스:**
- 생성: `InkCanvasState(document)`의 `onMotionEvent`, `undo`, `redo`, `clear`, `hover`, `viewport`
- 생성: `InkHoverCursor(worldX, worldY, worldDiameter)`
- `InkWritingSurface`는 `InkCanvasState`와 단일 `worldToScreen` 변환을 소비한다.

- [ ] **1단계: 상태 전이 실패 테스트 작성**

```kotlin
@Test fun `패널 리사이즈는 획과 뷰포트를 바꾸지 않는다`() {
    val state = InkCanvasState(documentWithOneStroke())
    val before = state.document
    state.onViewportSizeChanged(1200f, 800f)
    assertEquals(before, state.document)
}
@Test fun `취소 이벤트는 부분 획과 호버를 버린다`() {
    val state = InkCanvasState(emptyDocument())
    state.cancelInteraction()
    assertTrue(state.activePoints.isEmpty())
    assertNull(state.hover)
}
@Test fun `이동과 확대는 undo 기록에 들어가지 않는다`() {
    val state = InkCanvasState(emptyDocument())
    state.panBy(20f, 10f)
    state.zoomAt(2f, InkPoint2D(100f, 100f), InkPoint2D(600f, 400f))
    assertFalse(state.canUndo)
}
@Test fun `스트로크 도중 도구막대 변경은 현재 획 스타일을 바꾸지 않는다`() {
    val state = InkCanvasState(emptyDocument())
    state.beginStroke(InkInputMode.StrokeStyle(0xFF191919, 4.5f, false))
    state.updateToolbarStyle(InkInputMode.StrokeStyle(0xFF191919, 30f, true))
    assertEquals(4.5f, state.activeStyle.width)
    assertFalse(state.activeStyle.eraser)
}
```

- [ ] **2단계: 실패 확인**

실행: `... ./gradlew :app:testTabletMentorDebugUnitTest --tests '*InkCanvasStateTest'`

- [ ] **3단계: UI 상태와 렌더링 구현**

`InkSession`을 UI 파일의 비공개 정규화 좌표 세션에서 테스트 가능한 `InkCanvasState`로 이동한다. `pointerInteropFilter`에서 라우터 결과에 따라 스타일러스 획, 한 손가락 이동, 두 손가락 이동·확대를 처리한다. 렌더러는 모든 점을 월드에서 화면으로 변환하고, 굵기는 `baseWidth * zoom`만 사용한다. 지우개 호버는 접촉 전 중립색 원으로 그리며 접촉·종료·취소·도구 전환 시 즉시 지운다.

패널 크기 상태는 기존처럼 유지하되 크기 변경 시 문서 좌표나 뷰포트를 다시 계산하지 않는다. 뷰포트 변경 저장은 제스처 종료 시 한 번만 `onDocumentChanged`로 전달한다.

- [ ] **4단계: 테스트와 디버그 컴파일 확인 및 커밋**

```bash
JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home ./gradlew :app:testTabletMentorDebugUnitTest --tests '*InkCanvasStateTest' :app:compileTabletMentorDebugKotlin
git add android/app/src/main/java/com/sapiens/gagaodok/ui/screens/InkCanvasState.kt android/app/src/main/java/com/sapiens/gagaodok/ui/screens/InkPanel.kt android/app/src/test/java/com/sapiens/gagaodok/InkCanvasStateTest.kt
git commit -m "feat: render and navigate infinite ink canvas"
```

### 작업 5: 끊김 없는 탄성 굵기 슬라이더와 지우개 한 번 탭

**파일:**
- 생성: `android/app/src/main/java/com/sapiens/gagaodok/ui/screens/InkElasticSlider.kt`
- 수정: `android/app/src/main/java/com/sapiens/gagaodok/ui/screens/InkPanel.kt`
- 수정: `android/app/src/main/java/com/sapiens/gagaodok/ui/screens/InkToolbarControl.kt`
- 수정: `android/app/src/test/java/com/sapiens/gagaodok/InkToolbarControlTest.kt`

**인터페이스:**
- 생성: `elasticTrackPath(width, height, progress, stretch): Path`의 계산용 `ElasticTrackGeometry`
- 변경: `InkToolbarEvent.TAP_ERASER`는 지우개 선택과 `ERASER` 확장을 함께 유도한다.

- [ ] **1단계: 툴바 상태와 도형 실패 테스트 작성**

```kotlin
@Test fun `지우개를 한 번 누르면 지우개가 선택되고 굵기 조절이 열린다`() {
    assertEquals(InkToolbarControl.ERASER, InkToolbarControl.reduce(InkToolbarControl.NONE, InkToolbarEvent.OPEN_ERASER))
}
@Test fun `슬라이더 현재 위치의 두꺼운 부분은 트랙과 겹쳐 빈틈이 없다`() {
    val geometry = ElasticTrackGeometry.calculate(width = 200f, height = 38f, progress = .5f, stretch = 1f)
    assertTrue(geometry.blobLeft <= geometry.activeTrackRight)
    assertTrue(geometry.blobRight >= geometry.inactiveTrackLeft)
}
```

- [ ] **2단계: 실패 확인**

실행: `... ./gradlew :app:testTabletMentorDebugUnitTest --tests '*InkToolbarControlTest' --tests '*InkElasticSliderTest'`

- [ ] **3단계: 단일 Canvas 도형과 탄성 구현**

Material Slider의 트랙·thumb 색을 모두 투명하게 하고 접근성 및 드래그 입력만 사용한다. 하나의 Canvas Path가 비활성 트랙, 활성 트랙, 두꺼운 현재 위치와 베지어 어깨를 겹침 없이 그린다. 드래그 방향은 직전 값과 현재 값의 차이로 구하고, 이동 중 가로 늘어남·세로 눌림을 적용한 뒤 `spring(dampingRatio≈0.5, stiffness≈500)`으로 복귀시킨다. 노란 테두리·광택·반복 애니메이션은 사용하지 않는다.

지우개 버튼의 단일 탭은 `eraser=true`와 `OPEN_ERASER`를 동시에 실행한다. 길게 누르기 분기는 제거하며 전체 지우기는 확장 캡슐 내부의 삭제 아이콘으로만 유지한다.

- [ ] **4단계: 테스트와 컴파일 확인 및 커밋**

```bash
JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home ./gradlew :app:testTabletMentorDebugUnitTest --tests '*InkToolbarControlTest' --tests '*InkElasticSliderTest' :app:compileTabletMentorDebugKotlin
git add android/app/src/main/java/com/sapiens/gagaodok/ui/screens android/app/src/test/java/com/sapiens/gagaodok/InkToolbarControlTest.kt android/app/src/test/java/com/sapiens/gagaodok/InkElasticSliderTest.kt
git commit -m "feat: refine elastic ink width controls"
```

### 작업 6: 화면과 동일한 내용 경계 PNG 출력

**파일:**
- 생성: `android/app/src/main/java/com/sapiens/gagaodok/service/InkExportGeometry.kt`
- 수정: `android/app/src/main/java/com/sapiens/gagaodok/service/InkAttachmentFactory.kt`
- 생성: `android/app/src/test/java/com/sapiens/gagaodok/InkExportGeometryTest.kt`

**인터페이스:**
- 생성: `InkExportGeometry.candidateBounds(strokes): InkWorldRect?`
- 생성: `InkExportGeometry.outputSize(bounds, minShortEdge = 1600, maxLongEdge = 4096): InkPixelSize`
- 생성: `InkExportGeometry.transform(bounds, outputSize, margin): InkOutputTransform`
- 생성: `InkAttachmentFactory.create(document)`는 비어 있거나 완전히 지워진 문서에서 `null`을 반환한다.

- [ ] **1단계: 경계·굵기·빈 문서 실패 테스트 작성**

```kotlin
@Test fun `한 점 획 경계는 굵기의 절반만큼 확장된다`() {
    val bounds = InkExportGeometry.candidateBounds(listOf(stroke(width = 20f, point = InkPoint(50f, 40f, 1f, 0))))!!
    assertEquals(InkWorldRect(40f, 30f, 60f, 50f), bounds)
}
@Test fun `출력 긴 변은 4096을 넘지 않고 보통 필기는 짧은 변 1600을 확보한다`() {
    assertEquals(InkPixelSize(3200, 1600), InkExportGeometry.outputSize(InkWorldRect(0f, 0f, 200f, 100f)))
    assertTrue(InkExportGeometry.outputSize(InkWorldRect(0f, 0f, 10000f, 100f)).width <= 4096)
}
@Test fun `필압이 달라도 같은 baseWidth로 출력한다`() {
    assertEquals(20f, InkExportGeometry.outputStrokeWidth(baseWidth = 10f, outputScale = 2f, pressure = .1f))
    assertEquals(20f, InkExportGeometry.outputStrokeWidth(baseWidth = 10f, outputScale = 2f, pressure = 1f))
}
@Test fun `모든 내용이 지워지면 첨부를 만들지 않는다`() {
    assertNull(InkAttachmentFactory.create(completelyErasedDocument()))
}
```

- [ ] **2단계: 실패 확인**

실행: `... ./gradlew :app:testTabletMentorDebugUnitTest --tests '*InkExportGeometryTest'`

- [ ] **3단계: 공유 변환 기반 PNG 구현**

비지우개 획의 월드 경계를 굵기 반경만큼 확장해 후보 비트맵을 만들고, 획을 순서대로 그린다. 모든 선 굵기는 `baseWidth * outputScale`, 한 점 반경은 그 절반으로 통일한다. 지우개도 같은 경로·굵기로 흰색 합성한다. 렌더 후 픽셀을 검사해 실제 비백색 경계와 일정 흰 여백으로 자르며, 비어 있으면 비트맵을 폐기하고 `null`을 반환한다. 모든 중간 비트맵은 `finally`에서 재활용한다.

- [ ] **4단계: 테스트와 컴파일 확인 및 커밋**

```bash
JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home ./gradlew :app:testTabletMentorDebugUnitTest --tests '*InkExportGeometryTest' :app:compileTabletMentorDebugKotlin
git add android/app/src/main/java/com/sapiens/gagaodok/service/InkExportGeometry.kt android/app/src/main/java/com/sapiens/gagaodok/service/InkAttachmentFactory.kt android/app/src/test/java/com/sapiens/gagaodok/InkExportGeometryTest.kt
git commit -m "fix: match ink export to visible canvas"
```

### 작업 7: 첨부파일 전용 메시지 다시 보내기

**파일:**
- 생성: `android/app/src/main/java/com/sapiens/gagaodok/ui/screens/MessageResendLogic.kt`
- 수정: `android/app/src/main/java/com/sapiens/gagaodok/ui/screens/ChatRoomViewModel.kt`
- 수정: `android/app/src/main/java/com/sapiens/gagaodok/ui/screens/MessageActionSheet.kt`
- 수정: `android/app/src/main/java/com/sapiens/gagaodok/ui/screens/ChatRoomScreen.kt`
- 생성: `android/app/src/test/java/com/sapiens/gagaodok/MessageResendLogicTest.kt`

**인터페이스:**
- 생성: `MessageResendLogic.actionFor(message): MessageUserAction` (`EDIT`, `RESEND`, `NONE`)
- 생성: `MessageResendLogic.truncateFrom(messages, messageId, replacementText?): List<ChatMessage>`
- 생성: `ChatRoomViewModel.resendFromMessage(message, replacementText, room, model)`

- [ ] **1단계: 메뉴·대화 절단 실패 테스트 작성**

```kotlin
@Test fun `텍스트 없는 첨부 메시지는 수정 대신 다시 보내기다`() {
    assertEquals(MessageUserAction.RESEND, MessageResendLogic.actionFor(userMessage(text = "", attachment = imageAttachment())))
}
@Test fun `텍스트 메시지는 기존처럼 수정이다`() {
    assertEquals(MessageUserAction.EDIT, MessageResendLogic.actionFor(userMessage(text = "고쳐줘", attachment = null)))
}
@Test fun `다시 보내면 원본 첨부를 보존하고 그 뒤 대화를 제거한다`() {
    val target = userMessage(text = "", attachment = imageAttachment())
    val result = MessageResendLogic.truncateFrom(listOf(target, assistantMessage("답")), target.id, null)
    assertEquals(1, result.size)
    assertEquals(target.attachment, result.single().attachment)
}
@Test fun `존재하지 않는 메시지는 대화를 손상시키지 않는다`() {
    val original = listOf(userMessage(text = "질문", attachment = null))
    assertEquals(original, MessageResendLogic.truncateFrom(original, UUID.randomUUID(), null))
}
```

- [ ] **2단계: 실패 확인**

실행: `... ./gradlew :app:testTabletMentorDebugUnitTest --tests '*MessageResendLogicTest'`

- [ ] **3단계: 공통 재전송 경로 구현**

`messageMenuItems`에 `onResend` 콜백을 추가하고, 사용자 메시지가 `text.isBlank() && attachment != null`이면 `다시 보내기`, 텍스트가 있으면 `수정`을 표시한다. `ChatRoomViewModel.resend`와 `editAndResend`의 중복된 절단·응답 재시작을 `resendFromMessage`로 모으고, 첨부파일 전용 경로에서는 원본 첨부와 빈 텍스트를 그대로 사용한다. 해당 메시지 뒤의 대화만 삭제하고 그 지점부터 AI 응답을 다시 생성한다.

- [ ] **4단계: 테스트와 컴파일 확인 및 커밋**

```bash
JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home ./gradlew :app:testTabletMentorDebugUnitTest --tests '*MessageResendLogicTest' :app:compileTabletMentorDebugKotlin
git add android/app/src/main/java/com/sapiens/gagaodok/ui/screens android/app/src/test/java/com/sapiens/gagaodok/MessageResendLogicTest.kt
git commit -m "fix: resend attachment-only messages"
```

### 작업 8: 회귀 검증, APK 빌드, GitHub 푸시

**파일:**
- 검토: 위 작업의 모든 변경 파일
- 산출물: `android/app/build/outputs/apk/tabletMentor/release/app-tabletMentor-release.apk`

- [ ] **1단계: 전체 태블릿 단위 테스트**

```bash
JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home ./gradlew :app:testTabletMentorDebugUnitTest
```

기대 결과: 실패 0건.

- [ ] **2단계: 릴리스 APK 한 번 빌드**

```bash
JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home ./gradlew :app:assembleTabletMentorRelease
```

기대 결과: `BUILD SUCCESSFUL` 및 APK 생성.

- [ ] **3단계: 산출물·Git 상태 검증**

```bash
test -s android/app/build/outputs/apk/tabletMentor/release/app-tabletMentor-release.apk
shasum -a 256 android/app/build/outputs/apk/tabletMentor/release/app-tabletMentor-release.apk
git diff --check
git status --short
```

- [ ] **4단계: 가능하면 실기기 확인**

`adb devices`에 갤럭시탭이 있으면 설치 후 S Pen 필기, 측면 버튼 실시간 지우기, 지우개 호버, 한 손가락 이동, 두 손가락 확대/축소, 네 모서리 리사이즈, 전송 PNG 일치, 첨부파일 전용 다시 보내기를 확인한다. 기기가 없으면 이 항목만 명확한 미검증 위험으로 남긴다.

- [ ] **5단계: 최종 커밋과 푸시**

```bash
git add -A
git commit -m "feat: complete infinite tablet ink canvas"  # 남은 추적 변경이 있을 때만
git push origin codex/obsidian-mentor-export
```

PR 1의 동일 브랜치에 푸시하고, 강제 푸시나 `main` 병합은 하지 않는다.

# Android Group Worldline Heart Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 기존 개인 캐릭터로 조용히 시작하는 단톡방을 만들고, 분기 시점의 대화와 하트를 상속한 독립 세계선을 Figma와 Android phone 앱에 구현한다.

**Architecture:** 개인방의 `ChatRoom` 호환성은 기본값으로 보존하고 단톡방만 `GroupChatState`를 가진다. 단톡방 대화와 요약은 `(groupRoomId, worldlineId)` 저장 범위로 분리하며, 한 번의 Gemini 요청에서 화자·하트 표식을 파싱해 기존 나레이션 스트림을 유지한다. Compose UI는 Figma Page 1의 토큰과 `Heart gauge` 변형을 재사용하고 개인방 경로는 조건 분기로 그대로 둔다.

**Tech Stack:** Kotlin, kotlinx.serialization, Jetpack Compose Material 3, coroutines/StateFlow, JUnit 4, Gradle 8.9/JDK 17, Figma Plugin API/MCP.

**Spec:** `docs/superpowers/specs/2026-08-24-group-worldline-heart-design.md`

## Global Constraints

- Android `phone`의 `COMPANION`만 확장하고 `tabletMentor`, 멘토, macOS, Obsidian은 변경하지 않는다.
- 개인방의 기존 메시지 파일 이름, `turnId`, `canonicalText`, 나레이션 분리, 캐싱과 페르소나 동작을 보존한다.
- 단톡방은 기존 개인 캐릭터를 중복 없이 두 명 이상 선택하고 자동 인사 없이 생성한다.
- 세계선은 분기 시점의 대화, 요약, 참여자별 하트를 상속한 뒤 독립적으로 변한다.
- 모든 새 동작은 실패 테스트를 먼저 확인한 뒤 최소 구현으로 통과시킨다.
- 기존 미커밋 파일과 사용자 작업을 보존한다.
- Figma는 기존 파일 `UJZoCC2StSwwNSVVFSi1mx`의 기존 `Page 1`만 수정한다.
- 최종 phone 빌드는 `/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home`을 `JAVA_HOME`으로 사용한다.

---

### Task 1: 단톡방·세계선 도메인과 하위 호환성

**Files:**
- Create: `android/app/src/main/java/com/sapiens/gagaodok/model/GroupChatState.kt`
- Modify: `android/app/src/main/java/com/sapiens/gagaodok/model/ChatRoom.kt`
- Test: `android/app/src/test/java/com/sapiens/gagaodok/GroupChatStateTest.kt`

**Interfaces:**
- Consumes: 기존 `UuidSerializer`, `SwiftDateSerializer`, `ChatRoom`, `RoomProfile`.
- Produces: `GroupParticipantSeed`, `GroupParticipant`, `ParticipantHeart`, `WorldlineState`, `GroupChatState.create`, `branchActiveWorldline`, `adjustActiveHeart`, `switchWorldline`; `RoomProfile.baseAffection`; `ChatRoom.groupChat`.

- [x] **Step 1: 직렬화와 입력 정규화 실패 테스트 추가**

  `GroupChatStateTest`에 다음 동작을 리터럴 값으로 검증한다.
  - 생성 시 중복 참여자 ID는 한 번만 남는다.
  - 생성 시 기본 호감도는 `0..100`으로 제한된다.
  - JSON encode/decode 뒤 활성 세계선과 하트값이 동일하다.
  - `baseAffection`과 `groupChat` 필드가 없는 옛 `ChatRoom` JSON은 각각 `50`, `null`로 읽힌다.

- [x] **Step 2: 실패 확인**

  Run: `JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home ANDROID_HOME=/Users/dlgksdnf/Library/Android/sdk ./gradlew :app:testPhoneDebugUnitTest --tests com.sapiens.gagaodok.GroupChatStateTest`

  Expected: 중복 제거 또는 clamp/직렬화 기대가 실패한다.

- [x] **Step 3: 최소 구현**

  `GroupChatState.create`에서 `participants.distinctBy { it.roomId }`를 사용하고 하트는 `seed.baseAffection.coerceIn(0, 100)`으로 저장한다. 기존 필드 기본값은 바꾸지 않는다.

- [x] **Step 4: focused test 통과**

  Run: 위와 동일. Expected: PASS.

---

### Task 2: 세계선별 메시지·요약 저장과 조용한 단톡방 생성

**Files:**
- Create: `android/app/src/main/java/com/sapiens/gagaodok/data/ConversationScope.kt`
- Create: `android/app/src/main/java/com/sapiens/gagaodok/data/ConversationFiles.kt`
- Create: `android/app/src/main/java/com/sapiens/gagaodok/data/GroupChatRoomFactory.kt`
- Modify: `android/app/src/main/java/com/sapiens/gagaodok/data/ChatStore.kt`
- Test: `android/app/src/test/java/com/sapiens/gagaodok/ConversationScopeTest.kt`
- Test: `android/app/src/test/java/com/sapiens/gagaodok/ConversationFilesTest.kt`

**Interfaces:**
- Consumes: Task 1의 `GroupChatState`, `ChatRoom.groupChat`, 참여 개인방 `RoomProfile.baseAffection`.
- Produces: `ConversationScope(roomId, worldlineId)`, `messageFileName`, `digestFileName`, `aiConversationId`; 순수 파일 어댑터 `ConversationFiles(root)`; `createGroupChatRoom(title: String, participants: List<ChatRoom>, initialWorldlineId: UUID, createdAt: Long): ChatRoom`; `ChatStore.createGroupRoom`, `branchWorldline`, `switchWorldline`, `adjustWorldlineHeart`; worldline 인자를 받는 `loadMessages`/`saveMessages` overload.

- [x] **Step 1: 파일명과 AI 대화 ID 실패 테스트**

  개인 범위의 파일명은 기존 `room_<ROOM>_messages.json`을 그대로 반환하고, 단톡방은 `room_<ROOM>_worldline_<WORLDLINE>_messages.json`을 반환하도록 테스트한다. `aiConversationId`는 개인방에서 `roomId`, 단톡방에서 `worldlineId`여야 한다.

- [x] **Step 2: 저장 계약 실패 테스트**

  `java.nio.file.Files.createTempDirectory` 아래의 실제 파일을 쓰는 `ConversationFiles`로 다음을 검증한다.
  - 새 세계선의 메시지 파일을 초기화하면 정확히 `[]`만 쓴다.
  - `branch`는 활성 세계선 메시지와 digest를 새 파일로 복사한다.
  - 원본/분기 파일에 서로 다른 메시지를 저장해도 섞이지 않는다.
  - 단톡방 삭제는 명시된 세계선 파일만 삭제하고 개인방 파일은 보존한다.
  별도의 순수 factory 테스트로 `createGroupChatRoom`이 개인방만 받아 기본 세계선을 만들고 빈 대화 상태를 반환하는지 검증한다. 단톡방 `ChatRoom.profile`은 별도 상태이므로 참여 개인방 프로필 중 하나를 재사용하지 않는다.

- [x] **Step 3: 실패 확인**

  Run: `./gradlew :app:testPhoneDebugUnitTest --tests '*ConversationScopeTest' --tests '*ConversationFilesTest'`

  Expected: 새 API 미정의로 컴파일 실패.

- [x] **Step 4: 최소 저장 구현**

  개인 overload는 기존 파일 경로를 그대로 호출한다. 단톡방 overload만 활성 세계선 범위를 사용한다. `ChatStore`는 `ConversationFiles(dir)`에 파일 경로·초기화·복제를 위임한다. `pendingSaves`와 검색 인덱스 키를 `ConversationScope`로 바꾸되 개인방의 외부 동작은 동일하게 유지한다. 분기 시 `messages`, `digest` 파일을 각각 복사하고 새 세계선을 활성화한다.

- [x] **Step 5: focused tests 통과**

  Run: 위와 동일. Expected: PASS.

---

### Task 3: 한 요청 단톡방 응답, 화자 식별, 하트 변화

**Files:**
- Create: `android/app/src/main/java/com/sapiens/gagaodok/service/GroupConversationProtocol.kt`
- Modify: `android/app/src/main/java/com/sapiens/gagaodok/model/Message.kt`
- Modify: `android/app/src/main/java/com/sapiens/gagaodok/ui/screens/ChatRoomViewModel.kt`
- Test: `android/app/src/test/java/com/sapiens/gagaodok/GroupConversationProtocolTest.kt`
- Test: `android/app/src/test/java/com/sapiens/gagaodok/ConversationTurnTest.kt`

**Interfaces:**
- Consumes: 참여 개인방의 이름/페르소나, 활성 `WorldlineState`, 기존 `AIService.streamResponse`, `RoleplayParser`.
- Produces: `ChatMessage.speakerRoomId: UUID?`; `GroupConversationProtocol.personaFor(participants)`; `parseBubble(text, previousSpeakerId)`; `heartDeltas(rawText)`.

- [x] **Step 1: 프로토콜 실패 테스트**

  다음 리터럴 응답을 사용한다.

  ```text
  "[[speaker:11111111-1111-1111-1111-111111111111]] 안녕."

  *둘 사이에 잠깐 정적이 흐른다.*

  "[[speaker:22222222-2222-2222-2222-222222222222]][[heart:22222222-2222-2222-2222-222222222222:+2]] 왜 불렀어?"
  ```

  화자 표식과 하트 표식은 화면 텍스트에서 사라지고, 나레이션은 화자 `null`, 하트 변화는 두 번째 참여자 `+2`가 되어야 한다. 표식 없는 후속 대사는 직전 화자를 이어받고 허용되지 않은 UUID는 무시해야 한다.

- [x] **Step 2: 기존 대화 턴 회귀 실패 테스트**

  서로 다른 `speakerRoomId`를 가진 같은 `turnId`의 AI 말풍선들이 `canonicalText` 한 번으로 계속 합쳐지고, 개인방 메시지의 기본 화자는 `null`인지 검증한다.

- [x] **Step 3: 실패 확인**

  Run: `./gradlew :app:testPhoneDebugUnitTest --tests '*GroupConversationProtocolTest' --tests '*ConversationTurnTest'`

- [x] **Step 4: 최소 프로토콜과 ViewModel 분기 구현**

  개인방 `respond`는 기존 코드를 그대로 사용한다. 단톡방만 합성 페르소나를 만들고 활성 세계선 ID를 `AIService.roomId`로 넘긴다. 스트림 말풍선마다 표식을 제거해 `speakerRoomId`를 저장하고, 완료된 원문의 하트 변화는 `ChatStore.adjustWorldlineHeart`로 활성 세계선에만 반영한다. `canonicalText`에는 모델 원문을 한 번만 보존한다.

- [x] **Step 5: focused tests 통과**

  Run: 위와 동일. Expected: PASS.

---

### Task 4: Figma Page 1 화면과 프로토타입 완성

**Files:**
- Modify externally: Figma file `UJZoCC2StSwwNSVVFSi1mx`, Page `0:1` only.
- Record: `/tmp/design-system-state-gagaodok-20260824.json`

**Interfaces:**
- Consumes: 기존 `Gagaodok UI` 변수 30개, Noto Sans KR 텍스트 스타일 8개, `Heart gauge` component set `9:41`.
- Produces: `01 · Group creation`, `02 · Group chat`, `03 · Worldline switcher`, `04 · Branch confirmation` 프레임과 연결된 prototype 흐름.

- [x] **Step 1: 기존 Page 1 metadata와 screenshot 확인**

  `get_design_context`와 `get_screenshot`으로 기존 하트 컴포넌트와 추가할 화면 영역을 확인한다. Figma Starter 한도가 막으면 완료 표시하지 않고 Android 비시각 작업만 계속한다.

- [x] **Step 2: 단톡방 생성 화면 구성**

  기존 변수·텍스트 스타일을 바인딩하고 캐릭터 다중 선택, 선택 수, 비활성/활성 생성 버튼을 만든다. 개인방과 단톡방 선택 행을 섞지 않는다.

- [x] **Step 3: 단톡방·세계선 화면 구성**

  겹친 아바타 헤더, 화자별 말풍선, 가운데 나레이션, 접힌/펼친 Heart gauge instance, 세계선 pill과 분기 확인 패널을 만든다.

- [x] **Step 4: prototype 연결과 검증**

  하트 접기/펼치기 `300ms EASE_OUT`, 세계선 전환 `220ms EASE_OUT`을 연결한다. 화면별 screenshot과 metadata로 clipping, 겹침, 폰트, 변수 바인딩, 새 페이지 미생성을 확인한다.

---

### Task 5: Compose 단톡방 생성·채팅·세계선 UI와 모션

**Files:**
- Create: `android/app/src/main/java/com/sapiens/gagaodok/ui/screens/GroupChatCreationSheet.kt`
- Create: `android/app/src/main/java/com/sapiens/gagaodok/ui/screens/GroupChatPanels.kt`
- Modify: `android/app/src/main/java/com/sapiens/gagaodok/ui/screens/ChatsScreen.kt`
- Modify: `android/app/src/main/java/com/sapiens/gagaodok/ui/screens/ChatRoomScreen.kt`
- Modify: `android/app/src/main/java/com/sapiens/gagaodok/ui/screens/ChatRoomBubbles.kt`
- Test: `android/app/src/test/java/com/sapiens/gagaodok/GroupChatUiStateTest.kt`

**Interfaces:**
- Consumes: Tasks 2–4의 store API, `speakerRoomId`, Figma 수치와 토큰.
- Produces: 다중 선택 생성 흐름, group avatar/header, 화자별 bubble identity, `HeartGaugePanel`, `WorldlineSwitcher`, `BranchWorldlineSheet`.

- [x] **Step 1: 순수 UI 상태 실패 테스트**

  두 명 미만이면 생성 불가, 개인방만 후보, 선택 순서에 따른 기본 제목, 활성 세계선의 하트 평균, 접힘 상태와 세계선 전환 후 선택값을 검증한다.

- [x] **Step 2: 실패 확인**

  Run: `./gradlew :app:testPhoneDebugUnitTest --tests '*GroupChatUiStateTest'`

- [x] **Step 3: 생성 UI와 채팅 UI 최소 구현**

  `BuildConfig.TABLET_MENTOR`에서는 기존 작성 동작을 유지한다. phone에서는 작성 메뉴에 새 친구/새 단톡방을 제공한다. 단톡방 화면만 group header/panels를 보이고 개인방 컴포저블 경로는 유지한다.

- [x] **Step 4: Figma 모션 재현**

  `AnimatedContent`/`animateContentSize`에 `tween(300, easing = FastOutSlowInEasing)`을 사용해 Heart gauge를 morph하고, 세계선 콘텐츠는 `220ms` fade/수평 이동으로 바꾼다. `LazyListState`의 보이는 첫 항목과 offset을 보존해 패널 확장 시 말풍선이 튀지 않게 한다.

- [x] **Step 5: focused test와 compile 통과**

  Run: `./gradlew :app:testPhoneDebugUnitTest :app:compilePhoneDebugKotlin`

---

### Task 6: 통합 검증, APK, 단일 전달 커밋

**Files:**
- Review: Tasks 1–5 전체 diff.
- Artifact: `android/app/build/outputs/apk/phone/debug/app-phone-debug.apk` 또는 Gradle이 출력한 실제 APK.

**Interfaces:**
- Consumes: 모든 구현과 Figma 검증 결과.
- Produces: 테스트 로그, APK 절대 경로, 실제 흐름 증거, 단일 최종 커밋과 원격 브랜치.

- [x] **Step 1: 전체 phone 단위 테스트**

  Run: `JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home ANDROID_HOME=/Users/dlgksdnf/Library/Android/sdk ./gradlew :app:testPhoneDebugUnitTest`

- [x] **Step 2: 설치 가능한 APK 빌드**

  Run: 같은 환경에서 `./gradlew :app:assemblePhoneDebug`.

- [ ] **Step 3: 실제 핵심 흐름 검증**

  별도 설치 허가가 있거나 현재 빌드를 실행할 수 있는 기존 테스트 장치에서 단톡방 생성, 첫 메시지 전 무응답, 화자/나레이션 표시, 하트 접기·펼치기, 분기·전환 독립성을 확인한다. 설치 권한이 없으면 목표 완료로 처리하지 않고 해당 권한을 요청한다.

- [x] **Step 4: 최종 정적 검토**

  Run: `git diff --check`, 관련 diff 검토, `git status --short`.

- [ ] **Step 5: 단일 커밋과 push**

  모든 변경을 하나의 명확한 커밋으로 만들고 현재 `codex/persona-repetition-control` 브랜치를 `origin`에 push한다. `main` 병합, release, 기기 설치는 하지 않는다.

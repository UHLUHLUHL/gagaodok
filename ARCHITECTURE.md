# 어디에 무엇이 있는지

**고칠 곳을 찾으려고 저장소 전체를 읽지 않아도 되게 하려고 만든 문서입니다.**

파일이 크면 한 줄을 고치려고 천 줄을 읽게 됩니다. 그래서 큰 파일을 갈랐고,
갈라 놓은 것을 찾을 수 있도록 이 표를 둡니다. **이 문서가 목차입니다.**

한쪽을 고치면 대개 다른 쪽도 고쳐야 합니다. 맥과 안드로이드가 같은 구조·같은 이름을
쓰도록 맞춰 두었으니, 한쪽에서 찾은 파일 이름으로 다른 쪽도 바로 찾을 수 있습니다.

| | 맥 (Swift) | 안드로이드 (Kotlin) |
|---|---|---|
| 위치 | `Sources/KakaoSapiens/` | `android/app/src/main/java/com/sapiens/gagaodok/` |
| 크기 | 약 10,300줄 | 약 10,000줄 |
| 시험 | **없음** (아래 참고) | 61개, `app/src/test/` |

---

## 하고 싶은 일 → 열 파일

### 요금·캐시·토큰

| 하고 싶은 일 | 맥 | 안드로이드 |
|---|---|---|
| 캐시를 언제 만들고 버릴지 | `Services/GeminiService+PrefixCache.swift` | `service/AIServicePrefixCache.kt` |
| 사용량을 장부에 적는 곳 | `Services/GeminiService+Transport.swift` | `service/AIServiceTransport.kt` |
| 요금 계산·누적 장부 | `Services/TokenUsageManager.swift` | `data/TokenUsageStore.kt` |
| 토큰 수 어림 (사진 타일 포함) | `Services/TokenEstimator.swift` | `service/TokenEstimator.kt` |
| 사진을 몇 화소로 줄일지 | `Services/ImageBudget.swift` | `service/ImageBudget.kt` |
| 모델 단가 | `Models/AIModel.swift` | `model/AIModel.kt` |

### 대화

| 하고 싶은 일 | 맥 | 안드로이드 |
|---|---|---|
| 요청 본문·스트리밍 | `Services/GeminiService+Conversation.swift` | `service/AIServiceConversation.kt` |
| 답변을 말풍선으로 가르기 | `Services/GeminiService+Bubbles.swift` | `service/AIServiceBubbles.kt` |
| 스트림 조각을 문단으로 모으기 | `Services/StreamingBubbleBuffer.swift` | `service/StreamingBubbleBuffer.kt` |
| 대사·묘사 가르기 | `Services/RoleplayParser.swift` | `service/RoleplayParser.kt` |
| 긴 대화 압축·구간 요약 | `Services/ConversationCompactor.swift` | `service/ConversationCompactor.kt` |
| 요약 요청 보내기 | `Services/GeminiService+Digest.swift` | `service/AIServiceDigest.kt` |
| Luna(OpenAI) 쪽 | `Services/GeminiService+OpenAI.swift` | `service/AIServiceOpenAI.kt` |
| 시스템 지침 (멘토·챗봇) | `Models/ChatMode.swift` | `model/ChatMode.kt` |

### 말투

| 하고 싶은 일 | 맥 | 안드로이드 |
|---|---|---|
| 찾기·미리보기·다듬기 요청 | `Services/GeminiService+Persona.swift` | `service/AIServicePersona.kt` |
| 말투 편집 화면 | `Views/PersonaEditorView.swift` | `ui/screens/PersonaEditorScreen.kt` |

### 화면

| 하고 싶은 일 | 맥 | 안드로이드 |
|---|---|---|
| 대화방 | `Views/SingleChatRoomView.swift` | `ui/screens/ChatRoomScreen.kt` |
| 대화방 상단 바 | `Views/ChatHeaderView.swift` | `ui/screens/ChatRoomHeader.kt` |
| 입력창·수정 바 | `Views/ChatInputView.swift` | `ui/screens/ChatRoomInputBar.kt` |
| 답변 대기 "..." | `Views/TypingIndicatorView.swift` | `ui/screens/ChatRoomTyping.kt` |
| 말풍선 | `Views/MessageBubbleView.swift` | `ui/components/MessageBubble.kt` |
| 목록(친구·채팅) | `Views/KakaoMainWindowView.swift` | `ui/screens/FriendsScreen.kt`, `ChatsScreen.kt` |
| 설정·사용량 | `Views/KakaoUsageSettingsView.swift` | `ui/screens/SettingsScreen.kt` |
| 색 (라이트·다크) | `Views/KakaoTheme.swift` | `ui/theme/KakaoTheme.kt` |
| 치수 | 각 뷰에 흩어져 있음 | `ui/KakaoMetrics.kt` |
| 아이콘 | `Views/KakaoIcons.swift` | `ui/icons/KakaoIcons.kt` |
| 수식·마크다운 | `Views/LaTeXMarkdownView.swift` | `ui/components/MathMarkdownView.kt` |
| 그래프 그리기 | `Services/MathGraphRenderer.swift` | `service/MathGraphRenderer.kt` |

### 저장

| 하고 싶은 일 | 맥 | 안드로이드 |
|---|---|---|
| 방·메시지·요약 | `Models/ChatRoom.swift` | `data/ChatStore.kt` |
| API 키 | `Models/AIModel.swift`의 `KeychainStore` | `data/SecureStore.kt` |
| 설정 | `UserDefaults` (여기저기) | `data/AppSettings.kt` |

---

## 큰 파일을 어떻게 갈랐나

`GeminiService.swift`가 1,738줄, `AIService.kt`가 1,482줄이었습니다.
각각 저장소의 17%와 15%입니다. 한 줄을 고치려고 그걸 다 읽어야 했습니다.

**둘 다 같은 방식으로 갈랐습니다.** 클래스 자신과 상태는 원래 파일에 두고,
하는 일별로 옆 파일에 나눠 담았습니다. Swift는 `extension`, Kotlin은 확장 함수입니다.

```
GeminiService.swift          111줄   액터·상태·입구        AIService.kt          156줄
  +Conversation.swift        325줄   대화 한 턴             AIServiceConversation.kt   252줄
  +PrefixCache.swift         272줄   캐시 규칙              AIServicePrefixCache.kt    263줄
  +Digest.swift               77줄   구간 요약              AIServiceDigest.kt          98줄
  +Persona.swift             446줄   말투                   AIServicePersona.kt        314줄
  +OpenAI.swift              214줄   Luna                   AIServiceOpenAI.kt         116줄
  +Transport.swift           156줄   요청 한 건·장부        AIServiceTransport.kt      190줄
  +Bubbles.swift             192줄   말풍선 가르기          AIServiceBubbles.kt        170줄
```

`ChatRoomScreen.kt`(1,080줄)도 넷으로 갈랐습니다 — 화면·상단 바·입력창·대기 표시.

**코드는 한 줄도 안 고쳤습니다.** 자리만 옮겼습니다. 옮긴 뒤 원본과 대조해
`extension` 여는 줄과 확장 함수의 수신자(`AIService.`) 말고는 차이가 없음을 확인했습니다.

### 왜 `private`이 `internal`이 되었나

다른 파일에서 보여야 하기 때문입니다. **두 앱 모두 모듈이 하나라 `internal`은
"앱 안에서만"과 같은 뜻입니다.** 밖으로 열린 것은 없습니다.

### Kotlin 쪽 한 가지 주의

Kotlin에는 부분 클래스가 없어서 옮긴 함수들이 **확장 함수**가 되었습니다.
그래서 다른 패키지에서 부를 때는 import가 필요합니다.

```kotlin
import com.sapiens.gagaodok.service.lookupPersona   // ← 이런 줄이 필요합니다
```

`PersonaEditorScreen.kt`에 그런 import가 넷 있습니다. 새로 부르는 곳이 생기면
컴파일러가 알려줍니다.

---

## 아직 큰 파일

갈랐어도 600~780줄인 것들이 남아 있습니다. 갈랐을 때의 이득보다 위험이 커 보여
두었습니다. SwiftUI 뷰는 `@State`가 뷰 구조체에 묶여 있어 서비스처럼 깔끔히 안 갈라집니다.

| 파일 | 줄 | 갈라야 할까 |
|---|---|---|
| `Views/SingleChatRoomView.swift` | 777 | 화면 하나가 정말로 그만큼 합니다. 조각(헤더·입력·검색)은 이미 별도 파일입니다 |
| `Views/PersonaEditorView.swift` | 759 | 한 화면·한 흐름입니다 |
| `Views/KakaoMainWindowView.swift` | 759 | **갈라볼 만합니다.** 목록·사이드바·창 껍데기가 한 파일에 있습니다 |
| `Views/MessageBubbleView.swift` | 607 | 말풍선 한 종류가 경우가 많습니다 |
| `Models/ChatRoom.swift` | 578 | 모델 + 저장소 + 검색이 섞여 있어 **갈라볼 만합니다** |
| `ui/screens/PersonaEditorScreen.kt` | 483 | 괜찮은 크기입니다 |

---

## 맥에는 시험이 없습니다

안드로이드는 61개, 맥은 0개입니다. `Package.swift`가 실행 타깃 하나뿐이라
테스트를 붙이려면 라이브러리 타깃으로 쪼개야 합니다.

그때까지는 순수 계산부를 `swiftc`로 직접 묶어 임시로 확인하고 있습니다.
안드로이드 쪽 `app/src/test/`에 같은 내용의 시험이 있으니, 맥을 고칠 때는
**안드로이드 시험을 먼저 보고 무엇을 지켜야 하는지 확인하는 편이 빠릅니다.**

특히 `ConversationCompactor`는 **한 번 잘못 쓰면 되돌릴 수 없습니다.**
요약은 구간마다 한 번만 만들고 다시 만들지 않습니다.

---

## 같이 볼 문서

- `MAC_BACKPORT.md` — 안드로이드에서 고친 것 중 맥에 옮긴 것, 그리고 아직 확인이 필요한 것
- `android/MEASURED.md` — 원조 카카오톡 캡처에서 화소로 잰 치수
- `android/README.md` — 안드로이드 판의 판별 기록

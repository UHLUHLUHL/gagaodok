# Codex Handoff — 가가오독

이 문서는 긴 이전 채팅 없이 다음 Codex 작업을 시작하기 위한 기준점이다.

## 새 작업 시작점

- 저장소: `/Users/dlgksdnf/Desktop/ClaudeCode`
- 기능 기준 브랜치: `codex/obsidian-mentor-export`
- 최신 기능 커밋: `81d4681 feat: export multiple mentor problems to Obsidian`
- 그 브랜치는 `origin/main`의 `0179225` 위에 Obsidian 관련 3개 커밋이 올라간 상태다.
- GitHub push와 `main` 병합은 아직 하지 않았다.
- 새 작업에서는 먼저 `git status --short --branch`와 관련 심볼만 확인한다. 기존 변경을 reset하거나 덮어쓰지 않는다.

## 현재 제품 기준

- macOS 앱 표시 이름은 `가가오독`, 번들 ID와 대화 저장 경로의 내부 이름은 `KakaoSapiens`다.
- macOS Swift 소스는 `Sources/KakaoSapiens`, Android 소스는 `android`다.
- 멘토 압축: `threshold=60`, 최근 원문 `20턴`, 갱신 구간 `40턴`, 요약 예산 `1200`.
- 챗봇/companion 압축은 멘토와 독립적으로 유지한다(`threshold=150`, 원문 `20턴`, 갱신 `50턴`, 예산 `1500`). 멘토 작업에서 챗봇 로직을 바꾸지 않는다.
- 로컬 원문, API 전송 컨텍스트, 압축 요약, Obsidian 내보내기 요청은 서로 다른 데이터 흐름이다.

## 완료된 주요 기능

- 긴 수식의 세로 줄바꿈과 KaTeX/Markdown 렌더링 개선
- LazyVStack의 rich/plain 전환 피드백 루프 제거 및 긴 대화 스크롤 메모리 개선
- 멘토 AI 답변의 단일 문제 Obsidian 내보내기
- 자연어 단일/다중 문제 내보내기 명령 라우팅
- 여러 문제 후보 스캔, 선택, 첨부 참조/새 후보 선택, 순차 저장
- 독립 Obsidian 창, Markdown/LaTeX 미리보기·편집, 흰 시험지 스타일 문제 PNG
- Gemini 구조화 출력에서 지원하지 않는 `additionalProperties` 제거
- 내보내기 AI 요청이 일반 채팅 메시지·`previous_response_id`·다음 컨텍스트에 들어가지 않도록 격리
- Obsidian v2 노트 형식과 기존 생성 노트 마이그레이션

## 관련 파일

- `Sources/KakaoSapiens/Models/Obsidian*.swift`
- `Sources/KakaoSapiens/Services/Obsidian*.swift`
- `Sources/KakaoSapiens/Services/GeminiService+Obsidian.swift`
- `Sources/KakaoSapiens/Views/Obsidian*.swift`
- `Sources/KakaoSapiens/Views/SingleChatRoomView.swift`
- `Sources/KakaoSapiens/Views/ChatHeaderView.swift`
- `Sources/KakaoSapiens/Views/LaTeXMarkdownView.swift`
- `Tests/KakaoSapiensTests/Obsidian*Tests.swift`

## 검증과 실행

```bash
swift build
./build_app.sh
codesign --verify --deep --strict /Applications/가가오독.app
```

마지막 릴리스 빌드는 `/Applications/가가오독.app`에 설치되었고 ad-hoc 서명 검증을 통과했다. 구조화 출력·배치 후보·렌더러·Obsidian 핵심 테스트와 `git diff --check`는 통과했다. 다만 아주 큰 방에서 자연어 배치 명령을 실제로 끝까지 스크롤하는 수동 스트레스 검증은 자동화 포커스 문제로 완전히 수행하지 못했다.

## 다음 작업 규칙

- 사용자가 지정한 플랫폼과 멘토/챗봇 범위만 수정한다.
- 새 기능은 타깃 테스트 후 변경 묶음 마지막에만 전체 빌드·설치한다.
- 긴 대화 원문·대형 JSON·전체 로그를 출력하지 않는다.
- 성능 문제는 프로세스 수치, 샘플, 요청 크기, 캐시 또는 렌더링 수명주기 중 하나 이상의 증거를 먼저 확보한다.
- 커밋·push·main 병합은 명시적 요청이 있을 때만 한다.

## 새 채팅 시작 문구 예시

> `/Users/dlgksdnf/Desktop/ClaudeCode`의 `codex/obsidian-mentor-export` 기준으로 작업을 이어가자. 기존 변경은 보존하고, 이번에는 [원하는 작업]을 수정해줘.


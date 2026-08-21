# 캐릭터 말투 원출처 추출 구현 계획

**목표:** Android phone COMPANION의 최초 말투 찾기를 공식 자료 우선의 3단계 조사로 바꾸고, 충분한 표본으로 규칙을 만들되 채팅 비용은 제한한다.

1. `PersonaSourcePipelineTest`에 출처 우선순위, 48/40/8 상한, 유사 중복, 판본 보존, 증거 호환 테스트를 먼저 추가한다.
2. `PersonaSampleEvidence`와 로컬 정규화·다양성 선택 순수 함수를 구현한다.
3. `AIServicePersona`의 phone COMPANION 찾기를 출처 탐색, YouTube `fileData`/문서 `url_context` 증거 추출, 24~40개 규칙 생성으로 분리한다.
4. 편집 화면이 증거를 저장하되 사용자가 대사를 수정하면 일치하지 않는 연결을 제거하게 한다.
5. 런타임 프롬프트는 다양한 표본 최대 8개와 900토큰 예산을 지키고, 멘토·태블릿 경로가 그대로임을 회귀 검증한다.
6. Android phone 단위 테스트와 release 빌드를 한 번 수행하고, 가능하면 연결 기기에서 실제 흐름을 확인한 뒤 커밋·푸시한다.

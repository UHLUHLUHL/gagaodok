# 말투 조사 대화 신호 로딩 모션 설계

## 범위

- Android `phone` 변형의 `COMPANION` 말투 편집 화면에만 적용한다.
- 이름/링크 조사(`lookup`)와 사용자가 실제 대사로 최초 규칙을 만드는 작업(`analyze`)을 포함한다.
- 멘토 모드, `tabletMentor`, macOS, 규칙 다듬기와 미리보기 로딩은 기존 동작을 유지한다.

## 승인된 디자인

- Figma: https://www.figma.com/design/tYEBz5VicQ9lbd9alrJQgB?node-id=2-2
- 72dp 높이의 인라인 카드에서 76×36dp 대화 신호와 두 줄 상태 문구를 보여준다.
- 신호는 1.2초 동안 `0ms 왼쪽 → 300ms 가운데 → 600ms 오른쪽 → 900–1200ms 작은 휴지점`으로 반복한다.
- 실제 처리 단계에 따라 `공식 자료 확인`, `자료 검토`, `자막 수집`, `말투 규칙 생성` 문구를 바꾼다. 완료율을 계산할 수 없으므로 가짜 퍼센트는 표시하지 않는다.
- 라이트는 `surface`, `sunken`, `textPrimary`, `textSecondary`; 다크는 같은 의미 토큰을 사용한다. 활성 신호는 `editConfirm` 브랜드 노랑을 사용한다.

## 구현 원칙

- Jetpack Compose 기본 애니메이션과 `Canvas`만 사용하며 의존성을 추가하지 않는다.
- Figma SVG의 76×36 좌표계를 dp로 그대로 옮긴다. 원격 Figma 자산 URL은 만료되므로 런타임 자산으로 사용하지 않는다.
- 시스템 애니메이션 배율을 Compose가 따르도록 무한 전환을 사용하고, 접근성 서비스에는 현재 단계를 polite live region으로 노출한다.
- 로딩 문구 선택은 순수 함수로 분리해 JVM 단위 테스트로 보호한다.

# `7748170` Phase 1 canonical schema 독립 검증

## 문서 상태

- 검토일: 2026-08-28
- 대상: `7748170` (Phase 1 canonical schema 미결 계약 통합 확정)
- 작성: Claude Code (Codex 배정 작업)
- 판정: **§15 통합 결정 11건 모두 기술적으로 타당 / 차단 1건·보정 2건·관찰 2건 발견 / 구현 승인 아님**
- 이 검토에서 앱 코드·Cloudflare 리소스·실제 대화 archive를 변경하거나 열지 않았다. Phase 0 수치는 저장소 안 보고서의 집계값만 사용했다.

Codex 소유 문서(`PHASE1_CANONICAL_SCHEMA_DRAFT.md`, E2EE 제안서, 합의문)는 **직접 고치지 않았다.** 아래 발견 사항은 근거와 권고 수정안만 남기고 통합은 Codex가 수행한다.

## 1. 결론

`7748170`의 §15 통합 결정 11건은 모두 타당하다. 특히 다음 세 가지는 검증 과정에서 **문서의 주장을 그대로 재현했다.**

- nullable `worldline_key` 방식이 sentinel UUID 없이 D1 key와 E2EE AAD를 동시에 만족한다
- D1 용량 계산식과 세 시나리오 값이 산술적으로 자기 일관적이다
- 다섯 relationship 참조 + `activeWorldlineId`를 암호화하는 분류가 §8.3의 identity 평문 규칙과 충돌하지 않는다

다만 아래 **차단 1건**은 구현 전에 반드시 결정해야 한다. `bubble_order`에 실제 충돌을 만든다.

## 2. 구현한 contract fixture

| 파일 | 내용 |
| --- | --- |
| [`tools/canonical_schema_contract.py`](../tools/canonical_schema_contract.py) | Phase 1 계약의 실행 가능한 규칙 구현 |
| [`tools/tests/test_canonical_schema_contract.py`](../tools/tests/test_canonical_schema_contract.py) | acceptance test 54건 |

Python 표준 라이브러리만 사용한다. 실제 대화 archive를 열지 않고, 어떤 assertion 메시지도 대화 본문·방 이름·persona를 출력하지 않는다. 참조 값 누출 검사기(`find_plaintext_leaks`)는 **비밀 값 자체를 반환하지 않고 위치 표식(`secret#0`)만 돌려준다.**

배정된 9개 항목의 대응은 다음과 같다.

| 항목 | 대응 test class |
| --- | --- |
| 1 nullable worldline | `NullableWorldlineTests` (5) |
| 2 bubble_order | `BubbleOrderTests` (7), `TombstoneAndBubbleOrderTests` (3) |
| 3 extension | `ExtensionNamespaceTests` (5) |
| 4 tenant·identity | `TenantAndIdentityTests` (6) |
| 5 turn/bubble·삭제 | `TurnBubbleDeletionTests` (6) |
| 6 group/worldline·character 참조 | `GroupWorldlineAndReferenceTests` (6) |
| 7 unsupported profile | `UnsupportedProfileTests` (4) |
| 8 server_seq·idempotency | `ServerSequenceTests` (6) |
| 9 D1 용량 | `CapacityEstimateTests` (5) |

8번은 요청대로 `sqlite3` in-memory transaction으로 검증했다. Cloudflare 리소스는 만들지 않았다.

## 3. 차단 — tombstone 보존 규칙이 없어 `bubble_order`가 재사용될 수 있다

### 3.1 근거

- 초안 §9는 `delete_bubble`·`delete_turn`을 **tombstone 처리**로 정의한다.
- 합의문 원칙 8은 "Tombstone operation 없이 사라진 데이터를 삭제로 해석하지 않는다"이다.
- 그런데 **§14.1 키 설계 표에는 tombstone 컬럼도, tombstone 테이블도 없다.** 초안 전체에서 tombstone이 D1의 어디에 저장되는지, tombstone된 행이 보존되는지 삭제되는지 규정한 문장이 없다.

### 3.2 실제로 일어나는 일

초안 §2 규칙 5는 새 bubble이 "conversation scope 전체의 현재 최대값 + 1"을 받는다고 한다. **"현재"가 살아 있는 행만 뜻하면 번호가 재사용된다.**

```text
scope에 bubble_order 0, 1, 2 존재
→ order 2를 담은 turn을 delete_turn
→ 행이 물리 삭제되면 남은 최대값은 1
→ 새 bubble이 max+1 = 2 를 받음        ← 이미 쓰였던 번호
```

이것이 깨뜨리는 것은 세 가지다.

1. **§14.1의 `UNIQUE(scope, bubble_order)`가 무의미해진다.** 옛 행이 사라졌기 때문에 제약은 통과하지만, 같은 scope에서 서로 다른 `message_id` 둘이 같은 표시 순서를 주장한 이력이 생긴다.
2. **§2 규칙 3·4와 모순된다.** "빈 번호를 허용한다", "재번호 매기지 않는다"는 번호가 은퇴한 뒤 비어 있는 상태를 전제한다. 꼬리 번호가 재사용되면 그 전제가 무너진다.
3. **이미 동기화한 기기에서 표시 순서가 충돌한다.** 삭제 전 order 2를 받아 간 기기는 새 order 2 bubble을 받으면 같은 자리에 두 message를 갖는다.

E2EE AAD field 8(`entity_id`)이 함께 묶이므로 **암호문이 서로 바꿔치기되지는 않는다.** 이것은 기밀성 문제가 아니라 순서 correctness 문제다.

### 3.3 재현

[`TombstoneAndBubbleOrderTests`](../tools/tests/test_canonical_schema_contract.py)가 이 시나리오를 고정한다.

- `test_max_plus_one_over_live_rows_only_reuses_a_retired_order` — 살아있는 행만 세면 은퇴 번호 2가 재발급됨을 보인다
- `test_max_plus_one_over_all_assigned_orders_is_monotonic` — tombstone 포함 시 3이 나와 단조성이 유지됨을 보인다
- `test_reused_order_would_violate_scope_wide_uniqueness` — 두 행이 공존했다면 unique 제약이 실제로 거부함을 보인다

### 3.4 권고 수정안 (Codex 통합용)

**대상: 초안 §14.1과 §2 규칙 5.**

1. §14.1 `bubble`·`turn` 행에 ⬜ `tombstoned_at`(nullable timestamp) 또는 ⬜ `is_tombstoned` 컬럼을 추가하고, **tombstone은 행 삭제가 아니라 soft delete임을 명시한다.**
2. §2 규칙 5의 "현재 최대값"을 **"tombstone된 행을 포함한, 그 scope에 지금까지 배정된 모든 `bubble_order`의 최대값"**으로 바꾼다.
3. §14.1의 `UNIQUE(scope, bubble_order)`가 tombstone된 행에도 계속 적용됨을 명시한다.
4. tombstone 행을 물리적으로 지우는 정책(retention)을 언젠가 도입한다면, 그때 `bubble_order` 최대값을 별도 scope-level watermark 컬럼으로 옮겨야 한다는 조건을 함께 남긴다.

## 4. 보정 1 — 초안 JSON 예시의 UUID가 E2EE canonical 형식을 위반한다

### 4.1 근거

E2EE 제안서 §12.3은 **"UUID는 대문자 하이픈 형식으로 통일한다"**로 canonical 형식을 고정했고, `tools/e2ee_contract_vectors.py`의 `_canonical_uuid_ascii()`는 소문자 입력을 `ValueError`로 거부한다.

그런데 초안의 JSON 예시 UUID 18개 중 **3개가 소문자 hex 문자를 포함해 실제로 거부된다.**

```text
a0000000-0000-4000-8000-000000000001   (account_id, §1.2·§3.3·§4 등 다수)
c0000000-0000-4000-8000-0000000000e1   (engine_profile_id, §3.3·§4)
70000000-0000-4000-8000-0000000000ff   (r2_object_key 안, §7.1)
```

나머지 15개는 hex 문자가 없는 숫자-only UUID라 대소문자 구분이 없어 우연히 통과한다. **즉 문제가 절반만 드러나 있어 눈으로는 놓치기 쉽다.**

### 4.2 영향

이 예시를 그대로 fixture로 옮기면 AAD 계산 단계에서 `ValueError`가 난다. 지금은 문서 예시뿐이라 무해하지만, Phase 1 fixture와 Swift·Kotlin 구현이 예시를 복사하는 순간 실패한다. 더 나쁜 경우는 구현자가 거부를 보고 **소문자를 자동 대문자화하는 우회를 넣는 것**인데, 그러면 같은 방이 두 철자로 서로 다른 scope key를 만들 수 있다.

### 4.3 권고 수정안

초안 §0.1 합성 UUID 규약에 **"예시 UUID도 E2EE §12.3의 대문자 하이픈 형식을 따른다"**를 추가하고, 위 3개를 대문자로 고친다. 규약 문단의 접두사 설명(`1 = room`, `a = account`, `c = engine profile`)도 대문자 표기로 맞춘다.

검증 fixture는 이미 대문자를 쓰고 있으며, `test_lowercase_uuid_is_rejected_as_non_canonical`이 이 규칙을 고정한다.

## 5. 보정 2 — `map_raw_source_space`의 Mac·phone raw label이 문서에 없다

### 5.1 근거

초안 §1.1은 **tablet의 raw `source_space` 값이 `"tablet"`이었다**고만 적는다. Mac과 phone의 raw label은 초안에도 Phase 0 보고서 본문에도 없다.

구현에서는 세 label 모두 명시적 exact-match 표가 필요하다. 현재 fixture는 `{"mac", "phone", "tablet"}`을 가정했지만 **이것은 검증된 값이 아니라 추정이다.**

### 5.2 권고 수정안

초안 §1.1에 세 space의 raw label을 모두 표로 적는다. Phase 0 도구(`tools/sync_inventory.py`)가 실제로 무엇을 출력하는지 Codex가 확인해 확정해 주기 바란다. 확정 전까지 이 fixture의 `mac`·`phone` 항목은 **추정값**으로 취급해야 한다.

## 6. 관찰 1 — `activeWorldlineId` 암호화의 실효 보호는 문서가 시사하는 것보다 약하다

초안 §11.1과 E2EE §8.2는 `GroupChatState.activeWorldlineId`를 암호화 대상으로 분류했다. 분류 자체는 일관적이다.

다만 같은 문단이 근거로 든 문장이 보호 수준을 스스로 제한한다.

> 각 message write가 평문 canonical `worldline_id`를 명시하므로 서버가 active 값 자체를 읽을 필요는 없다.

**서버는 읽을 필요가 없을 뿐, 추론할 수 있다.** 가장 최근 write의 평문 `worldline_id`가 사실상 active worldline이다. 또 `worldline` 행의 key(`worldline_key`)가 평문이므로 어떤 세계선이 존재하는지도 서버에 보인다.

오류는 아니다. 다만 **"암호화했으므로 서버가 현재 세계선을 모른다"로 읽히면 안 된다.** §11.1이나 E2EE §10(명시적 비보장)에 한 줄로 "write 시각 분포로 추론 가능"을 적어두면 나중에 이 보호를 과대평가하지 않는다.

## 7. 관찰 2 — D1 용량 계산의 검증 범위

산술 체인 전체를 재현했고 **모두 일치했다.**

```text
40,355,530 - 20,800,577 - 2,558,968 = 16,995,985   ✓
16,995,985 - 12,494,244             =  4,501,741   ✓
ceil(4,501,741 x 4 / 3)             =  6,002,322   ✓  (반올림이 아니라 올림)
6,002,322 + 44 x 10,000             =  6,442,322   ✓
6,002,322 + 44 x 25,000             =  7,102,322   ✓
6,002,322 + 44 x 50,000             =  8,202,322   ✓
```

첨부 decoded 합계도 확인했다: `8,251,585 + 157,678 + 961,416 = 9,370,679` ✓.

**다만 두 값은 이 문서만으로 재현할 수 없다.**

- `12,494,244` (JSON 안 attachment base64 추정) — 전체를 한 덩어리로 보면 `4 x ceil(9,370,679/3) = 12,494,240`이 나와 4 byte 차이가 난다. 초안이 "**합계**"라고 적었으므로 첨부 44개를 개별 `4 x ceil(n/3)`로 계산해 더한 값으로 보이며, 그 해석이면 자릿수 보정으로 4 byte 차이가 자연스럽다. **개별 첨부 크기는 repository 밖 Phase 0 보고서에 있어 열지 않았으므로 확인하지 못했다.**
- `20,800,577` (avatar 합계)과 `2,558,968` (local-only) — 같은 이유로 재현 불가.

세 값 모두 Codex가 실제 inventory에서 뽑은 것이므로 의심할 근거는 없다. **다만 "독립 재현됨"이 아니라 "Codex 산출값을 그대로 사용"임을 기록해 둔다.**

## 8. §15 통합 결정 11건 판정

| # | 결정 | 판정 |
| ---: | --- | --- |
| 1 | `_enc` 컬럼 / canonical patch path 분리 | 타당 |
| 2 | 한 space에 여러 device 허용, CAS로 통제 | 타당 |
| 3 | `bubble_order` scope-wide `0...2^53-1` | **§3의 tombstone 조건부** |
| 4 | extension `<owner>.<entity>.<field>` + key별 봉투 | 타당, fixture로 고정 |
| 5 | engine profile immutable version entity | 타당 |
| 6 | `relationship_policy = group`은 PHONE_SPACE 전용 | 타당, fixture로 고정 |
| 7 | `legacy_unversioned`는 opaque read-only 보존 | 타당 |
| 8 | 마지막 bubble 삭제 → `delete_turn` 승격, headless 금지 | 타당, fixture로 고정 |
| 9 | checked materialized `worldline_key`, AAD는 nullable | **타당 — 핵심 결정, 재현 확인** |
| 10 | `server_seq` account-wide 단일 cursor | 타당, sqlite로 고정 |
| 11 | 다섯 참조 + `activeWorldlineId` 암호화 | 타당 (§6 관찰 첨부) |

9번을 특히 확인했다. `worldline_key = ""`와 AAD의 `presence = 0`이 같은 scope를 가리키고, `worldline_key`가 AAD·outbox·R2에 새지 않으며, sentinel UUID를 쓰지 않고, 기본 세계선과 명명된 세계선이 D1 key와 AAD 양쪽에서 서로 다른 scope로 남는 것을 각각 test로 고정했다.

## 9. 실행한 검증

| 검증 | 결과 |
| --- | --- |
| `python3 -m unittest tools.tests.test_canonical_schema_contract` | 54 tests OK |
| 기존 3개 test 모듈 동시 실행 (`sync_inventory`, `e2ee_contract_vectors`, 신규) | 66 tests OK |
| verbose 출력의 한글·본문 문자열 등장 | 0건 |
| `git diff --check` | 이상 없음 |
| 초안 JSON 예시 UUID canonical 검사 | 18개 중 3개 위반 (§4) |
| D1 용량 산술 체인 재현 | 전 단계 일치 (§7) |

## 10. 남은 차단점

1. **§3의 tombstone 보존 규칙** — 구현 전에 §14.1과 §2 규칙 5를 보정해야 한다. 이것만이 차단 등급이다.
2. §4의 예시 UUID 대문자 통일 — fixture·구현 이식 전에 고치는 것이 싸다.
3. §5의 Mac·phone raw label 확정 — `tools/sync_inventory.py` 실제 출력 확인 필요.

위 3건이 정리되기 전에는 이 fixture를 Swift·Kotlin으로 이식하거나 Worker API 구현으로 넘어가지 않는 것을 권고한다. 이 문서와 fixture는 **DDL, Worker API, Cloudflare 리소스, Phase 2 합성 시험, Phase 3 실데이터 업로드를 승인하지 않는다.**

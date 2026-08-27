# `7748170` Phase 1 canonical schema 독립 검증

## 문서 상태

- 검토일: 2026-08-28 (2026-08-28 후속 보정: A-1 source_space 실제값, A-2 Base64·envelope 공식)
- 대상: `7748170` (Phase 1 canonical schema 미결 계약 통합 확정)
- 작성: Claude Code (Codex 배정 작업)
- 판정: **§15 통합 결정 11건 모두 기술적으로 타당 / 차단 1건·보정 2건·관찰 2건 발견 / 구현 승인 아님**
- 이 검토에서 앱 코드·Cloudflare 리소스·실제 대화 archive를 변경하거나 열지 않았다. Phase 0 수치는 저장소 안 보고서의 집계값만 사용했다.

Codex 소유 문서(`PHASE1_CANONICAL_SCHEMA_DRAFT.md`, E2EE 제안서, 합의문)는 **직접 고치지 않았다.** 아래 발견 사항은 근거와 권고 수정안만 남기고 통합은 Codex가 수행한다.

## 1. 결론

`7748170`의 §15 통합 결정 11건은 모두 타당하다. 다음 둘은 검증 과정에서 **문서의 주장을 그대로 재현했다.**

- nullable `worldline_key` 방식이 sentinel UUID 없이 D1 key와 E2EE AAD를 동시에 만족한다
- 다섯 relationship 참조 + `activeWorldlineId`를 암호화하는 분류가 §8.3의 identity 평문 규칙과 충돌하지 않는다

**차단 1건**은 구현 전에 반드시 결정해야 한다(§3). `bubble_order`에 실제 충돌을 만든다.

**2026-08-28 후속 보정에서 이 검토 자신의 판정도 하나 뒤집혔다.** 초판은 D1 용량 계산을 "산술 체인 전체 일치"로 승인했는데, 재현은 맞았지만 **재현한 Base64 식 자체가 틀렸다는 것을 검증하지 않았다.** 문서가 스스로 일관적인 것과 문서의 식이 옳은 것은 다른 문제다. §7에 정정을 적었다.

## 2. 구현한 contract fixture

| 파일 | 내용 |
| --- | --- |
| [`tools/canonical_schema_contract.py`](../tools/canonical_schema_contract.py) | Phase 1 계약의 실행 가능한 규칙 구현 |
| [`tools/tests/test_canonical_schema_contract.py`](../tools/tests/test_canonical_schema_contract.py) | acceptance test 64건 |

Python 표준 라이브러리만 사용한다. 실제 대화 archive를 열지 않고, 어떤 assertion 메시지도 대화 본문·방 이름·persona를 출력하지 않는다. 참조 값 누출 검사기(`find_plaintext_leaks`)는 **비밀 값 자체를 반환하지 않고 위치 표식(`secret#0`)만 돌려준다.**

배정된 9개 항목의 대응은 다음과 같다.

| 항목 | 대응 test class |
| --- | --- |
| 1 nullable worldline | `NullableWorldlineTests` (5) |
| 2 bubble_order | `BubbleOrderTests` (7), `TombstoneAndBubbleOrderTests` (3) |
| 3 extension | `ExtensionNamespaceTests` (5) |
| 4 tenant·identity | `TenantAndIdentityTests` (8) |
| 5 turn/bubble·삭제 | `TurnBubbleDeletionTests` (6) |
| 6 group/worldline·character 참조 | `GroupWorldlineAndReferenceTests` (6) |
| 7 unsupported profile | `UnsupportedProfileTests` (4) |
| 8 server_seq·idempotency | `ServerSequenceTests` (6) |
| 9 D1 용량 | `Base64AndEnvelopeTests` (7), `CapacityEstimateTests` (6) |

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

## 5. 해소됨 — `source_space` 실제값 (2026-08-28 보정)

초판 검토는 Mac·phone의 raw label을 확인할 수 없어 `"mac"`·`"phone"`으로 **추정**했다. Codex가 repository 밖 Phase 0 집계 보고서에서 확인한 실제 값은 다르다.

| source | 실제 raw 값 | 처리 |
| --- | --- | --- |
| Mac | `MAC_SPACE` | 이미 canonical, 그대로 통과 |
| Phone | `PHONE_SPACE` | 이미 canonical, 그대로 통과 |
| Tablet | `tablet` | **유일하게 관측된 legacy alias**, 명시적으로 `TABLET_SPACE`로 변환 |

즉 세 source 중 tablet 하나만 legacy label을 냈고, 나머지 둘은 이미 canonical enum을 낸다. **초판 fixture의 `"mac"`·`"phone"` 항목은 실제로 존재하지 않는 값이었다.**

fixture를 실제값 기준으로 고쳤다.

- `MAC_SPACE`·`PHONE_SPACE`·`TABLET_SPACE`는 그대로 통과
- `tablet`만 명시적으로 변환
- **`mac`·`phone`은 관측된 적이 없으므로 거부한다.** 없는 값을 받아주면 그것이 곧 추측이다
- `Tablet`·`TABLET`·`Mac`·`PHONE`·미등록 문자열도 자동 보정 없이 거부

`test_canonical_labels_pass_through_unchanged`, `test_only_observed_legacy_alias_is_translated`, `test_unobserved_lowercase_labels_are_rejected`, `test_case_variants_and_unknown_labels_are_rejected`가 이 규칙을 고정한다.

초안 §1.1은 여전히 tablet의 raw 값만 적고 있으므로, **세 source의 raw label을 모두 표로 명시**하는 보정을 Codex에게 권고한다.

## 6. 관찰 1 — `activeWorldlineId` 암호화의 실효 보호는 문서가 시사하는 것보다 약하다

초안 §11.1과 E2EE §8.2는 `GroupChatState.activeWorldlineId`를 암호화 대상으로 분류했다. 분류 자체는 일관적이다.

다만 같은 문단이 근거로 든 문장이 보호 수준을 스스로 제한한다.

> 각 message write가 평문 canonical `worldline_id`를 명시하므로 서버가 active 값 자체를 읽을 필요는 없다.

**서버는 읽을 필요가 없을 뿐, 추론할 수 있다.** 가장 최근 write의 평문 `worldline_id`가 사실상 active worldline이다. 또 `worldline` 행의 key(`worldline_key`)가 평문이므로 어떤 세계선이 존재하는지도 서버에 보인다.

오류는 아니다. 다만 **"암호화했으므로 서버가 현재 세계선을 모른다"로 읽히면 안 된다.** §11.1이나 E2EE §10(명시적 비보장)에 한 줄로 "write 시각 분포로 추론 가능"을 적어두면 나중에 이 보호를 과대평가하지 않는다.

## 7. 보정 — D1 용량식이 정확한 Base64 계산이 아니었다 (2026-08-28)

### 7.1 초판 검토가 놓친 것

초판 검토는 초안 §14.4의 산술 체인을 재현하고 **"전 단계 일치"**로 판정했다. 재현 자체는 맞았지만, **재현한 공식이 애초에 틀렸다는 점을 검증하지 않았다.** 문서가 스스로 일관적인 것과 문서의 식이 옳은 것은 다른 문제다.

초안은 Base64 팽창을 `ceil(n × 4 / 3)`으로 계산했다. 패딩 포함 표준 Base64의 정확한 길이는 다음과 같다.

```text
base64_length(n) = 4 × ceil(n / 3)
```

두 식은 대부분의 입력에서 다른 값을 낸다.

| n | 초안 `ceil(n×4/3)` | 정확한 `4×ceil(n/3)` |
| ---: | ---: | ---: |
| 0 | 0 | 0 |
| 1 | **2** | 4 |
| 2 | **3** | 4 |
| 3 | 4 | 4 |
| 4 | **6** | 8 |

**패딩 포함 Base64는 항상 4문자 단위로 출력하므로 길이가 반드시 4의 배수다.** 초안 식이 내는 2, 3, 6 같은 값은 어떤 encoder도 만들 수 없다. `test_padded_base64_length_is_always_a_multiple_of_four`와 `test_matches_the_standard_library_encoder`가 표준 라이브러리 `base64.b64encode` 출력 길이와 직접 대조해 이를 고정한다.

### 7.2 envelope 크기도 틀렸다

초안은 field당 AEAD 오버헤드를 **"약 44 byte"**로 잡았다. E2EE 제안서 §7.1의 봉투 실제 크기는 다음 합이다.

```text
version 1 + alg 1 + key_generation 4 + nonce 12 + GCM tag 16 = 34 bytes
```

44는 이 34 byte를 Base64 팽창한 어림값으로 보이는데, 그렇게 쓰면 **봉투를 두 번 세게 된다.** 올바른 순서는 평문에 봉투를 붙인 뒤 전체를 Base64로 감싸는 것이다.

```text
encrypted_field_storage_bytes(p) = 4 × ceil((p + 34) / 3)
```

### 7.3 `P`와 `F`만으로는 정확값을 만들 수 없다

패딩은 **필드마다** 발생하므로, 총 평문 `P`와 필드 수 `F`만 알면 단일 정확값이 나오지 않는다. 각 필드 크기의 3 나머지에 따라 총합이 달라진다.

```text
m_i = p_i + 34,  Σm_i = P + 34F

최솟값: 모든 m_i가 3의 배수      → 4 × ceil((P + 34F) / 3)
최댓값: 모든 m_i % 3 == 1        → 4 × floor((P + 34F + 2F) / 3)
```

`estimate_d1_payload_range(P, F)`가 이 구간을 돌려준다. `test_range_bounds_are_attainable`은 두 경계가 **실제로 도달 가능한 값**임을 구체적 필드 조합으로 보이고, `test_range_brackets_every_possible_padding_outcome`은 임의 분할이 구간 안에 들어오는지 확인한다.

필드별 평문 크기를 아는 경우에는 `exact_encrypted_payload_bytes()`로 정확한 합을 계산한다. `test_encoding_the_sum_is_not_the_sum_of_encodings`가 "합을 인코딩한 값"과 "인코딩의 합"이 실제로 다름을 보인다.

### 7.4 초판 수치의 처리

`6,002,322 + 44 × F`와 세 시나리오 값은 **정확한 수치로 유지하지 않는다.** 추적을 위해 `draft_v1_estimate_bytes()`로만 남겼고, docstring에 "superseded / 두 입력 모두 틀림"을 명시했다. `test_superseded_draft_formula_is_reproducible_but_wrong`이 옛 값을 재현하는 동시에 **그 값이 4의 배수가 아니라 유효한 Base64 길이가 될 수 없음**을 함께 고정한다.

### 7.5 큰 결론은 그대로다

공식이 바뀌어도 **초기 D1 payload가 Free 한도보다 훨씬 작다는 결론은 유지된다.** `test_all_scenarios_stay_far_below_the_free_d1_limit`이 10,000·25,000·50,000 field 시나리오 모두 database 한도 500MB의 5% 미만임을 확인한다. 정확한 값은 **합성 importer가 field별 평문 크기를 산출한 뒤** 확정한다.

### 7.6 여전히 재현하지 못한 값

산술 체인의 뺄셈 부분은 일치한다.

```text
40,355,530 - 20,800,577 - 2,558,968 = 16,995,985   ✓
16,995,985 - 12,494,244             =  4,501,741   ✓
8,251,585 + 157,678 + 961,416       =  9,370,679   ✓  (첨부 decoded 합계)
```

다만 `12,494,244`·`20,800,577`·`2,558,968`은 개별 파일 크기가 repository 밖 Phase 0 보고서에 있어 열지 않았으므로 재현하지 못했다. **"독립 재현됨"이 아니라 "Codex 산출값을 그대로 사용"이다.**

특히 `12,494,244`는 이번 보정으로 해석이 분명해졌다. 전체를 한 덩어리로 보면 `4 × ceil(9,370,679/3) = 12,494,240`이라 4 byte 차이가 나는데, **첨부 44개를 개별 Base64로 계산해 더하면 필드별 패딩 때문에 그만큼 커진다.** §7.3에서 설명한 것과 같은 현상이며, 초안이 "합계"라고 적은 것과 일치한다.

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
| `python3 -m unittest tools.tests.test_canonical_schema_contract` | 64 tests OK |
| 3개 test 모듈 동시 실행 (`sync_inventory`, `e2ee_contract_vectors`, 신규) | 76 tests OK |
| `python3 -m py_compile` (모듈·테스트) | 이상 없음 |
| verbose 출력의 한글·본문 문자열 등장 | 0건 |
| `git diff --check` | 이상 없음 |
| 초안 JSON 예시 UUID canonical 검사 | 18개 중 3개 위반 (§4) |
| Base64 길이를 표준 라이브러리 `b64encode`와 대조 | 10개 입력 일치 (§7.1) |
| D1 용량 산술 뺄셈 체인 재현 | 일치. 단 Base64 식 자체가 부정확했음 (§7) |

## 10. 남은 차단점

1. **§3의 tombstone 보존 규칙** — 구현 전에 §14.1과 §2 규칙 5를 보정해야 한다. 이것만이 차단 등급이다.
2. §4의 예시 UUID 대문자 통일 — fixture·구현 이식 전에 고치는 것이 싸다.
3. **§7의 Base64·envelope 공식 보정** — 초안 §14.4의 `ceil(n×4/3)`과 `44 byte`를 각각 `4×ceil(n/3)`과 `34 byte`로 고치고, `P`·`F`만으로 산출한 값은 단일 수치가 아니라 범위로 표기해야 한다.
4. §5의 raw label 표 — 초안 §1.1이 tablet 값만 적고 있으므로 세 source를 모두 명시하는 것이 좋다. (실제값 자체는 확정되어 fixture에 반영 완료)

위 3건이 정리되기 전에는 이 fixture를 Swift·Kotlin으로 이식하거나 Worker API 구현으로 넘어가지 않는 것을 권고한다. 이 문서와 fixture는 **DDL, Worker API, Cloudflare 리소스, Phase 2 합성 시험, Phase 3 실데이터 업로드를 승인하지 않는다.**

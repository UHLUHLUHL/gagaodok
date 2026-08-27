# E2EE 3차 보정 Codex 통합 검토

_검토일: 2026-08-27 · 대상: `c327650`, 후속 Phase 0 `eb2d860`_

## 판정

E2EE 3차 보정의 R1 Worker 접근 통제, R2 HKDF 단계 분리, `alg` AAD 결속은 기술적으로 타당하다. LP v1과 HKDF 고정값을 별도 Python 표준 라이브러리 구현으로 재현했다.

다만 QR 흐름에는 Worker가 `claim_redeem_auth`를 어떻게 검증하는지에 필요한 **redeem verifier 등록·identity 결속·원자적 소비 절차**가 빠져 있었다. 이번 통합에서 그 계약과 고정 vector를 보완했다. 보완 후 E2EE 기술 계약은 통합 검토 완료로 판정한다.

이 판정은 문서 계약에 대한 것이다. Swift·Kotlin 구현, Worker API, D1·R2 생성, Phase 2 합성 시험, Phase 3 실데이터 업로드는 승인하거나 완료한 것이 아니다.

## 독립 재현 결과

저장소의 [`tools/e2ee_contract_vectors.py`](../tools/e2ee_contract_vectors.py)는 Python 표준 라이브러리만 사용한다. [테스트](../tools/tests/test_e2ee_contract_vectors.py)는 다음을 literal 기대값으로 검증한다.

| 항목 | 결과 |
| --- | --- |
| LP v1 고정 vector와 null/present-empty 구분 | 일치 |
| field 중복·역순 거부 | 통과 |
| RFC 5869 A.1 Extract·Expand | 일치 |
| `canonical_scope_context` 115 bytes | 문서와 일치 |
| `HKDFInfo(scope-root, context)` 171 bytes | 문서와 일치 |
| `scope_prk`, `scope_root_key`, child key 4개 | 문서와 일치 |
| Extract 생략·하위 key 재-Extract 오답 2개 | 문서와 일치 |
| pairing AAD field 6의 `alg = 0x01` 결속 | 통과 |
| UUID 대문자 하이픈 canonical 형식 | 비정규 입력 거부 |

문서의 시험용 `MAC_SPACE`는 Phase 1 schema 초안이 정의한 고정 enum과 일치한다. `account_master_key = 00…1f`는 실제 키가 아니라 눈으로 오타를 찾기 쉬운 fixture이므로 적절하다.

## QR verifier에서 발견하고 보완한 공백

3차 보정은 Worker가 `claim_redeem_auth`의 hash만 저장한다고 했지만 다음이 명시되지 않았다.

1. verifier를 어느 요청에서 등록하는가
2. 다른 session·claim으로 verifier를 옮기지 못하게 무엇에 결속하는가
3. 동시에 두 redeem이 들어오면 어떻게 1회 사용을 보장하는가
4. verifier는 hash인데 “AAD”라고 부른 표현

보완 계약은 다음과 같다.

- 새 기기가 claim 제출 시 `claim_redeem_verifier`를 함께 등록한다.
- verifier hash 입력에 `session_id`, `claim_id`, `claim_lookup`, `claim_redeem_auth`를 LP v1으로 결속한다.
- Worker는 redeem request body의 auth로 verifier를 다시 계산해 constant-time으로 비교한다.
- 성공 시 승인 claim과 package를 원자적으로 consumed 처리하며 동시·반복 redeem은 하나만 성공한다.
- verifier는 AEAD payload가 아니므로 AAD가 아니라 canonical hash binding으로 표현한다.

고정 시험 입력의 verifier는 다음과 같다.

```text
9f7c4f2294826ca2618ee42b6bb617dfd1699bb735fcd529c9725007a2bfdc88
```

## R1 접근 통제 판정

보완 후 §5.1의 계약은 Worker API로 옮길 수 있을 만큼 구체적이다.

- QR bearer는 claim을 제출할 수 있지만 claim 목록·ciphertext를 읽지 못한다.
- 기존 device token은 해당 account와 session에 결속됐을 때만 claim을 조회한다.
- 승인 전 package 생성·조회는 거부한다.
- package는 session이 아니라 승인된 claim identity에 결속된다.
- redeem auth는 URL·log에 남기지 않고 request body로만 전달한다.
- Worker 접근 통제와 QR 유출이 함께 깨지면 암호학적으로 방어하지 못한다는 한계는 §10.7에 유지한다.

Phase 2에서는 기존 7개 negative test에 잘못된 auth·다른 claim verifier 거부와 동시 redeem 단일 성공을 추가해 총 9개로 검증한다.

## Phase 0 실측 통합

`eb2d860`으로 Tablet inventory가 추가돼 세 source space의 기존 첨부와 avatar가 모두 12MB 미만임을 확인했다. 이 결과는 기존 데이터 import 예외가 관측되지 않았다는 뜻이다. Mac 입력 경로에 현재 상한이 없으므로 v1 12MB 상한은 계속 **관측값이 아니라 규격**으로 적용해야 한다.

## 남은 구현 gate

- Python 고정값을 Swift·Kotlin fixture로 이식하고 교차 복호화
- Worker claim 조회 권한과 9개 pairing 시험 구현
- Mac 입력 경로 12MB 상한
- 6.59MB avatar 단일 AEAD 최대 메모리 측정
- recovery·field patch·checkpoint·attachment 합성 contract test
- 실데이터 업로드 전 fail-closed와 평문 log 부재 검증

위 항목이 끝나기 전에는 구현 완료나 Phase 3 승인을 선언하지 않는다.

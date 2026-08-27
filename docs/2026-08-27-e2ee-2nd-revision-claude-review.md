# `618d370` / `377b717` Claude Code 독립 재검토

## 문서 상태

- 검토일: 2026-08-27
- 검토 대상: `618d370`(E2EE 제안서 2차 보정), `377b717`(clean-checkout 링크 복구)
- 작성: Claude Code (`8de019f` 추가 지적을 제기한 세션과 동일 세션)
- 판정: **두 커밋 모두 승인 / 잔여 보정 2건은 Phase 1 계약 확정 전까지 처리 / 구현 착수 승인 아님**
- 이 검토에서 앱 코드·실제 대화 데이터·Cloudflare 리소스·Phase 0 실행은 변경하지 않았다.

## 1. 결론

`618d370`은 [Codex 검토](2026-08-27-sync-encryption-codex-review.md) §8.2~§8.6의 차단 항목과 `8de019f` 재검토에서 새로 제기된 네 항목을 모두 반영했다. `377b717`은 clean checkout의 링크 문제를 실제로 해소했다. 되돌릴 이유가 없다.

다만 **문서를 그대로 Phase 1 구현 규격으로 넘기기 전에** 아래 §3의 두 건을 확정해야 한다. R1은 §8.2가 스스로 세운 acceptance 기준을 문서만으로는 충족했다고 볼 수 없는 부분이고, R2는 Swift·Kotlin이 서로 다른 키를 만들 수 있는 규격 공백이다.

## 2. 독립적으로 검증한 것

문서의 서술을 믿지 않고 직접 재현하거나 실행해 확인한 항목이다.

### 2.1 LP v1 고정 hex vector — 일치

§7.2의 grammar만 읽고 별도로 encoder를 구현해 문서의 vector를 재계산했다.

```text
LP([field 1 = 00 01, field 2 = null, field 3 = UTF-8 "A"])
독립 계산 = 47444b310003000101000000020001000200000000000003010000000141  (30 bytes)
문서 기재 = 47444b310003000101000000020001000200000000000003010000000141
```

magic `GDK1`(47 44 4B 31), `item_count` UInt16BE, item의 `field_id` UInt16BE + `presence` UInt8 + `length` UInt32BE 순서가 문서 표와 일치한다. `presence = 0`일 때 `length = 0`이고 value byte가 없는 것, present empty(`presence = 1, length = 0`)와 null이 다른 byte를 내는 것도 재현된다. **문서의 grammar만으로 제3자가 같은 byte에 도달할 수 있다.** §8.3 차단 항목은 해소됐다.

### 2.2 clean checkout 링크 — 깨진 링크 0건

`git archive 377b717`로 추출한 트리에서 모든 Markdown의 상대 링크 대상 존재를 기계적으로 확인했다.

- 깨진 링크: **0건** (저장소 전체 `.md` 대상)
- `docs/2026-08-26-cross-device-sync-proposal.md` 존재 — 합의문 13·536·537행의 링크가 산다
- `docs/installation/설치방법.txt` 존재 — `README.md`의 설치 링크가 산다
- 루트 `설치방법.txt` 없음 — 이동이 rename으로 완결됐다

작업 트리에 남은 `docs/installation/dist-설치방법.txt`는 `설치방법.txt`와 내용이 동일한 미추적 중복이며, 어떤 문서도 이를 가리키지 않으므로 링크 관점에서 문제가 없다. 정리 여부는 사용자 판단 대상으로 남긴다.

### 2.3 세 문서의 상태 표기 — 일치

| 문서 | 상태 표기 |
| --- | --- |
| E2EE 제안서 | 교차검토 보정 반영 / Claude Code 재검토 대기 / 구현 승인 아님 |
| Codex 검토문 | 2차 보정 작성 완료 / Claude Code 독립 재검토 대기 |
| 핵심 합의문 | E2EE 추가 계약 재검토 중 / 구현 승인 아님 |

`8de019f` 시점에 제안서가 "Codex 교차검토 수렴 완료"라고 단언해 검토문과 정면으로 어긋나던 문제는 해소됐다.

추가로 합의문의 `🤔 사용자 결정 대기` 표가 "과거 이력, 현재 기준 아님"으로 명시됐다. 이 표는 사용자가 17개 결정을 확정한 뒤에도 `결정 필요`를 그대로 달고 있어 **다음 작업자가 이미 끝난 결정을 미결로 오해할 수 있는 상태**였다. 이번 검토 범위 밖에서 발견된 문제였는데 함께 해소됐다.

### 2.4 `8de019f` 재검토에서 제기한 네 항목 — 모두 반영

| 제기 항목 | 반영 위치 |
| --- | --- |
| 문서 간 상태 모순 | §2.3 |
| 합의문 검토 기록 누락 | 합의문 `검토 기록`에 2026-08-27 네 행 추가 |
| pairing 파생 규격 미정의 | §5 파생 표에 label·길이 명시 |
| 단일 generation의 대가 미기재 | §10.3에 "분실 기기가 이후 generation-1 ciphertext를 얻으면 읽을 수 있다"로 명시 |
| tombstone 주입 비보장 누락 | §10.2 신설 |

§10.3은 v1 단일 generation 선택의 손실을 과장 없이 적었다. token 폐기가 정상 경로 접근을 막는다는 사실과, rotation 부재로 남는 잔여 위험을 분리해 서술한 점이 정확하다.

### 2.5 커밋 위생

- 두 커밋 모두 `docs/` 밖을 건드리지 않았다. Swift·Kotlin 소스, `build_app.sh`, Cloudflare 설정 변경 0건.
- 기존 미커밋 작업(`package_for_sharing.sh`, `tools/costsim.py`)과 미추적 파일(`CLAUDE.md`, `docs/CODEX_WORK_LOG.md`, 백업 디렉터리, `exec-*.png`)이 그대로 보존됐다.
- 설계 보정(`618d370`)과 링크 복구(`377b717`)가 분리돼 있어 각각 되돌릴 수 있다.

## 3. 잔여 보정

### 3.1 R1 — pairing claim ciphertext의 열람 권한이 규격에 없다

**§8.2 acceptance 5번("다른 claimant나 session-level bearer가 승인 결과를 가져갈 수 없어야 한다")을 문서만으로는 충족했다고 볼 수 없다.**

§5의 키 흐름을 따라가면 다음이 성립한다.

```text
QR              = session_id + pairing_secret
pairing_claim_key = HKDF(pairing_secret, …)         ← QR만 있으면 유도 가능
claim payload     = AEAD(pairing_claim_key, device_info || claim_secret)
claim_redeem_auth = HKDF(claim_secret, …)
joint_secret      = LP(pairing_secret, claim_secret)
pairing_delivery_key = HKDF(joint_secret, …)
```

`claim_secret`은 **QR에서 유도되는 키 하나로만 보호된 채** Worker에 저장된다(7단계). 따라서 QR을 촬영한 사람이 그 claim ciphertext를 한 번이라도 읽으면:

1. `pairing_claim_key`로 복호화해 `claim_secret`을 얻고,
2. `claim_redeem_auth`를 유도해 **승인된 정상 claim을 대신 redeem**할 수 있으며,
3. `joint_secret`의 두 조각을 모두 가지므로 `pairing_delivery_key`까지 유도해 **key package를 직접 복호화**할 수 있다.

SAS는 이 경로를 막지 못한다. SAS는 공격자가 *자기 claim을 밀어 넣는* 치환을 잡는 장치이고, 여기서 사용자는 손에 든 진짜 기기의 claim을 정상 승인한다. 훔쳐지는 것은 그 승인 결과다.

즉 현재 방어는 **"Worker가 claim ciphertext를 session bearer에게 절대 내주지 않는다"는 접근 통제 가정에 전적으로 의존한다.** 그런데 §5 7~8단계는 "Worker가 session에 저장한다", "기존 기기가 인증된 경로로 받아 복호화한다"까지만 적고, **누가 읽을 수 없는지를 규정하지 않는다.** `pairing_session_lookup`이 `pairing_secret`에서 유도되는 값이라 session을 그 lookup으로 주소 지정하는 자연스러운 Worker API를 만들면 QR 소지자가 그대로 도달한다. §8.2가 고치려던 것이 "접근 통제 대신 암호학으로 보장하라"였는데, 이 지점만 다시 접근 통제로 되돌아간다.

둘 중 하나를 Phase 1 계약에 명시해야 한다.

- **(a) 접근 통제를 규격으로 못 박는다.** claim ciphertext는 계정에 이미 연결된 기기의 device token으로만 조회 가능하고, `pairing_session_lookup` 보유만으로는 어떤 claim record도 읽을 수 없다고 명시한다. 이 경우 §10에 "QR 유출과 claim record 열람이 겹치면 방어가 없다"를 비보장으로 추가한다.
- **(b) redeem 자격을 QR에서 분리한다.** 새 기기가 `claim_secret`과 별개로 `redeem_secret`을 만들어 **claim payload 안에 넣지 않고**, claim 제출 시 `LabeledHash(redeem_secret)` verifier만 평문으로 Worker에 등록한다. 그러면 `pairing_secret`과 claim ciphertext를 모두 가진 상대도 redeem할 수 없다. 다만 `pairing_delivery_key`가 여전히 `joint_secret` 기반이라 package 복호화는 남으므로, 이것까지 막으려면 새 기기의 ephemeral 공개키를 claim에 실어 ECDH로 delivery key를 만들어야 한다(Codex §8.2가 "공개키 방식을 강제하지는 않는다"며 열어둔 선택지).

권고는 **(a)를 v1 규격으로 채택하고 비보장을 명시**하는 것이다. 이 앱의 QR pairing은 사용자가 자기 기기 두 대를 마주 놓고 하는 동작이고, ECDH 도입은 Swift·Kotlin 양쪽에 새 primitive와 test vector를 늘린다. 다만 **"명시 없이 넘어가는 것"만은 안 된다** — 지금 문서 상태로 Phase 1에 들어가면 Worker 구현자가 이 제약을 모른 채 lookup 기반 조회 API를 만들 수 있다.

### 3.2 R2 — scope 하위 키의 HKDF 단계가 확정되지 않았다

§3.2 마지막 문단만 "각 하위 키를 위 label로 다시 **HKDF-expand**한다"라고 쓰고, 문서의 다른 모든 파생은 `HKDF-SHA256(ikm, salt, info, len)` 즉 **extract + expand** 형태로 적혀 있다. 두 연산은 결과가 다르다.

- Swift `CryptoKit`은 `HKDF.deriveKey(inputKeyMaterial:salt:info:outputByteCount:)`(extract+expand)와 `HKDF.expand(pseudoRandomKey:info:outputByteCount:)`를 모두 제공한다.
- Kotlin 쪽은 통상 직접 구현하거나 별도 라이브러리를 쓴다.

각자 문서에 충실해도 한쪽은 extract를 거치고 한쪽은 건너뛸 수 있다. §7.2가 없애려던 "성실하게 구현했는데 byte가 다른" 실패가 키 파생 단계에 남아 있다.

Phase 1에서 다음을 문장으로 못 박아야 한다.

- `scope_root_key` 유도: `HKDF-Extract` 후 `HKDF-Expand`인지, salt는 `PROTOCOL_SALT`인지
- 하위 키 유도: `HKDF-Expand(PRK = scope_root_key, info = HKDFInfo(label, null), L = 32)`로 **extract를 거치지 않는다**는 것을 명시 (또는 반대로 확정)
- 위 두 단계 각각에 대한 고정 hex vector

**§13의 contract test는 이 결함을 잡지 못한다.** 6번(domain separation)은 "같은 root에서 label이 다르면 결과가 다르다"만 확인하므로 양쪽 구현이 각자 일관되기만 하면 통과한다. 3번(교차 복호)이 잡아내지만, 그때는 원인이 키 파생인지 AAD인지 봉투인지 분리하는 데 시간이 든다. 규격에서 미리 막는 편이 싸다.

### 3.3 경미 — 봉투 `alg` byte가 AAD에 없다

§7.1 봉투의 `version`과 `key_generation`은 AAD field 1·2에 중복 기재되어 인증되지만 `alg`(offset 1)는 어디에도 묶이지 않는다. v1이 `0x01` 외를 fail closed로 거부하므로 실질 위험은 없다. 향후 알고리즘을 추가할 때 `alg`를 AAD에 넣거나 supported set을 규격으로 고정해야 downgrade 여지가 생기지 않는다. Phase 1 차단 사항은 아니다.

## 4. 재검토 acceptance criteria

Codex §8.9의 6개 기준에 대한 현재 판정이다.

| 기준 | 판정 |
| --- | --- |
| 1. QR approval·redeem이 동일 claim에 결속된 합성 replay/race test 정의 | **조건부 충족** — §13.7에 정의됨. R1 해소 후 claim ciphertext 열람 시나리오를 test에 추가할 것 |
| 2. Swift·Kotlin 공유 canonical binary grammar와 고정 hex vector | **충족** — §2.1에서 독립 재현 확인. 단 R2의 HKDF 단계 vector는 미비 |
| 3. v1 generation 정책 확정 | **충족** — §6.2에서 `key_generation = 1`만 지원으로 확정 |
| 4. recovery verifier 저장·검증·문구 교체 atomic contract | **충족** — §4의 `recovery_auth_verifier`와 §4.1의 R2 선업로드·D1 transaction·실패 시 기존 record 유지 |
| 5. scope key 용도별 HKDF subkey label 확정 | **조건부 충족** — label은 확정. 파생 단계(R2)가 미확정 |
| 6. clean checkout에서 링크가 실제 파일을 가리킴 | **충족** — §2.2에서 0건 확인 |

## 5. 다음 작업자를 위한 상태

- **지금 할 수 있는 것**: R1·R2를 반영한 제안서 3차 보정. 두 건 모두 문서 작업이며 앱 코드와 무관하다.
- **그 다음**: 합의문에 E2EE 계약과 기기 인증 절을 병합한다.
- **아직 하면 안 되는 것**: 앱 코드 구현, Phase 0 실행, Cloudflare 리소스 생성, 실데이터 업로드. 사용자의 별도 시작 지시가 있어야 한다.
- R1을 (a)로 처리하면 §10에 비보장 항목이 하나 늘고, (b)로 처리하면 §5 절차와 §13.7 test가 함께 바뀐다. **어느 쪽을 고를지는 사용자 결정 사항이다.**

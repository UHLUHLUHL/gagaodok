# Phase 1 Canonical Schema Codex 통합 검토

_검토일: 2026-08-27 · 대상: `8620cd4`_

## 판정

Claude Code 초안의 identity·patch·tombstone·outbox 방향은 타당하다. §15의 미결 10건을 모두 결정했고, 이후 대화에서 추가된 character relationship 참조 암호화도 11번 결정으로 포함했다.

다만 초안에는 turn/bubble 내용 entity, PHONE_SPACE group/worldline payload, tenant key, 표시 순서 unique constraint가 빠져 있었고 사용자 결정 8과 충돌하는 read-only 문구가 있었다. 이를 통합 초안과 E2EE 암호화 목록에서 바로잡았다.

이 판정은 **schema 문서 통합**에 대한 것이다. DDL, Worker API, Swift·Kotlin model, Cloudflare resource, Phase 2 합성 시험, Phase 3 실데이터 업로드를 승인하지 않는다.

## §15 통합 결정

1. D1 암호문 컬럼은 `_enc`, wire patch path는 canonical 이름을 쓴다.
2. 한 `space_id`에 여러 device를 허용하고 동시성은 CAS·authority로 통제한다.
3. `bubble_order`는 scope-wide `0...2^53-1`이며 원본 0-based index, 이후 scope `max+1`이다.
4. extension은 `<owner>.<entity>.<field>` namespace와 key별 봉투를 쓴다.
5. `engine_profile`은 별도 immutable version entity이고 room이 exact revision을 참조한다.
6. `relationship_policy = group`은 v1 `PHONE_SPACE` 전용이다.
7. `legacy_unversioned` digest는 opaque read-only로 보존하고, 필요할 때만 원본에서 새 versioned checkpoint를 만든다.
8. 마지막 bubble 삭제는 `delete_turn`으로 승격하며 headless turn은 만들지 않는다.
9. D1 key는 checked materialized `worldline_key`, API·AAD는 nullable `worldline_id`를 유지한다.
10. `server_seq`는 account-wide 단일 cursor다.
11. character migration 대상 다섯 relationship reference 값과 `activeWorldlineId`는 암호화한다.

## 가장 중요한 scope 결정

기본 세계선은 API와 E2EE에서 계속 `worldline_id = null`이다. D1 composite key만 다음 mapping을 쓴다.

```text
worldline_key = worldline_id ?? ""
CHECK(worldline_key = COALESCE(worldline_id, ''))
```

sentinel UUID는 쓰지 않는다. `worldline_key`를 AAD·outbox·R2 경로에 넣지 않는다. SQLite generated column은 primary key 일부가 될 수 없으므로 ordinary materialized column과 `CHECK`를 선택했다.

## character relationship 암호화

다음 값은 canonical entity identity가 아니라 관계 graph이므로 암호화한다.

- `GroupParticipant.roomId`
- `ParticipantHeart.participantRoomId`
- `ChatMessage.speakerRoomId`
- `MessageReaction.participantRoomId`
- `MessageHeartChange.participantRoomId`
- `GroupChatState.activeWorldlineId`

향후 `character_id` 도입 시 authorized client/importer가 다섯 room reference를 같은 mapping으로 복호화·이전·재암호화한다. entity 자체의 `room_id`·`character_id`는 routing identity이므로 평문을 유지한다.

## D1 용량 계산

Phase 0의 세 archive 합계 40,355,530 byte를 그대로 D1 크기로 보지 않았다.

```text
전체 archive                              40,355,530
- R2 별도 avatar                           20,800,577
- local-only/cache/ink 등                   2,558,968
= message/room/digest JSON                 16,995,985
- JSON 내부 attachment base64 추정          12,494,244
= media 제거 text/JSON                      4,501,741
× base64 4/3                                6,002,322
+ field_count × 44 byte
```

Phase 0 보고서에는 encrypted field instance 수가 없으므로 식을 정직하게 남겼다. 10,000·25,000·50,000 field 시나리오는 각각 약 6.44MB·7.10MB·8.20MB다. index·row header·과거 revision·tombstone·operation log·성장은 포함하지 않는다.

현재 공식 D1 Free 한도는 database당 500MB, account 총 5GB, row/string/BLOB당 2MB다. 초기 payload는 충분히 작아 보이지만 개별 암호문 2MB와 query/write 비용은 합성 DDL에서 다시 측정해야 한다. 근거: [D1 limits](https://developers.cloudflare.com/d1/platform/limits/), [D1 batch](https://developers.cloudflare.com/d1/worker-api/d1-database/#batch), [SQLite generated columns](https://www.sqlite.org/gencol.html#limitations).

## 초안에서 추가로 고친 문제

- turn·bubble canonical content ownership 신설
- `group_state`·`worldline` payload 신설
- persona·attachment key의 `account_id` 누락 수정
- engine profile·extension·change log key 추가
- scope-wide `bubble_order` unique constraint 추가
- tablet raw label `tablet`을 canonical `TABLET_SPACE`로 명시적 mapping
- unsupported profile에서 고지된 fallback을 허용하고 AI turn에 실제 generation profile을 기록
- immutable persona/profile revision과 mutable head/reference CAS 분리

## 다음 구현 전 acceptance

- nullable worldline의 D1 key byte와 E2EE AAD null byte를 함께 검증하는 fixture
- scope-wide bubble order 중복·overflow 거부
- extension key grammar·unknown key opaque round-trip
- account-wide sequence의 idempotent retry·동시 write·pagination
- character relationship reference가 평문 D1·log에 나타나지 않는지 검사
- group/worldline과 unsupported-profile fallback의 canonical round-trip
- 합성 importer가 정확한 encrypted field count와 D1 serialized size를 산출

위 fixture가 통과하기 전에는 이 문서를 구현 완료 규격이나 Phase 3 승인으로 읽지 않는다.

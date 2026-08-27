# Gagaodok Phase 0 비파괴 조사 결과

_실행일: 2026-08-27 · 범위: Mac + Android phone + Android tablet 완료_

## 결론

Mac과 Android phone·tablet의 실제 저장소를 앱이 멈춘 상태에서 archive로 복사하고, **복사본만** 구조 분석했다. Mac·phone의 조사 전후 live source와 tablet에서 반복 생성한 archive의 파일 byte가 동일했다. 대화 본문, 방 이름, persona 본문, 첨부 이름, base64는 보고서와 실행 log에 기록하지 않았다.

이번 결과는 **세 source space의 Phase 0 inventory 완료**를 뜻한다. 동기화 구현과 실데이터 cloud upload 승인은 포함하지 않는다.

민감 archive와 상세 기계 보고서는 repository 밖의 다음 잠금 폴더에 있다.

`/Users/dlgksdnf/Documents/GagaodokPhase0/2026-08-27-phase0-01`

- 폴더 권한: 소유자만 접근 가능한 `0700`
- archive 권한: 소유자만 읽고 쓸 수 있는 `0600`
- 보존 archive: `mac-KakaoSapiens.tar`, `phone-KakaoSapiens.tar`, `tablet-KakaoSapiens.tar`
- repository와 Git commit에는 실제 대화 archive를 넣지 않음
- 검증용 추출 사본 두 벌은 완료 후 휴지통의 `GagaodokPhase0-2026-08-27-copies`, `GagaodokPhase0-2026-08-27-restore`로 옮겨 중복 보관 용량을 줄였으며, 필요하면 복구 가능함

## 조사 방법

1. Mac 앱을 정상 종료하고 Android phone·tablet 앱을 `force-stop`했다. 앱 데이터 삭제는 하지 않았다.
2. 일반 앱 loader를 호출하지 않고 raw file의 hash·크기·mtime을 먼저 기록했다.
3. Mac은 local tar, phone은 승인된 `run-as` + tar stream으로 잠금 폴더에 archive를 만들었다. Tablet은 설치 APK와 같은 서명의 debuggable APK로 데이터 보존 업데이트한 뒤 앱을 실행하지 않고 같은 방식으로 archive했다.
4. archive를 격리 폴더에 풀고 [`tools/sync_inventory.py`](../tools/sync_inventory.py)로 복사본만 분석했다.
5. 같은 archive를 다른 격리 폴더에 다시 풀어 파일 집합·크기·SHA-256이 같은지 확인했다.
6. live source를 다시 측정하고 조사 전과 비교했다.

조사 뒤 Mac 앱은 다시 실행했다. Phone 앱은 데이터 일관성을 위해 `force-stop`한 상태이며 ADB 연결은 해제했다. Tablet은 byte가 동일한 원래 non-debuggable APK로 데이터 보존 업데이트해 복원했고 `force-stop` 상태로 두었다. Tablet의 직접 실행 확인은 기존 파일을 다시 쓸 가능성을 피하기 위해 수행하지 않았다.

Mac의 `loadMessagesForRoom(roomId:)`, Android의 `ChatStore.loadMessages(...)`와 `loadMessagesFresh(...)`는 호출하지 않았다.

## 실제 집계

| 항목 | Mac | Android phone | Android tablet |
| --- | ---: | ---: | ---: |
| 전체 파일 | 24 | 29 | 8 |
| 전체 byte | 18,326,251 | 17,624,961 | 4,404,318 |
| 최대 파일 | 8,356,536 bytes | 6,593,776 bytes | 2,547,686 bytes |
| 방 목록의 방 | 6 | 10 | 2 |
| 메시지 파일 | 13 | 10 | 2 |
| digest 파일 | 1 | 3 | 0 |
| avatar 파일 | 5 | 9 | 2 |
| 단톡방 | 0 | 2 | 0 |
| worldline | 0 | 2 | 0 |
| worldline message/digest 파일 | 0 | 3 | 0 |

Mac의 방 목록은 6개인데 메시지 파일은 13개다. 본문을 보지 않고 room UUID만 대조해, 삭제된 방의 잔여 파일인지 다른 용도의 파일인지 후속 확인해야 한다. 현재 단계에서는 임의 삭제하지 않는다.

## Tablet 획득·복원 결과

무선 디버깅 페어링과 기기 식별은 성공했다.

- 기기: Samsung `SM-X910`
- Android: 16
- application ID: `com.sapiens.gagaodok.tabletmentor`
- 앱 버전: `2.0-tablet-mentor` (`versionCode=1`)
- 내부 저장소: `/data/user/0/com.sapiens.gagaodok.tabletmentor/files/KakaoSapiens`

처음 설치돼 있던 앱은 다음 두 조건 때문에 표준 ADB read-only export를 허용하지 않았다.

- `run-as`: `package not debuggable`로 거부
- 설치 APK manifest: `android:allowBackup="false"`

외부 저장소 `/sdcard/Android/data/com.sapiens.gagaodok.tabletmentor`에는 조사 가능한 파일이 0개였다. 내부 저장소 직접 접근도 Android sandbox가 `Permission denied`로 차단했다.

사용자 승인 후 다음 절차로 조사했다.

1. 현재 설치 APK를 pull하고 새 `tabletMentorDebug` APK를 빌드했다.
2. 두 APK의 signer SHA-256이 `5cf3ebed…a7b4`로 정확히 같은지 먼저 확인했다.
3. 앱을 `force-stop`하고 `adb install -r`로 데이터 보존 업데이트했다. 삭제·초기화·우회 접근은 하지 않았다.
4. 앱을 실행하지 않은 채 `run-as` tar stream으로 archive를 세 번 생성했다. 조사 전 두 번과 조사 후 한 번의 SHA-256이 모두 `f45b399e…d556`으로 같았다.
5. 원래 APK를 `adb install -r`로 복원하고 다시 pull해, 복원 전 보관본과 SHA-256 및 전체 byte가 동일함을 확인했다. UID도 `10057`로 유지됐고 `run-as`는 다시 `package not debuggable`로 거부됐다.

설치 전에는 내부 파일 hash를 읽을 권한이 없었으므로 **디버그 업데이트 이전 live source와의 직접 hash 비교는 불가능했다.** 대신 앱 미실행, 동일 signer, 동일 UID, `install -r`, 반복 archive의 byte 동일성, 원래 APK의 byte 동일 복원으로 경계를 검증했다.

## Turn identity 결과

| 항목 | Mac | Android phone | Android tablet |
| --- | ---: | ---: | ---: |
| `turnId == nil`이 있는 메시지 파일 | 3 | 0 | 0 |
| non-null `turnId`가 있는 메시지 파일 | 7 | 10 | 2 |
| nil과 non-null이 같은 파일에 공존 | 0 | 0 | 0 |
| AI 구간의 서로 다른 non-null turn ID: `0 / 1 / 2+` | 4 / 406 / 1 | 0 / 789 / 0 | 0 / 33 / 0 |
| nil 파일과 `2+` AI 구간이 겹치는 즉시 위험 파일 | 0 | 0 | 0 |
| `speakerRoomId`가 있는 파일 | 0 | 2 | 0 |

Mac에는 legacy nil 파일 3개와 서로 다른 두 AI turn이 인접한 구간 1개가 각각 존재하지만, 같은 파일에 겹치지는 않는다. 따라서 이번 snapshot에서 확인된 **즉시 migration 위험 파일은 0개**다. 그렇더라도 legacy 파일을 `known safe`로 부르지 않고 `unknown`으로 유지한다.

Timestamp 간격은 육안 확인 대상을 줄이는 휴리스틱일 뿐 훼손 판정 근거가 아니다. Mac에서 가장 큰 인접 AI gap은 약 44,923초, phone은 약 15.94초, tablet은 약 0.82초였다. 이 수치만으로 손상 여부를 결론 내리지 않는다.

## 첨부·avatar 결과

| 항목 | Mac | Android phone | Android tablet |
| --- | ---: | ---: | ---: |
| 첨부 개수 | 30 | 1 | 13 |
| 첨부 총 decoded byte | 8,251,585 | 157,678 | 961,416 |
| 최대 첨부 | 2,618,357 bytes | 157,678 bytes | 174,199 bytes |
| 선언 크기와 base64 계산 크기 불일치 | 0 | 0 | 0 |
| 최대 avatar | 1,391,214 bytes | 6,593,776 bytes | 274,146 bytes |

관측된 세 source space의 기존 첨부는 모두 12MB보다 작았다. 다만 Mac 앱 자체에는 첨부 상한이 없으므로, 이것을 영구적인 전체 상한의 증명으로 사용하면 안 된다. 특히 phone의 최대 avatar가 약 6.59MB이므로 R2·암호화·메모리 시험에는 attachment뿐 아니라 avatar도 포함해야 한다.

## 단톡방·digest 결과

- Phone에서 group participant 참조 4개, `speakerRoomId` 메시지 411개, reaction 2개, heart change 237개를 확인했다.
- Phone의 단톡방·worldline을 초기 범위에 포함한다는 사용자 결정을 구현 계약이 실제로 다뤄야 한다.
- 발견한 digest는 Mac 1개, phone 3개이며 모두 policy 식별자가 없는 `legacy_unversioned`로 분류했다. Tablet에는 digest가 없었다.
- JSON decode·encoding·크기 초과·read 오류는 세 source space 모두 0건이었다.

## 비파괴성과 복원 검증

| 검사 | 결과 |
| --- | --- |
| Mac live source 전후 파일 집합·크기·mtime·SHA-256 | 동일 |
| Phone live source 전후 파일 집합·크기·mtime·SHA-256 | 동일 |
| Tablet archive 반복 생성 3회의 전체 byte·SHA-256 | 동일 |
| Tablet inventory 추출본 전후 파일 집합·크기·mtime·SHA-256 | 동일 |
| Tablet 원래 APK와 조사 후 복원 APK 전체 byte·SHA-256 | 동일 |
| Phone live source와 추출 사본의 크기·SHA-256·초 단위 mtime | 동일 |
| Archive를 두 위치에 풀었을 때 파일 집합·크기·mtime·SHA-256 | 동일 |
| Mac live source와 tar 추출본의 크기·SHA-256 | 동일 |
| JSON parser 오류 | 0건 |

Mac tar 추출본은 원본의 nanosecond 단위 mtime까지 보존하지 않아 live-to-copy 전체 비교에서는 mtime 차이가 잡혔다. 파일 byte와 SHA-256은 동일하며, archive를 반복 추출한 두 사본끼리는 mtime까지 동일했다. Live source 자체의 mtime은 조사 전후 변하지 않았다.

## 개인정보 비노출 검증

합성 fixture에 본문·방 이름·persona·첨부 이름·base64 sentinel을 넣은 뒤 다음을 자동 검사했다.

- inventory 전후 원본 SHA-256·크기·mtime 동일
- 같은 입력을 두 번 분석한 결과 동일
- 생성된 모든 report와 stdout/stderr에 sentinel 0건
- malformed JSON 오류 report에도 원문 0건
- 조사 도구에서 금지된 앱 loader 참조 0건

실제 report에는 aggregate, field 이름 집합, MIME count, hash manifest와 opaque candidate ID만 남긴다.

## 남은 일

1. Mac의 방 목록 6개와 메시지 파일 13개를 room UUID만으로 대조해 잔여 파일 수를 확정한다.
2. 도구·결과의 추가 교차검토는 최종 통합 gate에서 필요할 때만 수행한다.
3. Phase 3 실데이터 cloud upload는 계속 보류한다.

# Cross-device sync handoff — 2026-09-01

## Authority and stop point

This handoff freezes local implementation at `f5cbf06` on `main`.  The user
asked the current Codex run to stop after the in-progress Android continuation
work and prepare this document.  Do **not** infer approval for the remaining
local tasks, Task 15, or any Cloudflare action from this document.

The user has **not** authorized remote deploy, remote D1 migration, production
resource changes, real-conversation read/upload, APK installation, app-data
clear, push, or merge in this handoff.  Task 15 is deliberately untouched.

Current worktree has unrelated user files.  Preserve them exactly; do not
stage, modify, remove, or reset them:

```text
 M package_for_sharing.sh
 M tools/costsim.py
?? KakaoSapiens-backup-20260814-110708/
?? docs/2026-08-27-deferred-followups-memo.md
?? docs/CODEX_WORK_LOG.md
?? docs/installation/dist-설치방법.txt
?? docs/superpowers/plans/2026-08-31-complete-cross-device-sync.md
?? exec-34b9ed07-11b9-454b-89d3-c768f9a79aa9.png
?? tools/__pycache__/
?? tools/tests/__pycache__/
```

## Baseline and completed implementation

The plan baseline is `e7bbfb2`.  Local branch `main` is ahead of
`origin/main`; no push occurred.

The room-family origin compatibility/enforcement and client writer work is in
the committed history ending at `479fc1b`, `3c273a8`, and their platform
counterparts.  Remote rooms are stored only under each app's `sync/remote/`
projection and exposure policy is fixed by `9be1821`:

- phone-origin rooms are hidden elsewhere;
- Mac-origin rooms are visible on phone only;
- tablet-origin rooms are visible on Mac and phone.

Continuation work is committed and is intentionally limited to personal
chatbot rooms:

| Commit | Meaning |
| --- | --- |
| `fdbab7a` | durable remote-reply journal contract |
| `192f780` | Swift Gemini 3.7 remote reply preparation |
| `40392d0`, `3480593` | Android capability projection and first reply coordinator |
| `421dc67`, `82f9073` | source room emits capability only for companion/chatbot rooms |
| `f5cbf06` | Android UI wiring and durable journal-before-outbox fix |
| `aa2cee4` | Swift/Kotlin runtime switch foundation |

`f5cbf06` is important: Android now prepares the encrypted operation plan,
writes the exact operation bytes to `SyncRemoteReplyJournal`, and only then
adds them to `SyncOutbox`.  The remote-room UI calls this route only for
`CHATBOT`; unsupported rooms remain read-only.  It generates with Gemini 3.7
only and neither reads nor writes the local ChatStore.  No Worker request is
made by this UI path; delivery remains a later runtime concern.

The independent runtime switches from `aa2cee4` are real core gates, but not
yet lifecycle-integrated:

```text
syncEnabled       permits scheduled sync work
remoteReadEnabled controls use of remote projection
remoteReplyEnabled controls continuation creation
```

All current connection configurations still default to `enabled = false`.
The new coordinator itself therefore sends no request unless a future caller
explicitly enables it.

## Verification actually run on the frozen state

- `swiftc -parse-as-library Sources/KakaoSapiens/Services/SyncRuntimeCoordinator.swift Tests/KakaoSapiensSyncOutboxTests/SyncRuntimeCoordinatorTests.swift -o /tmp/sync-runtime && /tmp/sync-runtime` — 2 runtime-switch tests passed.
- `cd android && ./gradlew :app:testPhoneDebugUnitTest --tests '*SyncRuntimeCoordinatorTest*'` — passed.
- `cd android && ./gradlew :app:testPhoneDebugUnitTest --tests '*SyncRemoteReplyCoordinatorTest*' --tests '*SyncShadowWriterFixtureTest*'` — passed after the journal-before-outbox change.
- `cd android && ./gradlew :app:compilePhoneDebugKotlin :app:compileTabletMentorDebugKotlin :app:testPhoneDebugUnitTest --tests '*SyncRemoteReplyCoordinatorTest*'` — passed after the Android UI route was connected.
- `git diff --check` passed before each new commit.

No APK was built or installed in this continuation.  No Cloudflare test,
smoke, deploy, login, migration, or remote resource operation was run after
these local commits.

## Open work — do not paper over these gates

### Task 11: encrypted photo/PDF attachment transfer is blocked by a contract gap

Do not implement an attachment coordinator yet.  The canonical attachment
identity is only `(account_id, attachment_id)`, while `SyncE2EE.Scope` and the
existing scope-root derivation require `space_id` **and** `room_id`.
`attachment_wrap_key` is described as a scope child key, but the canonical
documents do not define the attachment's scope, its wrapped-file-key AAD, or
the R2 file-envelope AAD.  A fake room UUID or a guessed source room would make
cross-device decryption incompatible.

Before Task 11, obtain and record an explicit crypto-contract decision covering
at least:

1. the derivation context for attachment wrap keys;
2. the AAD fields for `wrapped_file_key` and the single v1 R2 AES-GCM object;
3. how an attachment with no bubble reference remains readable account-wide.

Then write shared Swift/Kotlin vectors first.  Keep Worker ciphertext-only.

### Task 12: full room-family capability is not implemented

Current `SyncRemoteRoomAssembler` implementations only assemble room, turn,
bubble and the continuation extension.  They do not validate/render
group_state, named worldlines, engine-profile revisions, persona snapshot/head,
checkpoints, or ready attachment references.  Implement the planned canonical
snapshot builders with a capability-complete synthetic fixture.  A missing
reference must mark that family unsupported; never silently use a default.
Do not sync Gemini cache or affection state.

### Task 13: finish runtime only after Task 12 shape is stable

`aa2cee4` supplies the two-platform testable switch/single-flight core only.
Still needed:

- lifecycle integration on macOS and Android;
- foreground/manual/post-send scheduling and bounded retry/backoff;
- disabled/revoked/offline persistence behavior;
- status UI that never claims live synchronization while `syncEnabled=false`.

Keep all default configurations disabled and do not make a network call merely
because a settings/remote-room view appeared.

### Task 14: local complete acceptance is unstarted

After Tasks 11–13, create the deterministic synthetic Worker E2E fixture and
run the complete local matrix.  The fixture must contain no real text, token,
recovery phrase, endpoint, or ciphertext dump.  Record only actual commands
and results in the acceptance matrix.

### Task 15: held for a separate explicit user approval

Only after local acceptance and direct approval: user-guided Cloudflare login
(browser/MFA as required), isolated synthetic resource verification, remote
migration/deploy/smoke, then separate real-data activation approval.  Do not
bundle Task 15 with the local work.

## Suggested resumption order

1. Resolve the attachment encryption contract and add cross-platform vectors.
2. Complete Task 11 only after those vectors are green.
3. Complete Task 12 capability-complete projection/unsupported behavior.
4. Finish Task 13 lifecycle and status wiring, retaining `syncEnabled=false`.
5. Complete Task 14 local synthetic acceptance and report the resulting gate.
6. Stop for the user's explicit Task 15 approval.

## Handoff reporting format

Report compactly with: `HEAD`, commits, owned files, tests actually run,
unresolved contract gate, boundary confirmation (`real-data`, `remote`,
`install`, `push`), and next gate.  Do not paste conversation data, encrypted
body bytes, token values, recovery words, R2 keys, SQL errors, or stack traces.

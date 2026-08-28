# Gagaodok Repository Rules (Claude Code)

Read by Claude Code only; Codex reads `AGENTS.md`. The two files may state the
same project constraint differently — each is written for its own harness, so
do not copy wording between them. Keep the *constraints* consistent, not the
sentences.

These rules add only Gagaodok-specific constraints on top of the global
`~/.claude/CLAUDE.md`. Language, authority, handoff, subagent, and verification
reporting rules live there and are not repeated here.

## Collaboration

- Codex leads architecture, task division, integration, and final judgment.
  Claude Code receives a bounded task with owned files, forbidden scope, and
  required checks.
- **Inside the assigned scope, finish the task.** Do not halt to wait for
  Codex to re-approve something the prompt already covers. This is about not
  blocking, not about staying silent: keep the user posted on a long run or a
  material finding, then deliver the consolidated result at the end.
- Raise it instead of guessing when the task genuinely requires touching a file
  outside the owned set, or when a finding invalidates the assigned approach.
- Agents work in parallel: never edit a file another agent currently owns.

## Documentation location

- All Markdown (and similar) documents for this project belong under
  `docs/`. Write and save new docs there, not at the repo root or scattered
  in subdirectories.
- Exceptions that stay at the repo root: `AGENTS.md` (Codex's control
  document), `CLAUDE.md` (shared Claude Code project instructions), and
  `README.md` (repository entry point).
- Vendored/reference material under `reference/` (external repos pulled in
  for reference) is exempt — do not reorganize it.

## Scope boundaries

- macOS Swift: `Sources/KakaoSapiens/`. Android: `android/`. Cloudflare Worker
  and D1 migrations: `cloudflare/sync-worker/`.
- Change only the requested platform unless shared behavior explicitly
  requires both.
- Identify **mentor vs chatbot** and **phone vs tablet** before editing shared
  behavior. A mentor-only request must not alter chatbot prompts, compaction,
  message handling, or UI behavior.
- Keep these as separate data flows: local stored messages, API-bound context,
  compacted summaries, Obsidian export requests, and sync payloads.

## Minimal workflow

1. One narrow `rg` search for the relevant symbol or view.
2. Read only the owning file, adjacent type, and directly called service.
   Open architecture, cost, or sync design documents only at the cited
   section.
3. Prove the cause, apply the smallest cohesive patch, and run the smallest
   useful check.
4. After all edits are complete, perform one risk-appropriate final build or
   real-flow verification.
5. Finish with `git diff --check` and a focused diff review.

Do not repeatedly scan the repository, rebuild after every file, or relaunch
the app for non-UI changes. Stored conversation files count as real user data,
so a long room is inspected by counts, sizes, and IDs by default — the narrow
content-analysis exception in the global file still applies.

## Verification matrix

- Swift logic: targeted test if available, then one `swift build` at the
  end.
- **Android: inspect Gradle's reported JVM first.** Use JDK 17 unless the
  active checkout explicitly requires another version; report a mismatch
  before running tests rather than working around it. Build/test only the
  affected variant and skip macOS builds.
- Worker and D1 migrations: `npm test -- --run` and `npm run typecheck` in
  `cloudflare/sync-worker/`. These run entirely in the local
  workerd/Miniflare runtime — never against a remote binding.
- Shared storage, model routing, networking, or compaction: test both
  affected modes/platforms, but only the specific regression surface.
- Markdown, LaTeX, message bubbles, scrolling, resizing, or memory
  behavior: verify the relevant long-message/long-room and narrow-window
  flow in the installed app. **If that flow cannot actually be run, report
  the UI as unverified and name the check still needed — never infer it
  from a successful build.**
- Bundle resources, signing, packaging, or installation: first determine
  whether `./build_app.sh` replaces `/Applications/가가오독.app`. Without
  explicit install approval, verify only the local artifact. After an
  approved install, run
  `codesign --verify --deep --strict /Applications/가가오독.app` and state
  explicitly whether the installed app changed.
- Run a full regression suite only for broad shared infrastructure or when
  targeted evidence is insufficient.

## Cross-device sync safety

- `docs/CROSS_DEVICE_SYNC_USER_DECISIONS.md` and the Phase 1 design
  documents record **product decisions only**. They are not authorization to
  deploy, create remote Cloudflare resources, run a remote migration, or
  read/upload real conversation data.
- No Cloudflare deploy, `--remote` command, real-data import, APK install,
  app-data clear, destructive migration, or GitHub Release publish without
  explicit user approval.
- Keep synthetic/local contract work strictly separate from real-data
  phases. Synthetic fixtures use obviously fake identifiers and carry no
  conversation content.

## Performance and model-context rules

- Do not optimize from intuition alone. Obtain at least one concrete
  signal: process metrics, a sample/profile, allocation behavior, request
  payload size, cache metrics, or render-lifecycle evidence.
- Before changing API context, measure message count/size and inspect
  stable common-prefix and compaction boundaries. Avoid moving-window
  patterns such as `suffix(N)` when they destroy prompt-cache reuse.
- Prefer deterministic local work for Markdown preview, KaTeX, PNG
  generation, file storage, migration, filtering, and validation. Model
  calls are reserved for tasks that genuinely require semantic judgment.
- Independent export/analysis requests must not enter the normal chat
  response chain or future conversation context.

## Delivery

- State the affected platform, mentor/chatbot and phone/tablet scope, checks
  actually run, unresolved gates, and whether `/Applications/가가오독.app`
  was installed.
- Treat commits and canonical `docs/` files as the durable record. A handoff
  names commit hashes and decisions instead of pasting full reports.
- Create a new `docs/` review document only for a durable decision, blocker,
  or gate. Routine approval belongs in the commit message or the user report.

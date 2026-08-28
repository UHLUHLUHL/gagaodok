# Gagaodok Repository Rules

These rules add only Gagaodok-specific constraints to the global contract.

## Scope and coordination

- macOS Swift: `Sources/KakaoSapiens/`; Android: `android/`; Worker:
  `cloudflare/sync-worker/`; project documents: `docs/`.
- Identify mentor vs chatbot and phone vs tablet before changing shared behavior.
- Preserve local messages, API context, compacted summaries, exports, and sync
  payloads as separate data flows.
- Codex leads architecture, task division, integration, and final reporting.
  Claude Code receives bounded prompts with owned files, forbidden scope, tests,
  and commit requirements. Agents must not edit the same files concurrently.
- Existing staged or dirty files belong to their current owner. Inspect overlap
  before editing and never absorb unrelated work into a commit.

## Minimal workflow

- After the initial status check, inspect only the owning symbol, adjacent type,
  and directly called service. Open design/cost documents only at cited sections.
- For long rooms or real data, inspect counts, sizes, IDs, and minimal samples;
  never print conversation bodies.
- Prefer deterministic local tooling for parsing, migration, rendering, storage,
  and validation. Use a model only for semantic judgment.
- Finish edits with `git diff --check`, a focused diff review, and one
  risk-appropriate check. Do not rebuild after every file.

## Context economy

- Treat commits and canonical `docs/` files as durable context. Handoffs should
  name commit hashes and decisions, not paste full reports or routine logs.
- Start a new task at a phase or feature boundary once the handoff is committed.
- The implementer runs the affected suite; the reviewer reruns only disputed or
  high-risk checks, then records deltas instead of restating the whole history.
- Create a new review document only for a durable decision, blocker, or gate.
  Routine approval belongs in the commit message or a short user report.

## Verification choices

- Swift logic: focused test if available, then one final `swift build` when needed.
- Android: use Gradle's reported JVM; Gagaodok requires JDK 17 unless the checkout
  proves otherwise. Test/build only the affected variant.
- Shared storage, routing, networking, or compaction: verify only affected modes
  and platforms. UI claims require the relevant real flow when feasible.
- Packaging/install changes only: run `./build_app.sh`, then verify the installed
  app signature. State explicitly whether `/Applications/가가오독.app` changed.

## Cross-device sync safety

- Treat `docs/CROSS_DEVICE_SYNC_USER_DECISIONS.md` as product policy, not as
  authorization to deploy, create remote resources, or inspect/upload real data.
- No Cloudflare deploy, remote migration, real-data import, APK install, app-data
  clear, or destructive migration without explicit user approval.
- Keep synthetic/local contract work separate from real-data phases.

## Delivery

- Report affected platform/mode, checks run, unresolved gates, and commit state.
- Commit only when the user requests it or explicitly hands work to the other
  agent; use a detailed handoff message. Never push or merge without permission.

# Gagaodok Repository Rules

These rules add only Gagaodok-specific constraints to the global contract.

## Scope and coordination

- macOS Swift: `Sources/KakaoSapiens/`; Android: `android/`; Worker:
  `cloudflare/sync-worker/`; project documents: `docs/`.
- Identify mentor vs chatbot and phone vs tablet before changing shared behavior.
- Preserve local messages, API context, compacted summaries, exports, and sync
  payloads as separate data flows.
- When Codex and Claude Code collaborate, Codex leads architecture, task division,
  integration, and final reporting. Do not create orchestration for solo work.
- Give Claude Code bounded prompts with owned files, forbidden scope, required
  checks, and an explicit commit policy. Agents must not edit the same files
  concurrently.

## Minimal workflow

- After the initial status check, start with the owning symbol, adjacent type, and
  directly called service. Expand only when evidence or the change surface
  requires following another call, test, schema, configuration, migration, data
  flow, or invariant.
- Open design and cost documents at cited sections first. Expand only to referenced
  or necessary sections.
- For long rooms or real data, inspect counts, sizes, IDs, and minimal samples;
  never print conversation bodies.
- Use deterministic local tools for parsing, migration, rendering, storage, and
  mechanical validation. Do not invoke another model or agent when local tooling
  can produce the required result exactly.
- Finish edits with `git diff --check` and a focused diff review. Run any
  additional check required by the relevant failure mode. Do not rebuild after
  every file.

## Context economy

- Treat commits and canonical `docs/` files as durable context. Handoffs should
  name commit hashes and decisions, not paste full reports or routine logs.
- After a committed handoff, recommend a new task at a clear phase or feature
  boundary when the old context is no longer useful.
- Create a new review document only for a durable decision, blocker, or gate.
  Routine approval belongs in the commit message or a short user report.

## Verification choices

- Swift logic: focused test if available, then one final `swift build` when needed.
- Android: inspect Gradle's reported JVM first. Use JDK 17 unless the active
  checkout explicitly requires another version; report a mismatch before testing.
  Test/build the affected variant or variants. Expand only when shared build,
  packaging, or runtime code crosses variant boundaries.
- Shared storage, routing, networking, or compaction: verify only affected modes
  and platforms. UI claims require the relevant real flow when feasible; if it is
  unavailable, report the UI as unverified rather than inferring it from a build.
- For packaging changes, determine whether `./build_app.sh` replaces the installed
  app before running it. Without explicit install approval, verify only a local
  artifact. After an approved install, verify its signature and state explicitly
  whether `/Applications/가가오독.app` changed.

## Cross-device sync safety

- Treat `docs/CROSS_DEVICE_SYNC_USER_DECISIONS.md` as product policy, not as
  authorization to deploy, create remote resources, or inspect/upload real data.
- No Cloudflare deploy, remote migration, real-data import, APK install, app-data
  clear, or destructive migration without explicit user approval.
- Keep synthetic/local contract work separate from real-data phases.

## Delivery

- Report affected platform/mode, checks run, unresolved gates, and commit state.

# Gagaodok Repository Rules

## Scope boundaries

- macOS Swift code is under `Sources/KakaoSapiens`; Android code is under `android`. Change only the requested platform unless shared behavior explicitly requires both.
- Identify the mentor/chatbot branch before editing. A mentor-only request must not alter chatbot prompts, compaction, message handling, or UI behavior.
- Keep local source messages, API-bound context, compacted summaries, and Obsidian export requests as separate data flows.
- Preserve all pre-existing uncommitted changes and untracked files. Inspect overlapping hunks before editing; ignore unrelated dirt.

## Minimal workflow

1. Run `git status --short --branch` and one narrow `rg` search for the relevant symbol or view.
2. Read only the owning file, adjacent type, and directly called service. Open architecture or cost documents only at the relevant section.
3. Prove the cause, apply the smallest cohesive patch, and run the smallest useful check.
4. After all edits are complete, perform one risk-appropriate final build or real-flow verification.
5. Finish with `git diff --check`, a focused diff review, and `git status --short`.

Do not repeatedly scan the repository, rebuild after every file, relaunch the app for non-UI changes, or print full persisted conversations. For long rooms, inspect counts, sizes, IDs, and minimal samples only.

## Verification matrix

- Swift logic: targeted test if available, then one `swift build` at the end.
- Android-only logic: targeted Gradle test/build; skip macOS builds.
- Shared storage, model routing, networking, or compaction: test both affected modes/platforms, but only the specific regression surface.
- Markdown, LaTeX, message bubbles, scrolling, resizing, or memory behavior: verify the relevant long-message/long-room and narrow-window flow in the installed app.
- Bundle resources, signing, packaging, or installation: run `./build_app.sh` once at the end, then `codesign --verify --deep --strict /Applications/가가오독.app`.
- Run a full regression suite only for broad shared infrastructure or when targeted evidence is insufficient.

## Performance and model-context rules

- Do not optimize from intuition alone. Obtain at least one concrete signal: process metrics, a sample/profile, allocation behavior, request payload size, cache metrics, or render-lifecycle evidence.
- Before changing API context, measure message count/size and inspect stable common-prefix and compaction boundaries. Avoid moving-window patterns such as `suffix(N)` when they destroy prompt-cache reuse.
- Prefer deterministic local work for Markdown preview, KaTeX, PNG generation, file storage, migration, filtering, and validation. Model calls are reserved for tasks that genuinely require semantic judgment.
- Independent export/analysis requests must not enter the normal chat response chain or future conversation context.

## Delivery

- State the affected platform and mentor/chatbot scope, checks actually run, and whether `/Applications/가가오독.app` was installed.
- Do not commit, push, merge to `main`, or publish a release unless the user explicitly asks.

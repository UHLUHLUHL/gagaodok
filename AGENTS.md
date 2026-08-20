# Gagaodok Project Entry

This checkout is the coordination root for Gagaodok. A feature branch may be
checked out in another Git worktree, so do not assume the root checkout holds
the newest app code.

## Start every Gagaodok code task

1. Read `CODEX_HANDOFF.md`.
2. Run `scripts/resolve-gagaodok-worktree.sh --ensure`.
3. Use the returned path as the working directory for source edits, tests,
   builds, commits, and pushes.
4. Inspect that worktree's branch and dirty state before editing. Preserve
   unrelated and untracked files.

The current integration branch is `codex/obsidian-mentor-export`. Do not merge
it into another branch unless the user explicitly requests a merge.

## Android

- Android source is under `android/` in the resolved worktree.
- Use JDK 17. Do not infer Gradle's JVM from `java -version`; the repository
  scripts resolve and set `JAVA_HOME` explicitly.
- Prefer the root wrappers:
  - `scripts/verify-android.sh tablet`
  - `scripts/verify-android.sh phone`
  - `scripts/verify-android.sh all`
  - `scripts/build-tablet.sh`
  - `scripts/build-phone.sh`
- During implementation, run the narrowest relevant test. Run a release build
  once after the coherent change is complete when an APK is requested.
- A successful build does not prove S Pen behavior or UI quality. Verify the
  affected physical-device flow when feasible and report when it was not run.

## Scope

- macOS source: `Sources/KakaoSapiens/`
- Android source: `android/`
- Preserve `turnId` and `canonicalText` semantics when changing chat history.
- Tablet Obsidian export and Mac-tablet cloud sync are deferred unless the user
  explicitly resumes them.
- Keep credentials out of source, logs, binaries, URLs, and Git history.

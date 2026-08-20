# Gagaodok Handoff

Updated: 2026-08-20

## Where to work

Open `/Users/dlgksdnf/Desktop/ClaudeCode` in Codex. This root is a coordination
checkout, while current app work is on `codex/obsidian-mentor-export` in a Git
worktree. Resolve its current location with:

```bash
scripts/resolve-gagaodok-worktree.sh --ensure
```

Do not copy files between checkouts. Make app changes directly in the returned
worktree.

## Current integration state

- Branch: `codex/obsidian-mentor-export`
- Latest known commit: `ee6ed9d` (`fix: render stylus eraser strokes live`)
- Pull request: https://github.com/UHLUHLUHL/gagaodok/pull/1
- Root coordination branch at this update: `codex/mentor-plan-docs`

Always verify the local and remote branch heads because this document can age.

## Product boundaries

- macOS app: `Sources/KakaoSapiens/`
- Android app: `android/`
- Android flavors: `phone` and `tabletMentor`
- Tablet work currently includes the mentor layout, attachment menu, PDF/image
  input, floating handwriting panel, ink history, resizing, and stylus eraser.
- Tablet Obsidian export is deferred.
- Supabase Mac-tablet synchronization is documented for later implementation
  and is not part of the current tablet milestone.

## Standard verification

Run from the coordination root:

```bash
scripts/verify-android.sh tablet
scripts/build-tablet.sh
```

Use `phone` or `all` only when shared Android code or the phone flavor changed.
The wrappers select JDK 17 and operate on the active integration worktree.

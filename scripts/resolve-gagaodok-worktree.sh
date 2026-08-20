#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd -P)"
repo_root="$(git -C "$script_dir/.." rev-parse --show-toplevel)"
branch_name="codex/obsidian-mentor-export"
branch_ref="refs/heads/$branch_name"
ensure=false

if [[ "${1:-}" == "--ensure" ]]; then
  ensure=true
elif [[ $# -gt 0 ]]; then
  echo "usage: $0 [--ensure]" >&2
  exit 64
fi

if [[ -n "${GAGAODOK_WORKTREE:-}" && -x "$GAGAODOK_WORKTREE/android/gradlew" ]]; then
  printf '%s\n' "$GAGAODOK_WORKTREE"
  exit 0
fi

worktree="$({ git -C "$repo_root" worktree list --porcelain; printf '\n'; } | awk -v target="$branch_ref" '
  $1 == "worktree" { path = substr($0, 10) }
  $1 == "branch" && $2 == target && result == "" { result = path }
  END { if (result != "") print result }
')"

if [[ -n "$worktree" && -x "$worktree/android/gradlew" ]]; then
  printf '%s\n' "$worktree"
  exit 0
fi

if [[ "$ensure" == true ]]; then
  git -C "$repo_root" worktree prune
  persistent_path="$repo_root/.worktrees/obsidian-mentor-export"
  mkdir -p "$repo_root/.worktrees"
  git -C "$repo_root" worktree add "$persistent_path" "$branch_name" >&2
  printf '%s\n' "$persistent_path"
  exit 0
fi

echo "No active $branch_name worktree. Run $0 --ensure." >&2
exit 1

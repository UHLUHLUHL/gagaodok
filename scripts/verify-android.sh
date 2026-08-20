#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--help" ]]; then
  echo "usage: $0 [tablet|phone|all]"
  exit 0
fi

target="${1:-tablet}"
script_dir="$(cd "$(dirname "$0")" && pwd -P)"
worktree="$($script_dir/resolve-gagaodok-worktree.sh --ensure)"
java_home="$($script_dir/java17-home.sh)"

case "$target" in
  tablet) tasks=(":app:testTabletMentorDebugUnitTest") ;;
  phone) tasks=(":app:testPhoneDebugUnitTest") ;;
  all) tasks=(":app:testTabletMentorDebugUnitTest" ":app:testPhoneDebugUnitTest") ;;
  *) echo "usage: $0 [tablet|phone|all]" >&2; exit 64 ;;
esac

cd "$worktree/android"
JAVA_HOME="$java_home" ./gradlew "${tasks[@]}"

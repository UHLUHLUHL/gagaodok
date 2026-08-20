#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd -P)"
worktree="$($script_dir/resolve-gagaodok-worktree.sh --ensure)"
java_home="$($script_dir/java17-home.sh)"

cd "$worktree/android"
JAVA_HOME="$java_home" ./gradlew :app:assembleTabletMentorRelease
printf '%s\n' "$worktree/android/app/build/outputs/apk/tabletMentor/release/app-tabletMentor-release.apk"

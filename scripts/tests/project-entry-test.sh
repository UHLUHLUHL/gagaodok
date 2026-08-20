#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")/.." && pwd -P)"

worktree="$($script_dir/resolve-gagaodok-worktree.sh)"
test -x "$worktree/android/gradlew"

java_home="$($script_dir/java17-home.sh)"
test -x "$java_home/bin/java"
java_version="$("$java_home/bin/java" -version 2>&1)"
grep -Eq 'version "17\.' <<<"$java_version"

bash -n "$script_dir/verify-android.sh"
bash -n "$script_dir/build-tablet.sh"
bash -n "$script_dir/build-phone.sh"

help_output="$("$script_dir/verify-android.sh" --help)"
grep -q 'tablet|phone|all' <<<"$help_output"

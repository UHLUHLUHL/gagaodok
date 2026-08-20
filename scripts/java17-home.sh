#!/usr/bin/env bash
set -euo pipefail

is_java17() {
  [[ -x "$1/bin/java" ]] || return 1
  local version_output
  version_output="$("$1/bin/java" -version 2>&1)"
  grep -Eq 'version "17\.' <<<"$version_output"
}

candidates=(
  "${GAGAODOK_JAVA_HOME:-}"
  "${JAVA_HOME:-}"
  "/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home"
  "/Applications/Android Studio.app/Contents/jbr/Contents/Home"
)

for candidate in "${candidates[@]}"; do
  if [[ -n "$candidate" ]] && is_java17 "$candidate"; then
    printf '%s\n' "$candidate"
    exit 0
  fi
done

echo "JDK 17 was not found. Install openjdk@17 or set GAGAODOK_JAVA_HOME." >&2
exit 1

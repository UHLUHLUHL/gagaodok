#!/bin/bash
# Swift @main 테스트를 하나씩 컴파일·실행하고 결과를 집계한다.
#
# Package.swift에 test target이 없어 `swift test`를 쓸 수 없다. Tests/ 아래
# 파일은 각각 독립 실행파일이라 손으로 돌리면 "전부 통과"를 정직하게 셀 수 없다.
#
# Views와 App은 제외한다. `Bundle.module`이 SwiftPM이 만들어 주는 심볼이라
# 맨 swiftc로는 컴파일되지 않고, 앱의 @main이 테스트의 @main과 충돌한다.
# 뷰를 직접 여는 *WindowManager*도 같은 이유로 뺀다.
#
# 빌드에 실패한 테스트를 조용히 건너뛰지 않는다. FAILED로 세어 보고한다.
set -uo pipefail
cd "$(dirname "$0")/.."

# macOS의 bash 3.2에는 mapfile이 없다.
SOURCES=()
while IFS= read -r source; do
  SOURCES+=("$source")
done < <(
  find Sources/KakaoSapiens -name '*.swift' \
    ! -path '*/Views/*' ! -path '*/App/*' ! -name '*WindowManager*'
)

passed=0
build_failed=0
run_failed=0
failures=()

while IFS= read -r test; do
  name=$(basename "$test" .swift)
  binary="/tmp/swift-test-$name"
  if ! swiftc -parse-as-library "${SOURCES[@]}" "$test" -o "$binary" 2>"/tmp/$name.build.log"; then
    build_failed=$((build_failed + 1))
    failures+=("$name (build)")
    continue
  fi
  if "$binary" >"/tmp/$name.run.log" 2>&1; then
    passed=$((passed + 1))
  else
    run_failed=$((run_failed + 1))
    failures+=("$name (run)")
  fi
done < <(find Tests -name '*.swift' | sort)

total=$((passed + build_failed + run_failed))
echo "passed=$passed build_failed=$build_failed run_failed=$run_failed total=$total"
for failure in "${failures[@]:-}"; do
  [ -n "$failure" ] && echo "FAILED: $failure"
done
[ "$run_failed" -eq 0 ] && [ "$build_failed" -eq 0 ]

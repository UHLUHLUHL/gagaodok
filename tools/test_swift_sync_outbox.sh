#!/bin/sh
set -eu
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
binary_path="${TMPDIR:-/tmp}/gagaodok-sync-outbox-tests"
swiftc "$repo_root/Sources/KakaoSapiens/Services/SyncOutbox.swift" \
  "$repo_root/Tests/KakaoSapiensSyncOutboxTests/SyncOutboxTests.swift" -o "$binary_path"
"$binary_path"

client_binary_path="${TMPDIR:-/tmp}/gagaodok-sync-worker-client-tests"
swiftc \
  "$repo_root/Sources/KakaoSapiens/Services/SyncOutbox.swift" \
  "$repo_root/Sources/KakaoSapiens/Services/SyncWorkerClient.swift" \
  "$repo_root/Tests/KakaoSapiensSyncOutboxTests/SyncWorkerClientTests.swift" \
  -o "$client_binary_path"
"$client_binary_path"

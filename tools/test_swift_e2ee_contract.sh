#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
binary_path="${TMPDIR:-/tmp}/gagaodok-e2ee-contract-tests"

swiftc \
  "$repo_root/Sources/KakaoSapiens/Services/SyncE2EE.swift" \
  "$repo_root/Tests/KakaoSapiensE2EEContractTests/E2EEContractVectorTests.swift" \
  -o "$binary_path"
"$binary_path"

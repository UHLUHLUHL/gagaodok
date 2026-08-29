#!/bin/sh
# Standalone Swift tests for the sync coordinators.
#
# Compiled the same way as the other sync suites: the package has no test
# target, so each suite is an @main executable built with the sources it needs.
# Nothing here touches the Keychain, the network, or any conversation file.
set -eu
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
services="$repo_root/Sources/KakaoSapiens/Services"

onboarding_binary="${TMPDIR:-/tmp}/gagaodok-sync-onboarding-tests"
swiftc \
  "$services/SyncE2EE.swift" \
  "$services/SyncRecoveryMnemonic.swift" \
  "$services/SyncSecretStore.swift" \
  "$services/SyncEnrollmentBuilder.swift" \
  "$services/SyncConnectionState.swift" \
  "$services/SyncOutbox.swift" \
  "$services/SyncWorkerClient.swift" \
  "$services/SyncOnboardingCoordinator.swift" \
  "$repo_root/Tests/KakaoSapiensSyncOutboxTests/SyncOnboardingCoordinatorTests.swift" \
  -o "$onboarding_binary"
"$onboarding_binary"

pull_binary="${TMPDIR:-/tmp}/gagaodok-sync-pull-tests"
swiftc \
  "$services/SyncReplicaStore.swift" \
  "$services/SyncOutbox.swift" \
  "$services/SyncWorkerClient.swift" \
  "$services/SyncPullCoordinator.swift" \
  "$repo_root/Tests/KakaoSapiensSyncOutboxTests/SyncPullCoordinatorTests.swift" \
  -o "$pull_binary"
"$pull_binary"

model_binary="${TMPDIR:-/tmp}/gagaodok-sync-onboarding-model-tests"
swiftc \
  "$services/SyncE2EE.swift" \
  "$services/SyncRecoveryMnemonic.swift" \
  "$services/SyncSecretStore.swift" \
  "$services/SyncEnrollmentBuilder.swift" \
  "$services/SyncConnectionState.swift" \
  "$services/SyncReplicaStore.swift" \
  "$services/SyncOutbox.swift" \
  "$services/SyncWorkerClient.swift" \
  "$services/SyncOnboardingCoordinator.swift" \
  "$services/SyncPullCoordinator.swift" \
  "$services/SyncOnboardingModel.swift" \
  "$repo_root/Tests/KakaoSapiensSyncOutboxTests/SyncOnboardingModelTests.swift" \
  -o "$model_binary"
"$model_binary"

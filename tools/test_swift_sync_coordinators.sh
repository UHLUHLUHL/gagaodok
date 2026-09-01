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

pairing_binary="${TMPDIR:-/tmp}/gagaodok-sync-pairing-tests"
swiftc \
  "$services/SyncE2EE.swift" \
  "$services/SyncSecretStore.swift" \
  "$services/SyncConnectionState.swift" \
  "$services/SyncRecoveryMnemonic.swift" \
  "$services/SyncEnrollmentBuilder.swift" \
  "$services/SyncOnboardingCoordinator.swift" \
  "$services/SyncOutbox.swift" \
  "$services/SyncWorkerClient.swift" \
  "$services/SyncPairingPayload.swift" \
  "$services/SyncPairingClient.swift" \
  "$services/SyncPairingCoordinator.swift" \
  "$services/SyncPairingModel.swift" \
  "$services/SyncRecoveryEscrow.swift" \
  "$repo_root/Tests/KakaoSapiensSyncOutboxTests/SyncPairingTests.swift" \
  -o "$pairing_binary"
"$pairing_binary"

pairing_ui_binary="${TMPDIR:-/tmp}/gagaodok-sync-pairing-ui-tests"
swiftc \
  "$services/SyncE2EE.swift" \
  "$services/SyncSecretStore.swift" \
  "$services/SyncConnectionState.swift" \
  "$services/SyncRecoveryMnemonic.swift" \
  "$services/SyncEnrollmentBuilder.swift" \
  "$services/SyncOnboardingCoordinator.swift" \
  "$services/SyncOutbox.swift" \
  "$services/SyncWorkerClient.swift" \
  "$services/SyncPairingPayload.swift" \
  "$services/SyncPairingClient.swift" \
  "$services/SyncPairingCoordinator.swift" \
  "$services/SyncPairingModel.swift" \
  "$services/SyncPairingHostUIModel.swift" \
  "$repo_root/Sources/KakaoSapiens/Views/SyncPairingQRCodeView.swift" \
  "$repo_root/Tests/KakaoSapiensSyncOutboxTests/SyncPairingHostUIModelTests.swift" \
  -o "$pairing_ui_binary"
"$pairing_ui_binary"

transition_store_binary="${TMPDIR:-/tmp}/gagaodok-sync-transition-store-tests"
swiftc \
  "$services/SyncSecretStore.swift" \
  "$services/SyncAccountTransitionStore.swift" \
  "$repo_root/Tests/KakaoSapiensSyncOutboxTests/SyncAccountTransitionStoreTests.swift" \
  -o "$transition_store_binary"
"$transition_store_binary"

transition_coordinator_binary="${TMPDIR:-/tmp}/gagaodok-sync-transition-coordinator-tests"
swiftc \
  "$services/SyncSecretStore.swift" \
  "$services/SyncConnectionState.swift" \
  "$services/SyncOutbox.swift" \
  "$services/SyncAccountTransitionStore.swift" \
  "$services/SyncAccountTransitionModel.swift" \
  "$services/SyncAccountTransitionCoordinator.swift" \
  "$repo_root/Tests/KakaoSapiensSyncOutboxTests/SyncAccountTransitionCoordinatorTests.swift" \
  -o "$transition_coordinator_binary"
"$transition_coordinator_binary"

transition_model_binary="${TMPDIR:-/tmp}/gagaodok-sync-transition-model-tests"
swiftc \
  "$services/SyncAccountTransitionModel.swift" \
  "$repo_root/Tests/KakaoSapiensSyncOutboxTests/SyncAccountTransitionModelTests.swift" \
  -o "$transition_model_binary"
"$transition_model_binary"

device_list_binary="${TMPDIR:-/tmp}/gagaodok-sync-device-list-tests"
swiftc \
  "$services/SyncOutbox.swift" \
  "$services/SyncWorkerClient.swift" \
  "$services/SyncDeviceListModel.swift" \
  "$repo_root/Tests/KakaoSapiensSyncOutboxTests/SyncDeviceListModelTests.swift" \
  -o "$device_list_binary"
"$device_list_binary"

rotation_binary="${TMPDIR:-/tmp}/gagaodok-sync-recovery-rotation-tests"
swiftc \
  "$services/SyncE2EE.swift" \
  "$services/SyncRecoveryMnemonic.swift" \
  "$services/SyncRecoveryEscrow.swift" \
  "$services/SyncSecretStore.swift" \
  "$services/SyncOutbox.swift" \
  "$services/SyncWorkerClient.swift" \
  "$services/SyncRecoveryRotationBuilder.swift" \
  "$services/SyncRecoveryRotationCoordinator.swift" \
  "$repo_root/Tests/KakaoSapiensSyncOutboxTests/SyncRecoveryRotationCoordinatorTests.swift" \
  -o "$rotation_binary"
"$rotation_binary"

shadow_binary="${TMPDIR:-/tmp}/gagaodok-sync-shadow-importer-tests"
swiftc \
  "$services/SyncE2EE.swift" \
  "$services/SyncOutbox.swift" \
  "$services/SyncShadowImporter.swift" \
  "$repo_root/Tests/KakaoSapiensSyncOutboxTests/SyncShadowImporterTests.swift" \
  -o "$shadow_binary"
"$shadow_binary"

shadow_upload_binary="${TMPDIR:-/tmp}/gagaodok-sync-shadow-upload-tests"
swiftc \
  "$services/SyncE2EE.swift" \
  "$services/SyncSecretStore.swift" \
  "$services/SyncOutbox.swift" \
  "$services/SyncWorkerClient.swift" \
  "$services/SyncShadowImporter.swift" \
  "$services/SyncShadowUploadCoordinator.swift" \
  "$repo_root/Tests/KakaoSapiensSyncOutboxTests/SyncShadowUploadCoordinatorTests.swift" \
  -o "$shadow_upload_binary"
"$shadow_upload_binary"

shadow_reader_binary="${TMPDIR:-/tmp}/gagaodok-sync-shadow-reader-tests"
swiftc \
  "$services/SyncE2EE.swift" \
  "$services/SyncSecretStore.swift" \
  "$services/SyncOutbox.swift" \
  "$services/SyncWorkerClient.swift" \
  "$services/SyncShadowReader.swift" \
  "$repo_root/Tests/KakaoSapiensSyncOutboxTests/SyncShadowReaderTests.swift" \
  -o "$shadow_reader_binary"
"$shadow_reader_binary"

remote_room_binary="${TMPDIR:-/tmp}/gagaodok-sync-remote-room-tests"
swiftc \
  "$services/SyncE2EE.swift" \
  "$services/SyncReplicaStore.swift" \
  "$services/SyncRemoteRoomTypes.swift" \
  "$services/SyncRemoteRoomAssembler.swift" \
  "$services/SyncRemoteRoomRepository.swift" \
  "$repo_root/Tests/KakaoSapiensSyncOutboxTests/SyncRemoteRoomAssemblerTests.swift" \
  -o "$remote_room_binary"
"$remote_room_binary"

exposure_binary="${TMPDIR:-/tmp}/gagaodok-sync-room-exposure-tests"
swiftc \
  "$services/SyncRemoteRoomTypes.swift" \
  "$services/SyncRemoteRoomRepository.swift" \
  "$services/SyncRoomExposurePolicy.swift" \
  "$repo_root/Tests/KakaoSapiensSyncOutboxTests/SyncRoomExposurePolicyTests.swift" \
  -o "$exposure_binary"
"$exposure_binary"

remote_reply_journal_binary="${TMPDIR:-/tmp}/gagaodok-sync-remote-reply-journal-tests"
swiftc \
  "$services/SyncRemoteRoomTypes.swift" \
  "$services/SyncRemoteReplyJournal.swift" \
  "$repo_root/Tests/KakaoSapiensSyncOutboxTests/SyncRemoteReplyJournalTests.swift" \
  -o "$remote_reply_journal_binary"
"$remote_reply_journal_binary"

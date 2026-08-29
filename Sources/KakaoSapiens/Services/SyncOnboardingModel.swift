import Combine
import Foundation

/// The state a synthetic-account sync screen can be in, and the only way to
/// move between those states.
///
/// The screen itself does nothing. Opening it reads stored status and stops;
/// every transition that sends a request, stores a secret or writes the replica
/// is behind a method a button has to call. That is the whole point of putting
/// the state here rather than in the view: an accidental `onAppear` cannot
/// enroll a device.
///
/// Nothing in this file touches `ChatRoomManager`, `ChatStore` or any
/// conversation file. The only thing a successful pull writes is the opaque
/// shadow replica.

public enum SyncOnboardingUIState: Equatable {
    /// Nothing is linked. The screen offers to start, and offers nothing else.
    case disconnected
    /// Building the enrollment locally. No request has been sent.
    case preparing
    /// The recovery phrase is on screen and must be confirmed before sending.
    case awaitingPhraseConfirmation
    /// The enrollment request is in flight.
    case enrolling
    /// Linked, and deliberately not synchronising.
    case connectedSyncOff
    /// Walking the synthetic snapshot, one page per press.
    case bootstrapping(appliedItems: Int)
    /// The shadow replica holds the synthetic snapshot.
    case replicaReady(entryCount: Int)
    /// Secrets and endpoint state disagree. No key is generated to repair it.
    case relinkRequired
    /// Something failed and the same action can be tried again.
    case retryableError(SyncOnboardingUIError)
}

/// A failure the screen can describe without describing anything sensitive.
///
/// There is no associated endpoint, token, phrase, ciphertext or server
/// message: a case name is all the screen ever shows, and all a log would get.
public enum SyncOnboardingUIError: String, Equatable {
    case phraseNotConfirmed
    case enrollmentRefused
    case enrollmentRefusedRetryPending
    case storageFailed
    case networkFailed
    case bootstrapFailed
    case notConnected
}

/// What the screen may offer right now.
///
/// Derived from the state rather than decided in the view, so a button cannot
/// exist in a state its action would be unsafe in.
public struct SyncOnboardingActions: Equatable {
    public let canBeginConnection: Bool
    public let canConfirmPhrase: Bool
    public let canRetryEnrollment: Bool
    public let canAdvanceBootstrap: Bool
    public let canRequestDisconnect: Bool
}

@MainActor
public final class SyncOnboardingModel: ObservableObject {
    @Published public private(set) var state: SyncOnboardingUIState = .disconnected
    /// Shown exactly once, held only in memory, and cleared the moment the user
    /// confirms. It is never written to a file, a setting or a log.
    @Published public private(set) var recoveryPhrase: String?
    /// A confirmation sheet only. Nothing is deleted in this build.
    @Published public private(set) var disconnectConfirmationVisible = false

    private let onboarding: SyncOnboardingCoordinator
    private let pull: SyncPullCoordinator
    private let replica: SyncReplicaStore
    private let identity: () -> (accountID: String, deviceID: String, enrollmentID: String)
    private let spaceID: String
    private let platform: String
    private var draft: SyncOnboardingDraft?

    public init(
        onboarding: SyncOnboardingCoordinator,
        pull: SyncPullCoordinator,
        replica: SyncReplicaStore,
        spaceID: String,
        platform: String,
        identity: @escaping () -> (accountID: String, deviceID: String, enrollmentID: String)
    ) {
        self.onboarding = onboarding
        self.pull = pull
        self.replica = replica
        self.spaceID = spaceID
        self.platform = platform
        self.identity = identity
    }

    public var actions: SyncOnboardingActions {
        switch state {
        case .disconnected, .retryableError(.enrollmentRefused):
            return SyncOnboardingActions(
                canBeginConnection: true, canConfirmPhrase: false, canRetryEnrollment: false,
                canAdvanceBootstrap: false, canRequestDisconnect: false
            )
        case .awaitingPhraseConfirmation:
            return SyncOnboardingActions(
                canBeginConnection: false, canConfirmPhrase: true, canRetryEnrollment: false,
                canAdvanceBootstrap: false, canRequestDisconnect: false
            )
        case .retryableError(.enrollmentRefusedRetryPending), .retryableError(.networkFailed):
            // The journal holds the exact bytes, so the only safe offer is to
            // send those again — never to build a fresh enrollment.
            return SyncOnboardingActions(
                canBeginConnection: false, canConfirmPhrase: false, canRetryEnrollment: true,
                canAdvanceBootstrap: false, canRequestDisconnect: false
            )
        case .connectedSyncOff, .bootstrapping, .retryableError(.bootstrapFailed):
            return SyncOnboardingActions(
                canBeginConnection: false, canConfirmPhrase: false, canRetryEnrollment: false,
                canAdvanceBootstrap: true, canRequestDisconnect: true
            )
        case .replicaReady:
            return SyncOnboardingActions(
                canBeginConnection: false, canConfirmPhrase: false, canRetryEnrollment: false,
                canAdvanceBootstrap: false, canRequestDisconnect: true
            )
        default:
            return SyncOnboardingActions(
                canBeginConnection: false, canConfirmPhrase: false, canRetryEnrollment: false,
                canAdvanceBootstrap: false, canRequestDisconnect: false
            )
        }
    }

    /// Read stored status. Sends nothing, stores nothing, writes nothing.
    ///
    /// This is what the screen calls when it appears, and it is deliberately
    /// the only thing that runs without a press.
    public func refresh() async {
        switch onboarding.status() {
        case .disconnected:
            state = .disconnected
        case .relinkRequired:
            // A half-finished link is reported, never repaired. Generating a
            // replacement key here would silently orphan the account the
            // existing half belongs to.
            state = .relinkRequired
        case .connected:
            let progress = await pull.progress()
            let entries = (try? replica.snapshot().count) ?? 0
            if progress.bootstrapComplete && entries > 0 {
                state = .replicaReady(entryCount: entries)
            } else if progress.snapshotWatermark != nil {
                state = .bootstrapping(appliedItems: entries)
            } else {
                state = .connectedSyncOff
            }
        }
    }

    /// Build the enrollment and show the phrase. Still sends nothing.
    public func beginConnection() async {
        guard actions.canBeginConnection else { return }
        state = .preparing
        let ids = identity()
        do {
            let prepared = try onboarding.prepare(
                accountID: ids.accountID,
                deviceID: ids.deviceID,
                enrollmentID: ids.enrollmentID,
                spaceID: spaceID,
                platform: platform
            )
            draft = prepared
            recoveryPhrase = prepared.recoveryPhrase
            state = .awaitingPhraseConfirmation
        } catch SyncOnboardingError.relinkRequired {
            state = .relinkRequired
        } catch {
            state = .retryableError(.storageFailed)
        }
    }

    /// The user says the phrase is written down. Only now is anything sent.
    public func confirmPhraseSaved() async {
        guard actions.canConfirmPhrase, let draft else { return }
        state = .enrolling
        do {
            _ = try await onboarding.confirm(draft, confirmedPhrase: draft.recoveryPhrase)
            // The phrase leaves memory the moment it is no longer needed.
            recoveryPhrase = nil
            self.draft = nil
            state = .connectedSyncOff
        } catch SyncOnboardingError.phraseNotConfirmed {
            state = .retryableError(.phraseNotConfirmed)
        } catch SyncOnboardingError.enrollmentRejected {
            // The journal kept the bytes, so the retry is a replay rather than
            // a second enrollment for the same account.
            recoveryPhrase = nil
            state = .retryableError(.enrollmentRefusedRetryPending)
        } catch {
            recoveryPhrase = nil
            state = .retryableError(.networkFailed)
        }
    }

    /// Resend the staged bytes. Never rebuilds the request.
    public func retryEnrollment() async {
        guard actions.canRetryEnrollment, let secrets = draft?.package.secrets else {
            state = .retryableError(.storageFailed)
            return
        }
        state = .enrolling
        do {
            _ = try await onboarding.retryPendingEnrollment(secrets: secrets)
            self.draft = nil
            state = .connectedSyncOff
        } catch SyncOnboardingError.enrollmentRejected {
            state = .retryableError(.enrollmentRefusedRetryPending)
        } catch {
            state = .retryableError(.networkFailed)
        }
    }

    /// Walk one page of the synthetic snapshot into the shadow replica.
    public func advanceBootstrap() async {
        guard actions.canAdvanceBootstrap else { return }
        do {
            let progress = try await pull.advanceBootstrap()
            let entries = (try? replica.snapshot().count) ?? 0
            state = progress.bootstrapComplete
                ? .replicaReady(entryCount: entries)
                : .bootstrapping(appliedItems: entries)
        } catch {
            // A refused page left the cursor where it was, so the same page is
            // fetched again rather than skipped.
            state = .retryableError(.bootstrapFailed)
        }
    }

    /// Show the confirmation only. Nothing is deleted in this build.
    public func requestDisconnect() {
        guard actions.canRequestDisconnect else { return }
        disconnectConfirmationVisible = true
    }

    public func dismissDisconnect() {
        disconnectConfirmationVisible = false
    }
}

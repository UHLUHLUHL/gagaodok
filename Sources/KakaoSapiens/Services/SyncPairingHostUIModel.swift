import Combine
import Foundation

protocol SyncPairingHostServicing: Sendable {
    func openSession(accountID: String, baseURL: URL) async throws -> SyncPairingPayload
    func pollCandidates() async throws -> [SyncPairingCandidate]
    func approve(_ candidate: SyncPairingCandidate, sasConfirmed: Bool) async throws
}

extension SyncPairingHostCoordinator: SyncPairingHostServicing {}

/// State owner for the host half of the pairing settings card.
///
/// The view never calls the pairing service directly. In particular, it cannot
/// approve a candidate unless this model still holds the candidate whose SAS is
/// on screen.
@MainActor
final class SyncPairingHostUIModel: ObservableObject {
    @Published private(set) var state: SyncPairingHostState = .idle
    @Published private(set) var qrText: String?

    var actions: SyncPairingActions { .forHost(state) }

    private let service: SyncPairingHostServicing
    private var candidate: SyncPairingCandidate?
    private var busy = false

    init(service: SyncPairingHostServicing) {
        self.service = service
    }

    func openSession(accountID: String, baseURL: URL) async {
        guard !busy, actions.canOpenSession else { return }
        busy = true
        defer { busy = false }
        do {
            let payload = try await service.openSession(accountID: accountID, baseURL: baseURL)
            qrText = payload.encodedText()
            candidate = nil
            state = .sessionReady
        } catch {
            apply(error)
        }
    }

    func poll() async {
        guard !busy, actions.canPoll else { return }
        busy = true
        defer { busy = false }
        do {
            let candidates = try await service.pollCandidates()
            guard let first = candidates.first else {
                state = .waitingClaim
                return
            }
            candidate = first
            state = .verifySAS(first.shortAuthenticationString)
        } catch {
            apply(error)
        }
    }

    func approve(confirmed: Bool) async {
        guard confirmed, !busy, actions.canApprove, let candidate else { return }
        busy = true
        state = .approving
        defer { busy = false }
        do {
            try await service.approve(candidate, sasConfirmed: true)
            self.candidate = nil
            qrText = nil
            state = .completed
        } catch {
            apply(error)
        }
    }

    func reset() {
        guard !busy else { return }
        candidate = nil
        qrText = nil
        state = .idle
    }

    private func apply(_ error: Error) {
        candidate = nil
        qrText = nil
        if let pairing = error as? SyncPairingError {
            state = pairing == .sessionExpired ? .expired : .error(pairing)
        } else {
            state = .error(.transport)
        }
    }
}

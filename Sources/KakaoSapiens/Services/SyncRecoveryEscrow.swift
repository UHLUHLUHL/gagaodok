import Foundation

/// Letting the user see the recovery phrase again, for a while.
///
/// Three real-device runs produced three accounts whose phrase nobody wrote
/// down. The screen shows it once and moves on, which turns out not to be
/// enough. This is the contract for the agreed remedy; the storage, the
/// owner-authentication prompt and the expiry sweep come next.
///
/// What is kept is the sixteen bytes of recovery entropy, never the words. The
/// phrase is regenerated from the entropy each time it is shown, so between
/// viewings the phrase exists nowhere.
public protocol SyncRecoveryEscrow {
    /// Store entropy for a newly enrolled account. Overwriting an existing
    /// entry is refused: two accounts would then share one escrow slot and the
    /// older account's phrase would be silently unreachable.
    func stash(entropy: Data, accountID: String, at: Date) throws

    /// The entropy, if it is still within the window.
    ///
    /// Implementations require device-owner authentication on every call, and
    /// return `nil` rather than an error when the window has closed — an
    /// expired escrow is a normal end state, not a fault.
    func reveal(accountID: String, now: Date, authenticate: () throws -> Bool) throws -> Data?

    /// Drop the entropy: the user says it is written down, or time ran out.
    /// The connection survives — the master key lives elsewhere. What is lost
    /// is only the ability to look again.
    func discard(accountID: String) throws
}

public enum SyncRecoveryEscrowError: Error, Equatable {
    case alreadyStashed
    case invalidEntropy
    case notAuthenticated
    case storageFailed
}

public enum SyncRecoveryEscrowPolicy {
    /// Sixteen bytes: BIP-39 twelve words. Anything else is not our phrase.
    public static let entropyLength = 16

    /// Seven days from enrollment, as agreed.
    public static let window: TimeInterval = 7 * 24 * 60 * 60

    public static func isWithinWindow(stashedAt: Date, now: Date) -> Bool {
        now >= stashedAt && now.timeIntervalSince(stashedAt) < window
    }

    /// Whether a phrase may be produced at all.
    ///
    /// Deliberately not "generate one if none is stored". A device with no
    /// entropy has nothing to show, and inventing a fresh phrase there would
    /// silently orphan whatever account the old phrase belonged to.
    public static func mayReveal(hasEntropy: Bool, stashedAt: Date?, now: Date) -> Bool {
        guard hasEntropy, let stashedAt else { return false }
        return isWithinWindow(stashedAt: stashedAt, now: now)
    }
}

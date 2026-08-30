package com.sapiens.gagaodok.sync

/**
 * Letting the user see the recovery phrase again, for a while.
 *
 * Three real-device runs produced three accounts whose phrase nobody wrote
 * down. The screen shows it once and moves on, which turns out not to be
 * enough. This is the contract for the agreed remedy; the storage, the
 * owner-authentication prompt and the expiry sweep come next.
 *
 * What is kept is the sixteen bytes of recovery entropy, never the words. The
 * phrase is regenerated from the entropy each time it is shown, so between
 * viewings the phrase exists nowhere.
 */
interface SyncRecoveryEscrow {
    /**
     * Store entropy for a newly enrolled account. Overwriting an existing entry
     * is refused: two accounts would then share one escrow slot and the older
     * account's phrase would be silently unreachable.
     */
    fun stash(entropy: ByteArray, accountId: String, atEpochMillis: Long)

    /**
     * The entropy, if it is still within the window.
     *
     * Implementations require device-owner authentication on every call, and
     * return null rather than failing when the window has closed — an expired
     * escrow is a normal end state, not a fault.
     */
    fun reveal(accountId: String, nowEpochMillis: Long, authenticate: () -> Boolean): ByteArray?

    /**
     * Drop the entropy: the user says it is written down, or time ran out. The
     * connection survives — the master key lives elsewhere. What is lost is only
     * the ability to look again.
     */
    fun discard(accountId: String)
}

class SyncRecoveryEscrowException(val reason: Reason) : Exception() {
    enum class Reason { ALREADY_STASHED, INVALID_ENTROPY, NOT_AUTHENTICATED, STORAGE_FAILED }
}

object SyncRecoveryEscrowPolicy {
    /** Sixteen bytes: BIP-39 twelve words. Anything else is not our phrase. */
    const val ENTROPY_LENGTH = 16

    /** Seven days from enrollment, as agreed. */
    const val WINDOW_MILLIS = 7L * 24 * 60 * 60 * 1000

    fun isWithinWindow(stashedAt: Long, now: Long): Boolean =
        now >= stashedAt && now - stashedAt < WINDOW_MILLIS

    /**
     * Whether a phrase may be produced at all.
     *
     * Deliberately not "generate one if none is stored". A device with no
     * entropy has nothing to show, and inventing a fresh phrase there would
     * silently orphan whatever account the old phrase belonged to.
     */
    fun mayReveal(hasEntropy: Boolean, stashedAt: Long?, now: Long): Boolean =
        hasEntropy && stashedAt != null && isWithinWindow(stashedAt, now)
}

import Foundation

/// Walking the server's two read paths into the opaque replica.
///
/// Bootstrap first, one page at a time, then the account cursor starting at the
/// watermark that bootstrap fixed. That order is not a preference: a cursor
/// started anywhere else would either skip writes that landed behind the
/// snapshot or replay ones already inside it.
///
/// The replica is the only thing this writes. It has no reference to
/// `ChatRoom`, `ChatStore` or any conversation file, and nothing here decrypts
/// a projection — the entries stay opaque until a separate, later decision
/// connects them to real data.
///
/// An actor rather than a lock: every step awaits the network, and serialising
/// that with a mutex would mean blocking a cooperative thread for a round trip.

public enum SyncPullError: Error {
    /// Bootstrap has not finished, so there is no watermark to pull from.
    case bootstrapIncomplete
    /// The response was not the envelope this protocol version defines.
    case malformedEnvelope
    case httpStatus(Int)
}

public struct SyncPullProgress: Equatable {
    public let bootstrapComplete: Bool
    /// The cursor for the next bootstrap page, or nil when there is none left.
    public let bootstrapCursor: String?
    /// The snapshot ceiling bootstrap fixed, which is where changes begins.
    public let snapshotWatermark: UInt64?
    /// How far the account cursor has been scanned.
    public let changesCursor: UInt64?
    public let appliedItems: Int
    public let hasMore: Bool
}

/// Where the walk has got to. Kept beside the replica rather than inside the
/// connection state, which is versioned and owned elsewhere.
struct SyncPullState: Codable, Equatable {
    var bootstrapComplete: Bool = false
    var bootstrapCursor: String?
    var snapshotWatermark: UInt64?
    var changesCursor: UInt64?
}

public actor SyncPullCoordinator {
    private let client: SyncWorkerClient
    private let replica: SyncReplicaStore
    private let stateURL: URL

    public init(client: SyncWorkerClient, replica: SyncReplicaStore, stateURL: URL) {
        self.client = client
        self.replica = replica
        self.stateURL = stateURL
    }

    public func progress() -> SyncPullProgress {
        let state = loadState()
        return SyncPullProgress(
            bootstrapComplete: state.bootstrapComplete,
            bootstrapCursor: state.bootstrapCursor,
            snapshotWatermark: state.snapshotWatermark,
            changesCursor: state.changesCursor,
            appliedItems: 0,
            hasMore: !state.bootstrapComplete
        )
    }

    /// Fetch and apply one bootstrap page.
    ///
    /// The page is applied before the cursor moves. A page that fails to parse
    /// or fails to apply leaves both the replica and the cursor exactly as they
    /// were, so the same page is fetched again rather than skipped.
    @discardableResult
    public func advanceBootstrap() async throws -> SyncPullProgress {
        var state = loadState()
        if state.bootstrapComplete {
            return SyncPullProgress(
                bootstrapComplete: true,
                bootstrapCursor: nil,
                snapshotWatermark: state.snapshotWatermark,
                changesCursor: state.changesCursor,
                appliedItems: 0,
                hasMore: false
            )
        }

        let response = try await Self.fetch { try await self.client.bootstrap(cursor: state.bootstrapCursor) }
        let result = try Self.result(in: response.body, requiring: [
            "snapshot_high_watermark_seq", "has_more", "next_cursor", "items",
        ])
        guard let watermark = Self.sequence(result["snapshot_high_watermark_seq"]),
              let hasMore = result["has_more"] as? Bool,
              let items = result["items"] as? [[String: Any]] else {
            throw SyncPullError.malformedEnvelope
        }
        let nextCursor = try Self.cursor(result["next_cursor"], hasMore: hasMore)

        // A snapshot that moved between pages is not a snapshot. The server
        // carries the watermark inside the cursor precisely so it cannot, and a
        // different one here means this page belongs to some other walk.
        if let known = state.snapshotWatermark, known != watermark {
            throw SyncPullError.malformedEnvelope
        }

        try replica.apply(itemsJSON: try JSONSerialization.data(withJSONObject: items))

        state.snapshotWatermark = watermark
        state.bootstrapCursor = nextCursor
        state.bootstrapComplete = !hasMore
        if state.bootstrapComplete {
            // The account cursor starts exactly where the snapshot stopped, so
            // a write that landed behind the walk is picked up rather than lost.
            state.changesCursor = state.changesCursor ?? watermark
        }
        try saveState(state)

        return SyncPullProgress(
            bootstrapComplete: state.bootstrapComplete,
            bootstrapCursor: state.bootstrapCursor,
            snapshotWatermark: watermark,
            changesCursor: state.changesCursor,
            appliedItems: items.count,
            hasMore: hasMore
        )
    }

    /// Fetch and apply one changes page.
    ///
    /// Applying the same page twice is harmless: every change carries the
    /// current projection for its identity and the replica keys on identity, so
    /// a device that crashed mid-page converges on re-application.
    @discardableResult
    public func advanceChanges() async throws -> SyncPullProgress {
        var state = loadState()
        guard state.bootstrapComplete, let from = state.changesCursor else {
            throw SyncPullError.bootstrapIncomplete
        }

        let response = try await Self.fetch { try await self.client.changes(after: from) }
        let result = try Self.result(in: response.body, requiring: [
            "scanned_through_seq", "account_high_watermark_seq", "has_more", "changes",
        ])
        guard let scanned = Self.sequence(result["scanned_through_seq"]),
              let hasMore = result["has_more"] as? Bool,
              let changes = result["changes"] as? [[String: Any]] else {
            throw SyncPullError.malformedEnvelope
        }
        // A cursor that went backwards would replay applied work and could loop.
        guard scanned >= from else { throw SyncPullError.malformedEnvelope }

        let items = try changes.map { change -> [String: Any] in
            guard Set(change.keys) == [
                "change_seq", "entity_type", "change_kind", "revision", "identity", "projection",
            ],
            let entityType = change["entity_type"],
            let identity = change["identity"],
            let projection = change["projection"] else {
                throw SyncPullError.malformedEnvelope
            }
            return ["entity_type": entityType, "identity": identity, "projection": projection]
        }
        // One page, one apply. A page the replica refuses leaves the cursor
        // where it was, so nothing is silently skipped.
        try replica.apply(itemsJSON: try JSONSerialization.data(withJSONObject: items))

        state.changesCursor = scanned
        try saveState(state)

        return SyncPullProgress(
            bootstrapComplete: true,
            bootstrapCursor: nil,
            snapshotWatermark: state.snapshotWatermark,
            changesCursor: scanned,
            appliedItems: items.count,
            hasMore: hasMore
        )
    }

    /// Run one client call and present its failures on this actor's surface.
    ///
    /// The client already refuses a non-2xx response, so the status is mapped
    /// rather than re-checked. A caller of this coordinator should only ever
    /// have to handle `SyncPullError`.
    private static func fetch(
        _ work: () async throws -> SyncHTTPResponse
    ) async throws -> SyncHTTPResponse {
        do {
            return try await work()
        } catch SyncWorkerClientError.httpStatus(let status) {
            throw SyncPullError.httpStatus(status)
        }
    }

    // MARK: - Envelope

    /// The `result` object, with the envelope and its keys checked exactly.
    ///
    /// An unexpected key means the server is speaking a protocol this build
    /// does not know. Ignoring it and reading the fields that happen to match is
    /// how a client silently mis-applies a newer wire format.
    private static func result(in body: Data, requiring keys: Set<String>) throws -> [String: Any] {
        guard body.count <= 8_000_000,
              let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              Set(root.keys) == ["protocol_version", "request_id", "result"],
              root["protocol_version"] as? Int == 1,
              let requestID = root["request_id"] as? String, !requestID.isEmpty,
              let result = root["result"] as? [String: Any],
              Set(result.keys) == keys else {
            throw SyncPullError.malformedEnvelope
        }
        return result
    }

    private static func sequence(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber else { return nil }
        let raw = number.int64Value
        guard raw >= 0, Double(raw) == number.doubleValue else { return nil }
        return UInt64(raw)
    }

    /// `next_cursor` is a token when there is more and null when there is not.
    /// Any other combination is a page this client will not act on.
    private static func cursor(_ value: Any?, hasMore: Bool) throws -> String? {
        if hasMore {
            guard let token = value as? String, !token.isEmpty, token.count <= 4_096 else {
                throw SyncPullError.malformedEnvelope
            }
            return token
        }
        guard value == nil || value is NSNull else { throw SyncPullError.malformedEnvelope }
        return nil
    }

    // MARK: - State

    private func loadState() -> SyncPullState {
        guard FileManager.default.fileExists(atPath: stateURL.path),
              let data = try? Data(contentsOf: stateURL),
              let state = try? JSONDecoder().decode(SyncPullState.self, from: data) else {
            // Unreadable progress is restarted rather than guessed at: a wrong
            // cursor would skip pages, and a full re-walk is only slow.
            return SyncPullState()
        }
        return state
    }

    private func saveState(_ state: SyncPullState) throws {
        try FileManager.default.createDirectory(
            at: stateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(state)
            .write(to: stateURL, options: [.atomic, .completeFileProtectionUnlessOpen])
    }
}

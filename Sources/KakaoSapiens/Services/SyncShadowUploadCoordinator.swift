import Foundation

/// The result of one shadow pass, in numbers.
public struct SyncShadowUploadReport: Equatable {
    public let importBatchID: String
    public let localTurnCount: Int
    public let localBubbleCount: Int
    public let localContentHash: String
    public let uploadedOperations: Int
    /// Rows the server says it holds for this room, counted from the pulled
    /// projection rather than trusted from the upload's own responses.
    public let remoteTurnCount: Int
    public let remoteBubbleCount: Int
    /// Bubbles skipped because they carry an attachment this pass does not copy.
    public let skippedAttachments: Int

    public var matches: Bool {
        localTurnCount == remoteTurnCount && localBubbleCount == remoteBubbleCount
    }
}

public enum SyncShadowUploadError: Error, Equatable {
    case secretsUnavailable
    case roomNotFound
    case unreadableStorage
    case uploadFailed(Int)
    case transport
    case projectionUnreadable
}

/// One-way copy of a designated room into the encrypted shadow.
///
/// Read-only on the way in. The room list and the message file are opened for
/// reading and never written, and nothing the Worker returns is applied back to
/// them — the shadow is a projection no conversation screen consults. A failed
/// pass therefore costs a retry and nothing else.
///
/// Attachments are not copied in this pass. A bubble that carries one is still
/// copied as text, and the count of those is reported rather than hidden, so
/// "the counts matched" cannot quietly mean "the images were dropped".
@MainActor
public final class SyncShadowUploadCoordinator {
    private let directory: URL
    private let accountID: String
    private let deviceID: String
    private let client: SyncWorkerClient
    private let outbox: SyncOutbox
    private let loadSecrets: () -> SyncSecretLoadResult

    public init(
        directory: URL,
        accountID: String,
        deviceID: String,
        client: SyncWorkerClient,
        outbox: SyncOutbox,
        loadSecrets: @escaping () -> SyncSecretLoadResult = { SyncSecretStore.load() }
    ) {
        self.directory = directory
        self.accountID = accountID
        self.deviceID = deviceID
        self.client = client
        self.outbox = outbox
        self.loadSecrets = loadSecrets
    }

    /// Import the room, drain the outbox, then read the projection back.
    ///
    /// The comparison deliberately re-reads from `/v1/sync/changes` instead of
    /// counting the accepted uploads. A response that said "applied" proves the
    /// request was taken, not that a later device can see the row.
    public func run(roomID: UUID, storageDirectory: URL) async throws -> SyncShadowUploadReport {
        guard case .available(let secrets) = loadSecrets() else {
            throw SyncShadowUploadError.secretsUnavailable
        }
        let (input, skipped) = try Self.readRoom(roomID: roomID, from: storageDirectory)

        let importer = SyncShadowImporter(
            accountID: accountID,
            deviceID: deviceID,
            masterKey: secrets.accountMasterKey
        )
        let manifest = try importer.importRooms([input], into: outbox)

        var uploaded = 0
        while true {
            do {
                guard try await client.drainOne(from: outbox) != nil else { break }
                uploaded += 1
            } catch SyncWorkerClientError.httpStatus(let status) {
                // The journal keeps the original bytes, so the pass can be
                // resumed rather than rebuilt.
                throw SyncShadowUploadError.uploadFailed(status)
            } catch {
                throw SyncShadowUploadError.transport
            }
        }

        let projection = try await readProjection(roomID: roomID.uuidString.uppercased())
        let room = manifest.rooms[0]
        return SyncShadowUploadReport(
            importBatchID: manifest.importBatchID,
            localTurnCount: room.turnCount,
            localBubbleCount: room.bubbleCount,
            localContentHash: room.contentHash,
            uploadedOperations: uploaded,
            remoteTurnCount: projection.turns,
            remoteBubbleCount: projection.bubbles,
            skippedAttachments: skipped
        )
    }

    // MARK: - Local read

    /// Read the designated room. Both files are opened read-only and closed
    /// again; no field of the original is modified.
    static func readRoom(roomID: UUID, from directory: URL) throws -> (SyncShadowRoomInput, Int) {
        let listURL = directory.appendingPathComponent("rooms_list.json")
        let messagesURL = directory
            .appendingPathComponent("room_\(roomID.uuidString)_messages.json")
        guard
            let listData = try? Data(contentsOf: listURL),
            let rooms = try? JSONSerialization.jsonObject(with: listData) as? [[String: Any]]
        else {
            throw SyncShadowUploadError.unreadableStorage
        }
        guard let row = rooms.first(where: {
            ($0["id"] as? String)?.uppercased() == roomID.uuidString.uppercased()
        }) else {
            throw SyncShadowUploadError.roomNotFound
        }
        guard
            let messageData = try? Data(contentsOf: messagesURL),
            let messages = try? JSONSerialization.jsonObject(with: messageData) as? [[String: Any]]
        else {
            throw SyncShadowUploadError.unreadableStorage
        }

        var bubbles: [SyncShadowRoomInput.Bubble] = []
        var skipped = 0
        for message in messages {
            guard
                let rawID = message["id"] as? String, let messageID = UUID(uuidString: rawID),
                let sender = message["sender"] as? String,
                let text = message["text"] as? String,
                let seconds = message["timestamp"] as? Double
            else {
                // A row this importer cannot describe is left behind rather
                // than guessed at. It stays in local storage untouched.
                continue
            }
            if message["attachment"] is [String: Any] { skipped += 1 }
            // A message with no turn of its own is its own turn: inventing a
            // shared one would merge unrelated exchanges on the other device.
            let turnID = (message["turnId"] as? String).flatMap(UUID.init(uuidString:)) ?? messageID
            bubbles.append(
                SyncShadowRoomInput.Bubble(
                    messageID: messageID,
                    turnID: turnID,
                    sender: sender,
                    // The local model leaves `kind` absent for ordinary speech.
                    kind: (message["kind"] as? String) ?? "speech",
                    text: text,
                    timestamp: Date(timeIntervalSince1970: seconds)
                )
            )
        }
        return (
            SyncShadowRoomInput(
                roomID: roomID,
                title: (row["title"] as? String) ?? "",
                bubbles: bubbles,
                // Only a local companion room is explicitly eligible. Missing
                // legacy metadata remains read-only rather than being guessed.
                continuationCapability: (row["modeIdentifier"] as? String) == "companion"
            ),
            skipped
        )
    }

    // MARK: - Remote projection

    private struct Projection { let turns: Int; let bubbles: Int }

    /// Count what the server will actually hand a second device.
    ///
    /// Only entity type and identity are read. No envelope is decrypted here:
    /// the question is whether the rows arrived, not what they say.
    private func readProjection(roomID: String) async throws -> Projection {
        var turns: Set<String> = []
        var bubbles: Set<String> = []
        var after: UInt64 = 0
        while true {
            let response: SyncHTTPResponse
            do {
                response = try await client.changes(after: after, limit: 300)
            } catch {
                throw SyncShadowUploadError.transport
            }
            guard
                let root = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
                let result = root["result"] as? [String: Any],
                let rows = result["changes"] as? [[String: Any]]
            else {
                throw SyncShadowUploadError.projectionUnreadable
            }
            for row in rows {
                if let sequence = row["change_seq"] as? Int, sequence > 0 {
                    after = max(after, UInt64(sequence))
                }
                // Identity, not a target: the change feed names a row by its
                // canonical primary key.
                guard let identity = row["identity"] as? [String: Any],
                      (identity["room_id"] as? String)?.uppercased() == roomID else { continue }
                switch row["entity_type"] as? String {
                case "turn":
                    if let id = identity["turn_id"] as? String { turns.insert(id.uppercased()) }
                case "bubble":
                    if let id = identity["message_id"] as? String { bubbles.insert(id.uppercased()) }
                default:
                    continue
                }
            }
            // `has_more` is the server's own answer, observed from one row past
            // the page rather than inferred from the page being short.
            guard result["has_more"] as? Bool == true else { break }
        }
        return Projection(turns: turns.count, bubbles: bubbles.count)
    }
}

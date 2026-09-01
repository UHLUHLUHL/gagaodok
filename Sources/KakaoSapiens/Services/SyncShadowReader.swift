import CryptoKit
import Foundation

/// What this device could make of a room another device owns.
///
/// Counts and one digest, never a decrypted line. The digest is built from
/// bubble identity and order alone, so the writing device and this one can
/// agree on what arrived without either showing a word.
public struct SyncShadowReadResult: Equatable {
    public let roomID: String
    public let spaceID: String
    public let turnCount: Int
    public let bubbleCount: Int
    public let decryptedCount: Int
    public let contentHash: String
    /// Why the first unreadable bubble did not open, in non-secret terms.
    public let diagnostic: String

    public var allDecrypted: Bool { bubbleCount > 0 && decryptedCount == bubbleCount }
}

public enum SyncShadowReadError: Error, Equatable {
    case secretsUnavailable
    case transport
    case malformedProjection
    case roomAbsent
}

/// Reading a room this device did not write.
///
/// The mirror of `SyncShadowImporter`: rows arrive owned by another space, and
/// the scope key is derived from that space rather than this one. A device that
/// derived under its own space would fail to open everything it did not write,
/// which is precisely the direction being proved here.
///
/// Field names are the wire's, not D1's. The Worker strips the `_enc` suffix
/// when it projects a row and spells the worldline as the nullable
/// `worldline_id`; reading the column names instead finds nothing and looks
/// exactly like a row with nothing sealed in it.
@MainActor
public final class SyncShadowReader {
    private let accountID: String
    private let client: SyncWorkerClient
    private let loadSecrets: () -> SyncSecretLoadResult

    /// The bubble fields that carry ciphertext, named as they arrive.
    private static let sealedFields = ["sender", "kind", "text", "speaker_ref", "reactions"]

    public init(
        accountID: String,
        client: SyncWorkerClient,
        loadSecrets: @escaping () -> SyncSecretLoadResult = { SyncSecretStore.load() }
    ) {
        self.accountID = accountID
        self.client = client
        self.loadSecrets = loadSecrets
    }

    private struct Bubble {
        let messageID: String
        let roomID: String
        let spaceID: String
        let worldlineID: String?
        let order: UInt64
        let sealed: [(String, String)]
    }

    public func read(writerSpaceID: String, roomID: UUID) async throws -> SyncShadowReadResult {
        guard case .available(let secrets) = loadSecrets() else {
            throw SyncShadowReadError.secretsUnavailable
        }
        let wanted = roomID.uuidString.uppercased()

        var bubbles: [Bubble] = []
        var turns: Set<String> = []
        var space = "-"
        var after: UInt64 = 0
        // A page count rather than an open loop: a server that kept claiming
        // there was more would otherwise spin here forever.
        var pages = 0
        while pages < 200 {
            pages += 1
            let response: SyncHTTPResponse
            do {
                response = try await client.changes(after: after, limit: 300)
            } catch {
                throw SyncShadowReadError.transport
            }
            guard
                let root = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
                let result = root["result"] as? [String: Any],
                let rows = result["changes"] as? [[String: Any]]
            else {
                throw SyncShadowReadError.malformedProjection
            }
            for row in rows {
                if let sequence = row["change_seq"] as? Int, sequence > 0 {
                    after = max(after, UInt64(sequence))
                }
                guard
                    let identity = row["identity"] as? [String: Any],
                    (identity["room_id"] as? String)?.uppercased() == wanted,
                    identity["space_id"] as? String == writerSpaceID
                else { continue }
                switch row["entity_type"] as? String {
                case "turn":
                    if let id = identity["turn_id"] as? String { turns.insert(id.uppercased()) }
                case "bubble":
                    guard
                        let projection = row["projection"] as? [String: Any],
                        let messageID = identity["message_id"] as? String,
                        let order = projection["bubble_order"] as? Int, order >= 0
                    else { throw SyncShadowReadError.malformedProjection }
                    space = (identity["space_id"] as? String) ?? space
                    bubbles.append(
                        Bubble(
                            messageID: messageID.uppercased(),
                            roomID: wanted,
                            spaceID: (identity["space_id"] as? String) ?? "",
                            // Nullable on the wire. `worldline_key` is the
                            // storage key and never travels.
                            worldlineID: identity["worldline_id"] as? String,
                            order: UInt64(order),
                            sealed: Self.sealedFields.compactMap { field in
                                (projection[field] as? String).map { (field, $0) }
                            }
                        )
                    )
                default:
                    continue
                }
            }
            guard result["has_more"] as? Bool == true else { break }
        }
        if bubbles.isEmpty && turns.isEmpty { throw SyncShadowReadError.roomAbsent }

        // The writer hashed in the order it sent; sorting reproduces that from
        // rows which may have arrived across several pages.
        bubbles.sort { $0.order < $1.order }

        var decrypted = 0
        var firstFailure: String?
        var hasher = SHA256()
        hasher.update(data: Data(wanted.utf8))
        for bubble in bubbles {
            if let failure = failureOpening(bubble, masterKey: secrets.accountMasterKey) {
                if firstFailure == nil { firstFailure = failure }
            } else {
                decrypted += 1
            }
            hasher.update(data: Data(bubble.messageID.utf8))
            hasher.update(data: withUnsafeBytes(of: bubble.order.bigEndian) { Data($0) })
        }

        return SyncShadowReadResult(
            roomID: wanted,
            spaceID: space,
            turnCount: turns.count,
            bubbleCount: bubbles.count,
            decryptedCount: decrypted,
            contentHash: hasher.finalize().map { String(format: "%02x", $0) }.joined(),
            diagnostic: "acct=\(accountID.prefix(8)) space=\(space) \(firstFailure ?? "opened")"
        )
    }

    /// Nil when the bubble opened; otherwise a short, non-secret reason.
    private func failureOpening(_ bubble: Bubble, masterKey: Data) -> String? {
        guard !bubble.sealed.isEmpty else { return "fail=no-sealed-field" }
        let scope = SyncE2EE.Scope(
            accountID: accountID,
            // The originating space, taken from the row: a bubble the phone
            // wrote is keyed under PHONE_SPACE no matter who reads it.
            spaceID: bubble.spaceID,
            roomID: bubble.roomID,
            worldlineID: bubble.worldlineID
        )
        guard let keys = try? SyncE2EE.deriveScopeKeys(accountMasterKey: masterKey, scope: scope) else {
            return "fail=derive"
        }
        for (field, envelope) in bubble.sealed {
            guard let bytes = Data(base64Encoded: envelope) else { return "fail=base64 field=\(field)" }
            guard let opened = try? SyncE2EE.open(
                envelope: bytes,
                key: keys.fieldAEADKey,
                context: SyncE2EE.AADContext(
                    scope: scope, entityType: "bubble", entityID: bubble.messageID,
                    fieldPath: field, bubbleOrder: bubble.order, recoveryVersion: nil
                )
            ) else { return "fail=open field=\(field)" }
            // The plaintext is never kept; only its emptiness is refused.
            if opened.isEmpty { return "fail=empty field=\(field)" }
        }
        return nil
    }
}

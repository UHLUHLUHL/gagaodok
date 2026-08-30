import Foundation

/// The thing a joining device scans.
///
/// It carries the address, the account being joined, the session, and the
/// `pairing_secret` — and nothing else. No device token, no master key, no
/// claim secret, no recovery phrase. Whoever holds this payload can attempt to
/// join, so it is shown on screen and never written to a URL, the clipboard, or
/// a log: a URL would make a scanner open a browser, leaving the secret in a
/// history somewhere.
public struct SyncPairingPayload: Equatable {
    public let baseURL: URL
    public let accountID: String
    public let sessionID: String
    public let pairingSecret: Data

    public enum PayloadError: Error, Equatable {
        case malformed
        case notCanonical
        case unsupportedVersion
    }

    private static let magic = Data("GDP1".utf8)
    private static let version: UInt32 = 1
    private static let fieldCount: UInt16 = 5

    public init(baseURL: URL, accountID: String, sessionID: String, pairingSecret: Data) throws {
        guard pairingSecret.count == 32 else { throw PayloadError.malformed }
        guard baseURL.scheme == "https", baseURL.host != nil,
              baseURL.query == nil, baseURL.fragment == nil else {
            throw PayloadError.malformed
        }
        guard Self.isCanonicalUUID(accountID), Self.isCanonicalUUID(sessionID) else {
            throw PayloadError.malformed
        }
        self.baseURL = baseURL
        self.accountID = accountID
        self.sessionID = sessionID
        self.pairingSecret = pairingSecret
    }

    /// Canonical bytes. The field set is fixed and ascending, so this is a
    /// function of the values alone — which is what makes the decoder's
    /// re-encode check meaningful.
    public func encoded() -> Data {
        var out = Self.magic
        out.append(contentsOf: Self.fieldCount.bigEndianBytes)
        Self.appendField(&out, id: 1, value: Data(Self.version.bigEndianBytes))
        Self.appendField(&out, id: 2, value: Data(baseURL.absoluteString.utf8))
        Self.appendField(&out, id: 3, value: Data(accountID.utf8))
        Self.appendField(&out, id: 4, value: Data(sessionID.utf8))
        Self.appendField(&out, id: 5, value: pairingSecret)
        return out
    }

    /// Base64URL without padding, which is what a QR actually carries.
    public func encodedText() -> String {
        encoded().base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decode(text: String) throws -> SyncPairingPayload {
        guard let bytes = base64URLDecode(text) else { throw PayloadError.malformed }
        let payload = try decode(bytes)
        // Re-encoding is the whole canonicality check: trailing bytes, a
        // missing field, reordered fields, a lowercase UUID and a padded or
        // otherwise non-canonical Base64 spelling all fail right here.
        guard payload.encoded() == bytes, payload.encodedText() == text else {
            throw PayloadError.notCanonical
        }
        return payload
    }

    public static func decode(_ bytes: Data) throws -> SyncPairingPayload {
        guard bytes.count > 6, bytes.prefix(4) == magic else { throw PayloadError.malformed }
        guard readUInt16(bytes, at: 4) == fieldCount else { throw PayloadError.malformed }

        var offset = 6
        var fields: [UInt16: Data] = [:]
        var order: [UInt16] = []
        while offset < bytes.count {
            guard offset + 7 <= bytes.count else { throw PayloadError.malformed }
            let id = readUInt16(bytes, at: offset)
            guard bytes[bytes.startIndex + offset + 2] == 1 else { throw PayloadError.malformed }
            let length = Int(readUInt32(bytes, at: offset + 3))
            offset += 7
            guard length >= 0, offset + length <= bytes.count else { throw PayloadError.malformed }
            guard fields[id] == nil else { throw PayloadError.malformed }
            fields[id] = Data(bytes[(bytes.startIndex + offset)..<(bytes.startIndex + offset + length)])
            order.append(id)
            offset += length
        }
        guard offset == bytes.count, order == [1, 2, 3, 4, 5] else { throw PayloadError.malformed }

        guard let versionField = fields[1], versionField.count == 4 else { throw PayloadError.malformed }
        guard readUInt32(versionField, at: 0) == version else { throw PayloadError.unsupportedVersion }

        guard let urlField = fields[2], let urlText = String(data: urlField, encoding: .utf8),
              let url = URL(string: urlText),
              let accountField = fields[3], let account = String(data: accountField, encoding: .utf8),
              let sessionField = fields[4], let session = String(data: sessionField, encoding: .utf8),
              let secret = fields[5] else {
            throw PayloadError.malformed
        }
        return try SyncPairingPayload(
            baseURL: url,
            accountID: account,
            sessionID: session,
            pairingSecret: secret
        )
    }

    private static func appendField(_ out: inout Data, id: UInt16, value: Data) {
        out.append(contentsOf: id.bigEndianBytes)
        out.append(1)
        out.append(contentsOf: UInt32(value.count).bigEndianBytes)
        out.append(value)
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        let base = data.startIndex + offset
        return (UInt16(data[base]) << 8) | UInt16(data[base + 1])
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        return (0..<4).reduce(UInt32(0)) { ($0 << 8) | UInt32(data[base + $1]) }
    }

    private static func base64URLDecode(_ text: String) -> Data? {
        guard !text.contains("="), !text.contains("+"), !text.contains("/") else { return nil }
        var padded = text.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while padded.count % 4 != 0 { padded.append("=") }
        return Data(base64Encoded: padded)
    }

    static func isCanonicalUUID(_ value: String) -> Bool {
        value.range(of: "^[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}$", options: .regularExpression) != nil
    }
}

// File-scoped on purpose: `SyncE2EE` declares its own, and two internal
// spellings of the same member would be ambiguous wherever both are visible.
private extension FixedWidthInteger {
    var bigEndianBytes: [UInt8] { withUnsafeBytes(of: bigEndian) { Array($0) } }
}

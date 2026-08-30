import Foundation

public protocol SyncSlottedSecretVault {
    func load(slot: SyncSecretSlot) -> SyncSecretLoadResult
    func save(_ bundle: SyncSecretBundle, slot: SyncSecretSlot) throws
    func remove(slot: SyncSecretSlot)
}

public struct KeychainSyncSlottedSecretVault: SyncSlottedSecretVault {
    public init() {}
    public func load(slot: SyncSecretSlot) -> SyncSecretLoadResult { SyncSecretStore.load(slot: slot) }
    public func save(_ bundle: SyncSecretBundle, slot: SyncSecretSlot) throws {
        try SyncSecretStore.save(bundle, slot: slot)
    }
    public func remove(slot: SyncSecretSlot) { SyncSecretStore.remove(slot: slot) }
}

public enum SyncTransitionStage: String, Codable {
    case staged
    case committing
}

public struct SyncAccountTransitionRecord: Codable, Equatable {
    public let stage: SyncTransitionStage
    public let oldAccountID: String
    public let newAccountID: String
    public let createdAtMilliseconds: Int64

    enum CodingKeys: String, CodingKey {
        case stage
        case oldAccountID = "old_account_id"
        case newAccountID = "new_account_id"
        case createdAtMilliseconds = "created_at_ms"
    }

    public init(
        stage: SyncTransitionStage,
        oldAccountID: String,
        newAccountID: String,
        createdAtMilliseconds: Int64
    ) {
        self.stage = stage
        self.oldAccountID = oldAccountID
        self.newAccountID = newAccountID
        self.createdAtMilliseconds = createdAtMilliseconds
    }
}

public enum SyncAccountTransitionStoreError: Error {
    case corruptJournal
    case invalidRecord
    case missingStagingFile
    case missingRollbackFile
}

public final class SyncAccountTransitionJournal: @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()
    private static let allowedKeys: Set<String> = [
        "version", "stage", "old_account_id", "new_account_id", "created_at_ms",
    ]
    private static let identifier = try! NSRegularExpression(
        pattern: "^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$"
    )

    public init(fileURL: URL) { self.fileURL = fileURL }

    public func save(_ record: SyncAccountTransitionRecord) throws { try locked {
        guard Self.valid(record) else { throw SyncAccountTransitionStoreError.invalidRecord }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        var object = try Self.object(for: record)
        object["version"] = 1
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUnlessOpen])
    } }

    public func load() throws -> SyncAccountTransitionRecord? { try locked {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: fileURL)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(object.keys) == Self.allowedKeys,
                  object["version"] as? Int == 1 else {
                throw SyncAccountTransitionStoreError.corruptJournal
            }
            let decoder = JSONDecoder()
            var withoutVersion = object
            withoutVersion.removeValue(forKey: "version")
            let record = try decoder.decode(
                SyncAccountTransitionRecord.self,
                from: JSONSerialization.data(withJSONObject: withoutVersion)
            )
            guard Self.valid(record) else { throw SyncAccountTransitionStoreError.invalidRecord }
            return record
        } catch let error as SyncAccountTransitionStoreError { throw error }
        catch { throw SyncAccountTransitionStoreError.corruptJournal }
    } }

    public func remove() throws { try locked {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    } }

    private static func object(for record: SyncAccountTransitionRecord) throws -> [String: Any] {
        let data = try JSONEncoder().encode(record)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SyncAccountTransitionStoreError.invalidRecord
        }
        return object
    }

    private static func valid(_ record: SyncAccountTransitionRecord) -> Bool {
        func isIdentifier(_ value: String) -> Bool {
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            return identifier.firstMatch(in: value, range: range) != nil
        }
        return isIdentifier(record.oldAccountID) && isIdentifier(record.newAccountID)
            && record.oldAccountID != record.newAccountID && record.createdAtMilliseconds > 0
    }

    private func locked<T>(_ work: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }; return try work()
    }
}

public enum SyncTransitionFileRole: String, CaseIterable {
    case connection = "connection.json"
    case replica = "replica.plist"
    case cursor = "pull.json"
    case outbox = "outbox.plist"
}

public final class SyncTransitionFiles: @unchecked Sendable {
    private let directoryURL: URL
    private let lock = NSLock()

    public init(directoryURL: URL) { self.directoryURL = directoryURL }

    public func writeActive(_ data: Data, role: SyncTransitionFileRole) throws {
        try locked { try write(data, to: url(role, suffix: "")) }
    }

    public func stage(_ data: Data, role: SyncTransitionFileRole) throws {
        try locked { try write(data, to: url(role, suffix: ".staging")) }
    }

    public func readActive(role: SyncTransitionFileRole) throws -> Data? { try locked {
        let target = url(role, suffix: "")
        return FileManager.default.fileExists(atPath: target.path) ? try Data(contentsOf: target) : nil
    } }

    public func prepareRollback() throws { try locked {
        for role in SyncTransitionFileRole.allCases {
            let active = url(role, suffix: "")
            let rollback = url(role, suffix: ".rollback")
            if FileManager.default.fileExists(atPath: active.path) {
                try write(Data(contentsOf: active), to: rollback)
            } else if FileManager.default.fileExists(atPath: rollback.path) {
                try FileManager.default.removeItem(at: rollback)
            }
        }
    } }

    public func promote() throws { try locked {
        for role in SyncTransitionFileRole.allCases {
            let staging = url(role, suffix: ".staging")
            guard FileManager.default.fileExists(atPath: staging.path) else { continue }
            try write(Data(contentsOf: staging), to: url(role, suffix: ""))
        }
        guard FileManager.default.fileExists(atPath: url(.connection, suffix: "").path) else {
            throw SyncAccountTransitionStoreError.missingStagingFile
        }
    } }

    public func restore() throws { try locked {
        let rollbackConnection = url(.connection, suffix: ".rollback")
        guard FileManager.default.fileExists(atPath: rollbackConnection.path) else {
            throw SyncAccountTransitionStoreError.missingRollbackFile
        }
        for role in SyncTransitionFileRole.allCases {
            let rollback = url(role, suffix: ".rollback")
            let active = url(role, suffix: "")
            if FileManager.default.fileExists(atPath: rollback.path) {
                try write(Data(contentsOf: rollback), to: active)
            } else if FileManager.default.fileExists(atPath: active.path) {
                try FileManager.default.removeItem(at: active)
            }
        }
    } }

    public func discardTransient() throws { try locked {
        for role in SyncTransitionFileRole.allCases {
            for suffix in [".staging", ".rollback"] {
                let target = url(role, suffix: suffix)
                if FileManager.default.fileExists(atPath: target.path) {
                    try FileManager.default.removeItem(at: target)
                }
            }
        }
    } }

    public var hasTransientFiles: Bool { locked {
        SyncTransitionFileRole.allCases.contains { role in
            [".staging", ".rollback"].contains { suffix in
                FileManager.default.fileExists(atPath: url(role, suffix: suffix).path)
            }
        }
    } }

    private func url(_ role: SyncTransitionFileRole, suffix: String) -> URL {
        directoryURL.appendingPathComponent(role.rawValue + suffix)
    }

    private func write(_ data: Data, to target: URL) throws {
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target, options: [.atomic, .completeFileProtectionUnlessOpen])
    }

    private func locked<T>(_ work: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }; return try work()
    }
}

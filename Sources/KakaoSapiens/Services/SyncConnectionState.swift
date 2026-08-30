import Foundation

public enum SyncConnectionStateError: Error {
    case invalidConfiguration
    case invalidEnrollment
    case replayMismatch
    case corruptStore
}

public struct SyncConnectionConfiguration: Codable, Equatable {
    public let baseURL: URL
    public let accountID: String
    public let deviceID: String
    public let enabled: Bool
    public let changesCursor: String?

    public init(baseURL: URL, accountID: String, deviceID: String, enabled: Bool, changesCursor: String?) throws {
        guard baseURL.scheme == "https", baseURL.host != nil,
              baseURL.user == nil, baseURL.password == nil,
              baseURL.query == nil, baseURL.fragment == nil,
              Self.isIdentifier(accountID), Self.isIdentifier(deviceID),
              changesCursor.map({ !$0.isEmpty && $0.count <= 4096 }) ?? true else {
            throw SyncConnectionStateError.invalidConfiguration
        }
        self.baseURL = baseURL
        self.accountID = accountID
        self.deviceID = deviceID
        self.enabled = enabled
        self.changesCursor = changesCursor
    }

    private static func isIdentifier(_ value: String) -> Bool {
        value.range(of: "^[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}$", options: .regularExpression) != nil
    }
}

public enum SyncConnectionLoadResult: Equatable {
    case absent
    case available(SyncConnectionConfiguration)
    case relinkRequired
}

/// Non-secret sync endpoint and cursor state. A missing file means sync is off;
/// malformed state never guesses a replacement account or endpoint.
public final class SyncConnectionStateStore: @unchecked Sendable {
    private struct Stored: Codable { let version: Int; let configuration: SyncConnectionConfiguration }
    private let fileURL: URL
    private let lock = NSLock()

    public init(fileURL: URL) { self.fileURL = fileURL }

    public func load() -> SyncConnectionLoadResult { locked {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .absent }
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode(Stored.self, from: data), stored.version == 1,
              let validated = try? SyncConnectionConfiguration(
                baseURL: stored.configuration.baseURL,
                accountID: stored.configuration.accountID,
                deviceID: stored.configuration.deviceID,
                enabled: stored.configuration.enabled,
                changesCursor: stored.configuration.changesCursor
              ) else { return .relinkRequired }
        return .available(validated)
    } }

    public func save(_ configuration: SyncConnectionConfiguration) throws { try locked {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(Stored(version: 1, configuration: configuration))
            .write(to: fileURL, options: [.atomic, .completeFileProtectionUnlessOpen])
    } }

    public func encoded(_ configuration: SyncConnectionConfiguration) throws -> Data {
        try JSONEncoder().encode(Stored(version: 1, configuration: configuration))
    }

    private func locked<T>(_ work: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }; return try work()
    }
}

public struct SyncPendingEnrollment: Equatable {
    public let enrollmentID: String
    public let rawBody: Data
}

/// Separate exact-byte journal for the unauthenticated first enrollment. It
/// intentionally contains neither the recovery phrase nor raw device secrets.
public final class SyncEnrollmentJournal: @unchecked Sendable {
    private struct Stored: Codable { let version: Int; let enrollmentID: String; let rawBody: Data }
    private let fileURL: URL
    private let lock = NSLock()
    public init(fileURL: URL) { self.fileURL = fileURL }

    public func stage(enrollmentID: String, rawBody: Data) throws {
        try locked {
            guard Self.isIdentifier(enrollmentID), !rawBody.isEmpty, rawBody.count <= 1_048_576 else {
                throw SyncConnectionStateError.invalidEnrollment
            }
            if let existing = try pendingUnlocked() {
                guard existing.enrollmentID == enrollmentID, existing.rawBody == rawBody else {
                    throw SyncConnectionStateError.replayMismatch
                }
                return
            }
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try PropertyListEncoder().encode(Stored(version: 1, enrollmentID: enrollmentID, rawBody: rawBody))
                .write(to: fileURL, options: [.atomic, .completeFileProtectionUnlessOpen])
        }
    }

    public func pending() throws -> SyncPendingEnrollment? { try locked { try pendingUnlocked() } }

    public func acknowledge(enrollmentID: String) throws { try locked {
        guard let existing = try pendingUnlocked() else { return }
        guard existing.enrollmentID == enrollmentID else { throw SyncConnectionStateError.replayMismatch }
        try FileManager.default.removeItem(at: fileURL)
    } }

    private func pendingUnlocked() throws -> SyncPendingEnrollment? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        do {
            let stored = try PropertyListDecoder().decode(Stored.self, from: Data(contentsOf: fileURL))
            guard stored.version == 1, Self.isIdentifier(stored.enrollmentID),
                  !stored.rawBody.isEmpty, stored.rawBody.count <= 1_048_576 else {
                throw SyncConnectionStateError.corruptStore
            }
            return SyncPendingEnrollment(enrollmentID: stored.enrollmentID, rawBody: stored.rawBody)
        } catch let error as SyncConnectionStateError { throw error }
        catch { throw SyncConnectionStateError.corruptStore }
    }

    private static func isIdentifier(_ value: String) -> Bool {
        value.range(of: "^[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}$", options: .regularExpression) != nil
    }
    private func locked<T>(_ work: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }; return try work()
    }
}

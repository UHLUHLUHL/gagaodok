import Foundation
import Security

public struct SyncSecretBundle: Equatable {
    public let accountMasterKey: Data
    public let deviceToken: Data

    public init(accountMasterKey: Data, deviceToken: Data) throws {
        guard accountMasterKey.count == 32, deviceToken.count == 32 else {
            throw SyncSecretStoreError.invalidLength
        }
        self.accountMasterKey = accountMasterKey
        self.deviceToken = deviceToken
    }
}

public enum SyncSecretLoadResult: Equatable {
    case absent
    case available(SyncSecretBundle)
    case relinkRequired
}

public enum SyncSecretStoreError: Error {
    case invalidLength
    case invalidEncoding
    case keychain(OSStatus)
}

/// Device-local custody for the two raw sync secrets.
///
/// Each value is a separate generic-password item with
/// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, and synchronizable is
/// explicitly false. The account master key and raw device token therefore do
/// not move through iCloud Keychain or a restored device backup.
public enum SyncSecretStore {
    private static let service = "com.sapiens.gagaodok.sync-secrets.v1"
    private static let masterKeyAccount = "account-master-key"
    private static let deviceTokenAccount = "device-token"

    public static func load() -> SyncSecretLoadResult {
        let master = read(account: masterKeyAccount)
        let token = read(account: deviceTokenAccount)
        switch (master, token) {
        case (.success(nil), .success(nil)):
            return .absent
        case (.success(let master?), .success(let token?)):
            guard let bundle = try? SyncSecretBundle(accountMasterKey: master, deviceToken: token) else {
                return .relinkRequired
            }
            return .available(bundle)
        default:
            // A partial pair or an unreadable item is never repaired by
            // inventing a new key. The caller must enter pairing/recovery.
            return .relinkRequired
        }
    }

    public static func save(_ bundle: SyncSecretBundle) throws {
        let previousMaster = try readValue(account: masterKeyAccount)
        try upsert(bundle.accountMasterKey, account: masterKeyAccount)
        do {
            try upsert(bundle.deviceToken, account: deviceTokenAccount)
        } catch {
            // Restore the former complete pair rather than destroying a valid
            // master key when only the second write failed.
            if let previousMaster {
                try? upsert(previousMaster, account: masterKeyAccount)
            } else {
                delete(account: masterKeyAccount)
            }
            throw error
        }
    }

    public static func remove() {
        delete(account: masterKeyAccount)
        delete(account: deviceTokenAccount)
    }

    private static func query(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }

    private static func read(account: String) -> Result<Data?, SyncSecretStoreError> {
        var item = query(account: account)
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(item as CFDictionary, &result)
        if status == errSecItemNotFound { return .success(nil) }
        guard status == errSecSuccess, let data = result as? Data else {
            return .failure(.keychain(status))
        }
        return .success(data)
    }

    private static func readValue(account: String) throws -> Data? {
        switch read(account: account) {
        case .success(let value): return value
        case .failure(let error): throw error
        }
    }

    private static func upsert(_ data: Data, account: String) throws {
        let base = query(account: account)
        let status = SecItemUpdate(
            base as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if status == errSecItemNotFound {
            var item = base
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw SyncSecretStoreError.keychain(added) }
        } else if status != errSecSuccess {
            throw SyncSecretStoreError.keychain(status)
        }
    }

    private static func delete(account: String) {
        SecItemDelete(query(account: account) as CFDictionary)
    }
}

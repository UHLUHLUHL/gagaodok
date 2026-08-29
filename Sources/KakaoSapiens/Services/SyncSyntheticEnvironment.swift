import Foundation

/// Where the synthetic test endpoint comes from.
///
/// Never a literal in this repository. The address of a deployed Worker is not
/// a secret, but hardcoding one means every build points at somebody's account
/// and a checkout can start talking to it by accident. The app reads it from a
/// file the user places themselves, and when that file is absent the sync
/// screen simply has nothing to offer.
///
/// This is the synthetic test environment only. It is not a route to real
/// conversation data, and nothing here enables synchronisation.
public struct SyncSyntheticEnvironment: Equatable {
    public let baseURL: URL
    /// The account and device this build enrolls as. Synthetic identifiers.
    public let accountID: String
    public let deviceID: String
    public let enrollmentID: String

    private struct Stored: Decodable {
        let base_url: String
        let account_id: String
        let device_id: String
        let enrollment_id: String
    }

    /// `~/Library/Application Support/KakaoSapiens/sync-synthetic.json`
    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        return base.appendingPathComponent("KakaoSapiens/sync-synthetic.json")
    }

    /// Load the environment, or nil when it is absent or does not check out.
    ///
    /// A malformed file is treated exactly like a missing one. Guessing at a
    /// half-written endpoint is how a build ends up sending an enrollment
    /// somewhere nobody intended.
    public static func load(from url: URL = defaultURL()) -> SyncSyntheticEnvironment? {
        guard let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode(Stored.self, from: data),
              let baseURL = URL(string: stored.base_url),
              baseURL.scheme == "https", baseURL.host != nil,
              baseURL.query == nil, baseURL.fragment == nil,
              isIdentifier(stored.account_id), isIdentifier(stored.device_id),
              isIdentifier(stored.enrollment_id) else {
            return nil
        }
        return SyncSyntheticEnvironment(
            baseURL: baseURL,
            accountID: stored.account_id,
            deviceID: stored.device_id,
            enrollmentID: stored.enrollment_id
        )
    }

    private static func isIdentifier(_ value: String) -> Bool {
        value.range(of: "^[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}$", options: .regularExpression) != nil
    }

    /// The host, for a screen that has to say *something* about where it points.
    ///
    /// The host alone, never the full URL: a path or a query could carry a
    /// token, and this string is the one thing about the endpoint the UI shows.
    public var displayHost: String { baseURL.host ?? "" }
}

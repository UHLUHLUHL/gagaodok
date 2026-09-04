import Combine
import Foundation

public struct SyncAccountDevice: Equatable, Identifiable {
    public let id: String
    public let platform: String
    public let linkedAt: String
    public let isCurrent: Bool

    public var title: String {
        switch platform {
        case "macos": return "Mac"
        case "android_phone": return "Android 폰"
        case "android_tablet": return "Android 태블릿"
        default: return "알 수 없는 기기"
        }
    }
}

public enum SyncDeviceListState: Equatable {
    case idle
    case loading
    case loaded([SyncAccountDevice])
    case failed
}

@MainActor
public final class SyncDeviceListModel: ObservableObject {
    @Published public private(set) var state: SyncDeviceListState = .idle
    /// The device the user has asked to remove, waiting for confirmation.
    @Published public private(set) var pendingRevoke: SyncAccountDevice?
    @Published public private(set) var revokeFailed = false
    private let client: SyncWorkerClient

    public init(client: SyncWorkerClient) { self.client = client }

    /// Removing *this* device is deliberately not offered here.
    ///
    /// Revoking is a server-side act; it would leave this Mac holding keys the
    /// account no longer honours — the half-linked state this whole feature
    /// exists to escape. Leaving is what "이 기기 연결 해제" does, and that
    /// clears the local side too.
    public func canRevoke(_ device: SyncAccountDevice) -> Bool { !device.isCurrent }

    public func requestRevoke(_ device: SyncAccountDevice) {
        guard canRevoke(device) else { return }
        revokeFailed = false
        pendingRevoke = device
    }

    public func cancelRevoke() {
        pendingRevoke = nil
        revokeFailed = false
    }

    public func confirmRevoke() async {
        guard let device = pendingRevoke else { return }
        pendingRevoke = nil
        do {
            _ = try await client.revokeDevice(deviceID: device.id)
            revokeFailed = false
            // Read the list back rather than removing the row locally: what the
            // account holds is the server's answer, not our guess at it.
            state = .idle
            await load()
        } catch {
            revokeFailed = true
        }
    }

    public func load() async {
        guard state != .loading else { return }
        state = .loading
        do {
            let response = try await client.devices()
            state = .loaded(try Self.parse(response.body))
        } catch {
            state = .failed
        }
    }

    private static func parse(_ data: Data) throws -> [SyncAccountDevice] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let rows = result["devices"] as? [[String: Any]] else {
            throw SyncWorkerClientError.invalidResponse
        }
        return try rows.map { row in
            guard let id = row["device_id"] as? String,
                  let platform = row["platform"] as? String,
                  let linkedAt = row["linked_at"] as? String,
                  let isCurrent = row["is_current"] as? Bool,
                  !id.isEmpty,
                  ["macos", "android_phone", "android_tablet"].contains(platform),
                  ISO8601DateFormatter().date(from: linkedAt) != nil else {
                throw SyncWorkerClientError.invalidResponse
            }
            return SyncAccountDevice(id: id, platform: platform, linkedAt: linkedAt, isCurrent: isCurrent)
        }
    }
}

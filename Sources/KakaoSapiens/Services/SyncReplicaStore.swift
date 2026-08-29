import Foundation

public enum SyncReplicaStoreError: Error { case invalidPage; case corruptStore }

public struct SyncReplicaEntry: Equatable {
    public let entityType: String
    public let identityJSON: Data
    public let projectionJSON: Data
}

/// Opaque remote projection store. It is deliberately given only its own file
/// URL and has no reference to the application's local conversation storage.
public final class SyncReplicaStore: @unchecked Sendable {
    private struct Stored: Codable { let version: Int; var entries: [Entry] }
    private struct Entry: Codable { let key: String; let entityType: String; let identityJSON: Data; let projectionJSON: Data }
    private static let entityTypes: Set<String> = ["room","group_state","worldline","turn","bubble","engine_profile","persona_snapshot","checkpoint","attachment"]
    private let fileURL: URL
    private let lock = NSLock()
    public init(fileURL: URL) { self.fileURL = fileURL }

    public func apply(itemsJSON: Data) throws { try locked {
        guard itemsJSON.count <= 8_000_000,
              let array = try JSONSerialization.jsonObject(with: itemsJSON) as? [[String: Any]] else { throw SyncReplicaStoreError.invalidPage }
        var replacements: [Entry] = []
        for item in array {
            guard Set(item.keys) == ["entity_type","identity","projection"],
                  let type=item["entity_type"] as? String, Self.entityTypes.contains(type),
                  let identity=item["identity"] as? [String: Any], !identity.isEmpty,
                  let projection=item["projection"] as? [String: Any] else { throw SyncReplicaStoreError.invalidPage }
            let identityData = try JSONSerialization.data(withJSONObject: identity, options: [.sortedKeys])
            let projectionData = try JSONSerialization.data(withJSONObject: projection, options: [.sortedKeys])
            guard identityData.count <= 16_384, projectionData.count <= 2_000_000 else { throw SyncReplicaStoreError.invalidPage }
            let key = type + ":" + identityData.base64EncodedString()
            replacements.append(Entry(key:key, entityType:type, identityJSON:identityData, projectionJSON:projectionData))
        }
        var stored = try load()
        for entry in replacements { stored.entries.removeAll { $0.key == entry.key }; stored.entries.append(entry) }
        stored.entries.sort { $0.key < $1.key }
        try persist(stored)
    } }

    public func snapshot() throws -> [SyncReplicaEntry] { try locked {
        try load().entries.map { SyncReplicaEntry(entityType:$0.entityType, identityJSON:$0.identityJSON, projectionJSON:$0.projectionJSON) }
    } }

    private func load() throws -> Stored {
        guard FileManager.default.fileExists(atPath:fileURL.path) else { return Stored(version:1,entries:[]) }
        do { let stored=try PropertyListDecoder().decode(Stored.self,from:Data(contentsOf:fileURL));guard stored.version==1 else{throw SyncReplicaStoreError.corruptStore};return stored }
        catch let error as SyncReplicaStoreError { throw error } catch { throw SyncReplicaStoreError.corruptStore }
    }
    private func persist(_ stored:Stored)throws{try FileManager.default.createDirectory(at:fileURL.deletingLastPathComponent(),withIntermediateDirectories:true);try PropertyListEncoder().encode(stored).write(to:fileURL,options:[.atomic,.completeFileProtectionUnlessOpen])}
    private func locked<T>(_ work:()throws->T)rethrows->T{lock.lock();defer{lock.unlock()};return try work()}
}

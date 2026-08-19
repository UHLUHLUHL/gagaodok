import Foundation

public enum ObsidianVaultLocator {
    private struct Configuration: Decodable {
        let vaults: [String: Vault]
    }

    private struct Vault: Decodable {
        let path: String
        let ts: Double?
        let open: Bool?
    }

    public static func preferredExportFolder(
        configurationData: Data,
        folderName: String,
        fileManager: FileManager = .default
    ) -> URL? {
        guard let configuration = try? JSONDecoder().decode(Configuration.self, from: configurationData) else {
            return nil
        }
        let ordered = configuration.vaults.values.sorted { lhs, rhs in
            if (lhs.open == true) != (rhs.open == true) { return lhs.open == true }
            return (lhs.ts ?? 0) > (rhs.ts ?? 0)
        }
        for vault in ordered {
            let folder = URL(fileURLWithPath: vault.path, isDirectory: true)
                .appendingPathComponent(folderName, isDirectory: true)
                .standardizedFileURL
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return folder
            }
        }
        return nil
    }

    public static func openURI(for noteURL: URL) -> URL? {
        var components = URLComponents()
        components.scheme = "obsidian"
        components.host = "open"
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "/?&=+")
        guard let encoded = noteURL.standardizedFileURL.path.addingPercentEncoding(withAllowedCharacters: allowed) else {
            return nil
        }
        components.percentEncodedQuery = "path=\(encoded)"
        return components.url
    }
}

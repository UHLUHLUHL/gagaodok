import Foundation
import AppKit

public class StorageService {
    public static let shared = StorageService()
    
    private let fileManager = FileManager.default
    private let appSupportURL: URL
    
    private var messagesFileURL: URL {
        appSupportURL.appendingPathComponent("chat_history.json")
    }
    
    private var profileFileURL: URL {
        appSupportURL.appendingPathComponent("profile_data.json")
    }
    
    private var avatarFileURL: URL {
        appSupportURL.appendingPathComponent("profile_avatar.png")
    }
    
    private init() {
        if let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let kakaoDir = appSupport.appendingPathComponent("KakaoSapiens", isDirectory: true)
            if !fileManager.fileExists(atPath: kakaoDir.path) {
                try? fileManager.createDirectory(at: kakaoDir, withIntermediateDirectories: true, attributes: nil)
            }
            self.appSupportURL = kakaoDir
        } else {
            self.appSupportURL = fileManager.temporaryDirectory
        }
    }
    
    // MARK: - 대화 내역 저장 및 로드
    public func saveMessages(_ messages: [ChatMessage]) {
        DispatchQueue.global(qos: .utility).async {
            do {
                let data = try JSONEncoder().encode(messages)
                try data.write(to: self.messagesFileURL, options: .atomic)
            } catch {
                print("Failed to save chat history: \(error)")
            }
        }
    }
    
    public func loadMessages() -> [ChatMessage]? {
        guard fileManager.fileExists(atPath: messagesFileURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: messagesFileURL)
            let messages = try JSONDecoder().decode([ChatMessage].self, from: data)
            return messages
        } catch {
            print("Failed to load chat history: \(error)")
            return nil
        }
    }
    
    // MARK: - 프로필 정보 저장 및 로드
    public struct ProfileDTO: Codable {
        public let name: String
        public let statusMessage: String
        public let musicTitle: String
        public let musicArtist: String
    }
    
    public func saveProfile(name: String, statusMessage: String, musicTitle: String, musicArtist: String) {
        DispatchQueue.global(qos: .utility).async {
            let dto = ProfileDTO(name: name, statusMessage: statusMessage, musicTitle: musicTitle, musicArtist: musicArtist)
            do {
                let data = try JSONEncoder().encode(dto)
                try data.write(to: self.profileFileURL, options: .atomic)
            } catch {
                print("Failed to save profile data: \(error)")
            }
        }
    }
    
    public func loadProfile() -> ProfileDTO? {
        guard fileManager.fileExists(atPath: profileFileURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: profileFileURL)
            return try JSONDecoder().decode(ProfileDTO.self, from: data)
        } catch {
            print("Failed to load profile data: \(error)")
            return nil
        }
    }
    
    // MARK: - 프로필 이미지 저장 및 로드
    public func saveAvatarImage(_ image: NSImage?) {
        DispatchQueue.global(qos: .utility).async {
            guard let image = image,
                  let tiffData = image.tiffRepresentation,
                  let bitmapImage = NSBitmapImageRep(data: tiffData),
                  let pngData = bitmapImage.representation(using: .png, properties: [:]) else {
                // nil인 경우 기존 파일 삭제
                try? self.fileManager.removeItem(at: self.avatarFileURL)
                return
            }
            try? pngData.write(to: self.avatarFileURL, options: .atomic)
        }
    }
    
    public func loadAvatarImage() -> NSImage? {
        guard fileManager.fileExists(atPath: avatarFileURL.path),
              let data = try? Data(contentsOf: avatarFileURL) else { return nil }
        return NSImage(data: data)
    }
}

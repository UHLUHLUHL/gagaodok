import Foundation
import SwiftUI
import AppKit

public struct RoomProfile: Codable, Equatable {
    public var name: String
    public var statusMessage: String
    public var musicTitle: String
    public var musicArtist: String
    public var avatarImageFileName: String?
    
    public init(
        name: String = "사피엔스",
        statusMessage: String = "수학 학습 파트너 · 냉철한 피드백",
        musicTitle: String = "1-800 (Explicit Ver.)",
        musicArtist: String = "bbno$",
        avatarImageFileName: String? = nil
    ) {
        self.name = name
        self.statusMessage = statusMessage
        self.musicTitle = musicTitle
        self.musicArtist = musicArtist
        self.avatarImageFileName = avatarImageFileName
    }
}

public struct ChatRoom: Identifiable, Codable, Equatable {
    public let id: UUID
    public var title: String
    public var createdAt: Date
    public var profile: RoomProfile
    public var lastMessageText: String
    public var lastMessageTime: Date
    public var isPinned: Bool
    public var unreadCount: Int
    
    public init(
        id: UUID = UUID(),
        title: String = "사피엔스",
        profile: RoomProfile = RoomProfile(),
        lastMessageText: String = "반갑습니다. 수학 학습 파트너입니다.",
        lastMessageTime: Date = Date(),
        isPinned: Bool = false,
        unreadCount: Int = 0
    ) {
        self.id = id
        self.title = title
        self.createdAt = Date()
        self.profile = profile
        self.lastMessageText = lastMessageText
        self.lastMessageTime = lastMessageTime
        self.isPinned = isPinned
        self.unreadCount = unreadCount
    }
}

public class ChatRoomManager: ObservableObject {
    public static let shared = ChatRoomManager()
    
    @Published public var rooms: [ChatRoom] = []
    
    private let fileManager = FileManager.default
    private static let persistenceQueue = DispatchQueue(label: "com.sapiens.kakaotalk.persistence", qos: .utility)
    public let appSupportURL: URL
    
    private var roomsListURL: URL {
        appSupportURL.appendingPathComponent("rooms_list.json")
    }
    
    private init() {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let dir = appSupport?.appendingPathComponent("KakaoSapiens", isDirectory: true) ?? fileManager.temporaryDirectory
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
        }
        self.appSupportURL = dir
        
        // 1. 저장된 방 목록 로드
        let listURL = dir.appendingPathComponent("rooms_list.json")
        if let savedRooms = Self.loadRoomsFromDisk(url: listURL), !savedRooms.isEmpty {
            self.rooms = savedRooms
        } else {
            // 기본 대화방 생성 (인삿말 없이 빈 대화로 시작)
            let defaultProfile = RoomProfile(name: "사피엔스", statusMessage: "수학 학습 파트너 · 냉철한 피드백")
            let defaultRoom = ChatRoom(id: UUID(), title: "사피엔스", profile: defaultProfile, lastMessageText: "대화를 시작해보세요.")
            self.rooms = [defaultRoom]
            
            Self.saveMessagesDirectly(url: dir.appendingPathComponent("room_\(defaultRoom.id.uuidString)_messages.json"), messages: [])
            Self.saveRoomsDirectly(url: listURL, rooms: [defaultRoom])
        }
    }
    
    public func getRoom(id: UUID) -> ChatRoom? {
        rooms.first(where: { $0.id == id })
    }
    
    public func createNewRoom(name: String, status: String = "수학 학습 코치") -> ChatRoom {
        let newProfile = RoomProfile(name: name, statusMessage: status)
        let newRoom = ChatRoom(
            id: UUID(),
            title: name,
            profile: newProfile,
            lastMessageText: "대화를 시작해보세요.",
            lastMessageTime: Date()
        )
        
        // 인삿말 없이 빈 대화로 생성
        saveMessagesForRoom(roomId: newRoom.id, messages: [])
        
        rooms.insert(newRoom, at: 0)
        saveRooms()
        return newRoom
    }
    
    public func deleteRoom(id: UUID) {
        guard rooms.count > 1 else { return }
        rooms.removeAll(where: { $0.id == id })
        saveRooms()
    }
    
    public func updateRoomProfile(roomId: UUID, name: String, statusMessage: String) {
        if let idx = rooms.firstIndex(where: { $0.id == roomId }) {
            rooms[idx].profile.name = name
            rooms[idx].profile.statusMessage = statusMessage
            rooms[idx].title = name
            saveRooms()
        }
    }
    
    public func updateRoomAvatar(roomId: UUID, image: NSImage?) {
        guard let idx = rooms.firstIndex(where: { $0.id == roomId }) else { return }
        let fileName = "avatar_\(rooms[idx].id.uuidString).png"
        let fileURL = appSupportURL.appendingPathComponent(fileName)
        
        if let image = image,
           let tiff = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
            try? png.write(to: fileURL, options: .atomic)
            rooms[idx].profile.avatarImageFileName = fileName
        } else {
            try? fileManager.removeItem(at: fileURL)
            rooms[idx].profile.avatarImageFileName = nil
        }
        saveRooms()
    }
    
    public func loadAvatarForRoom(profile: RoomProfile) -> NSImage? {
        guard let fileName = profile.avatarImageFileName else { return nil }
        let url = appSupportURL.appendingPathComponent(fileName)
        guard fileManager.fileExists(atPath: url.path), let data = try? Data(contentsOf: url) else { return nil }
        return NSImage(data: data)
    }
    
    // MARK: - 룸별 독립 대화 내역 영구 저장 및 로드
    public func messagesURLForRoom(roomId: UUID) -> URL {
        appSupportURL.appendingPathComponent("room_\(roomId.uuidString)_messages.json")
    }
    
    public func loadMessagesForRoom(roomId: UUID) -> [ChatMessage] {
        let url = messagesURLForRoom(roomId: roomId)
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let msgs = try? JSONDecoder().decode([ChatMessage].self, from: data) else {
            return []
        }
        let migrated = Self.migrateLegacyTurns(msgs)
        if migrated.changed {
            Self.saveMessagesDirectly(url: url, messages: migrated.messages)
        }
        return migrated.messages
    }
    
    public func saveMessagesForRoom(roomId: UUID, messages: [ChatMessage]) {
        let url = messagesURLForRoom(roomId: roomId)
        Self.persistenceQueue.async {
            if let data = try? JSONEncoder().encode(messages) {
                try? data.write(to: url, options: .atomic)
            }
        }
        
        // 마지막 메시지 업데이트
        if let last = messages.last, let idx = self.rooms.firstIndex(where: { $0.id == roomId }) {
            DispatchQueue.main.async {
                self.rooms[idx].lastMessageText = last.text.isEmpty ? "사진/파일 전송됨" : last.text
                self.rooms[idx].lastMessageTime = last.timestamp
                self.saveRooms()
            }
        }
    }
    
    private func saveRooms() {
        Self.saveRoomsDirectly(url: roomsListURL, rooms: rooms)
    }
    
    private static func saveRoomsDirectly(url: URL, rooms: [ChatRoom]) {
        persistenceQueue.async {
            if let data = try? JSONEncoder().encode(rooms) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }
    
    private static func saveMessagesDirectly(url: URL, messages: [ChatMessage]) {
        persistenceQueue.async {
            if let data = try? JSONEncoder().encode(messages) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }
    
    private static func loadRoomsFromDisk(url: URL) -> [ChatRoom]? {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([ChatRoom].self, from: data) else {
            return nil
        }
        return list
    }

    private static func migrateLegacyTurns(_ messages: [ChatMessage]) -> (messages: [ChatMessage], changed: Bool) {
        guard messages.contains(where: { $0.turnId == nil }) else { return (messages, false) }
        var migrated = messages
        var index = 0

        while index < migrated.count {
            if migrated[index].sender == .user {
                let id = migrated[index].turnId ?? UUID()
                migrated[index].turnId = id
                migrated[index].canonicalText = migrated[index].canonicalText ?? migrated[index].text
                index += 1
                continue
            }

            let start = index
            while index < migrated.count, migrated[index].sender == .sapiens { index += 1 }
            let id = migrated[start].turnId ?? UUID()
            let canonical = migrated[start..<index]
                .map(\.text)
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
            for position in start..<index {
                migrated[position].turnId = id
                migrated[position].canonicalText = position == start ? canonical : nil
            }
        }
        return (migrated, true)
    }
}

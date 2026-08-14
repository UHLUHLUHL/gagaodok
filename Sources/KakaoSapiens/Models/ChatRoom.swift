import Foundation
import SwiftUI
import AppKit

/// 방마다 다른 말투를 주기 위한 설정입니다.
///
/// 말투는 "설명"보다 "실제 예시"가 훨씬 잘 먹힙니다.
/// 그래서 사용자가 붙여넣은 대사 원문(`samples`)을 그대로 들고 다니고,
/// 거기서 뽑아낸 규칙(`styleGuide`)을 함께 보냅니다.
public struct PersonaStyle: Codable, Equatable {
    /// 캐릭터 이름이나 한 줄 설명. 사용자가 직접 씁니다.
    public var description: String
    /// 실제 대사 예시. 말투 학습의 핵심 재료입니다.
    public var samples: [String]
    /// 예시에서 추출한 말투 규칙. 비어 있으면 예시만 보냅니다.
    public var styleGuide: String
    /// 말투를 실제로 적용할지 여부.
    public var isEnabled: Bool

    public init(
        description: String = "",
        samples: [String] = [],
        styleGuide: String = "",
        isEnabled: Bool = false
    ) {
        self.description = description
        self.samples = samples
        self.styleGuide = styleGuide
        self.isEnabled = isEnabled
    }

    public var hasContent: Bool {
        !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !styleGuide.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !samples.isEmpty
    }

    /// 시스템 지침에 붙일 형태로 만듭니다.
    /// 규칙을 먼저 두고 원문 예시를 뒤에 두면, 모델이 규칙으로 방향을 잡고 예시로 결을 맞춥니다.
    public func promptSection(botName: String) -> String? {
        guard isEnabled, hasContent else { return nil }
        var lines = ["# 말투", "'\(botName)'는 아래 인물의 말투로 말한다. 수학 내용의 정확성은 절대 바꾸지 않는다."]

        let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedDescription.isEmpty {
            lines.append("인물: \(trimmedDescription)")
        }
        let trimmedGuide = styleGuide.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedGuide.isEmpty {
            lines.append("")
            lines.append(trimmedGuide)
        }
        if !samples.isEmpty {
            lines.append("")
            lines.append("아래는 이 인물의 실제 대사다. 어휘와 문장 끝맺음을 이 결에 맞춘다.")
            for sample in samples.prefix(12) {
                lines.append("- \(sample.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            // 예시를 그대로 붙여넣는 실수가 잦습니다. 칭찬 대사를 지적하는 상황에 쓰는 식입니다.
            lines.append("")
            lines.append("이 대사들은 말투를 보여주는 견본일 뿐이다. 문장을 그대로 복사하지 않는다.")
            lines.append("지금 상황에 맞는 말을 새로 만들되 어투만 같게 한다.")
        }
        lines.append("")
        lines.append("말투만 흉내 내고, 설명의 구조·수식·풀이 순서는 원래 방식을 지킨다.")
        lines.append("문제 풀이에 필요한 정보를 말투 때문에 빠뜨리지 않는다.")
        return lines.joined(separator: "\n")
    }
}

public struct RoomProfile: Codable, Equatable {
    public var name: String
    public var statusMessage: String
    public var musicTitle: String
    public var musicArtist: String
    public var avatarImageFileName: String?
    public var persona: PersonaStyle

    public init(
        name: String = "사피엔스",
        statusMessage: String = "수학 학습 파트너 · 냉철한 피드백",
        musicTitle: String = "1-800 (Explicit Ver.)",
        musicArtist: String = "bbno$",
        avatarImageFileName: String? = nil,
        persona: PersonaStyle = PersonaStyle()
    ) {
        self.name = name
        self.statusMessage = statusMessage
        self.musicTitle = musicTitle
        self.musicArtist = musicArtist
        self.avatarImageFileName = avatarImageFileName
        self.persona = persona
    }

    // 기존에 저장된 프로필에는 persona가 없습니다. 없으면 기본값으로 읽습니다.
    private enum CodingKeys: String, CodingKey {
        case name, statusMessage, musicTitle, musicArtist, avatarImageFileName, persona
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "사피엔스"
        statusMessage = try container.decodeIfPresent(String.self, forKey: .statusMessage) ?? ""
        musicTitle = try container.decodeIfPresent(String.self, forKey: .musicTitle) ?? ""
        musicArtist = try container.decodeIfPresent(String.self, forKey: .musicArtist) ?? ""
        avatarImageFileName = try container.decodeIfPresent(String.self, forKey: .avatarImageFileName)
        persona = try container.decodeIfPresent(PersonaStyle.self, forKey: .persona) ?? PersonaStyle()
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
    
    public func updateRoomPersona(roomId: UUID, persona: PersonaStyle) {
        guard let idx = rooms.firstIndex(where: { $0.id == roomId }) else { return }
        guard rooms[idx].profile.persona != persona else { return }
        rooms[idx].profile.persona = persona
        saveRooms()
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
    
    // 답변은 말풍선 단위로 0.45초 간격으로 붙습니다. 그때마다 대화 전체를 인코딩해 쓰면
    // 첨부 이미지의 base64까지 매번 직렬화되어 디스크가 계속 들썩입니다.
    // 마지막 호출로부터 잠깐 조용해진 뒤 한 번만 저장하도록 모읍니다.
    private var pendingSaves: [UUID: (work: DispatchWorkItem, messages: [ChatMessage])] = [:]
    private static let saveCoalescingInterval: TimeInterval = 0.7

    public func saveMessagesForRoom(roomId: UUID, messages: [ChatMessage]) {
        let url = messagesURLForRoom(roomId: roomId)

        pendingSaves[roomId]?.work.cancel()
        let work = DispatchWorkItem { [weak self] in
            Self.write(messages: messages, to: url)
            DispatchQueue.main.async { self?.pendingSaves[roomId] = nil }
        }
        pendingSaves[roomId] = (work, messages)
        Self.persistenceQueue.asyncAfter(deadline: .now() + Self.saveCoalescingInterval, execute: work)

        // 마지막 메시지 업데이트
        // rooms는 @Published라서 값을 넣을 때마다 이 매니저를 보는 화면이 전부 다시 그려집니다.
        // 실제로 달라졌을 때만 건드려야 말풍선이 붙는 동안 화면이 흔들리지 않습니다.
        guard let last = messages.last, let idx = self.rooms.firstIndex(where: { $0.id == roomId }) else { return }
        let preview = last.text.isEmpty ? "사진/파일 전송됨" : last.text
        guard rooms[idx].lastMessageText != preview || rooms[idx].lastMessageTime != last.timestamp else { return }
        DispatchQueue.main.async {
            guard let idx = self.rooms.firstIndex(where: { $0.id == roomId }) else { return }
            self.rooms[idx].lastMessageText = preview
            self.rooms[idx].lastMessageTime = last.timestamp
            self.saveRooms()
        }
    }

    /// 앱이 내려가기 전에 아직 기다리고 있는 저장을 즉시 처리합니다.
    /// 저장을 0.7초 모아서 하기 때문에, 이게 없으면 마지막 말풍선이 유실될 수 있습니다.
    public func flushPendingSaves() {
        let pending = pendingSaves
        pendingSaves.removeAll()
        for (roomId, entry) in pending {
            entry.work.cancel()
            Self.write(messages: entry.messages, to: messagesURLForRoom(roomId: roomId))
        }
    }

    private static func write(messages: [ChatMessage], to url: URL) {
        guard let data = try? JSONEncoder().encode(messages) else { return }
        try? data.write(to: url, options: .atomic)
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

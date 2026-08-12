import Foundation
import SwiftUI

public struct RoomTokenUsage: Codable, Equatable {
    public var promptTokens: Int
    public var candidatesTokens: Int
    public var totalTokens: Int { promptTokens + candidatesTokens }
    
    public init(promptTokens: Int = 0, candidatesTokens: Int = 0) {
        self.promptTokens = promptTokens
        self.candidatesTokens = candidatesTokens
    }
    
    // Gemini 1.5/2.0 Flash 공식 단가 ($0.075 / 1M Input, $0.30 / 1M Output)
    public func costUSD() -> Double {
        let inputCost = Double(promptTokens) * 0.000000075
        let outputCost = Double(candidatesTokens) * 0.00000030
        return inputCost + outputCost
    }
    
    public func costKRW(exchangeRate: Double = 1380.0) -> Double {
        return costUSD() * exchangeRate
    }
}

public class TokenUsageManager: ObservableObject {
    public static let shared = TokenUsageManager()
    
    @Published public var roomUsages: [UUID: RoomTokenUsage] = [:]
    @Published public var exchangeRate: Double = 1380.0
    
    private let fileManager = FileManager.default
    private let usageFileURL: URL
    
    private init() {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let dir = appSupport?.appendingPathComponent("KakaoSapiens", isDirectory: true) ?? fileManager.temporaryDirectory
        self.usageFileURL = dir.appendingPathComponent("token_usage.json")
        
        loadUsage()
        
        // 기존 대화가 있는데 토큰 기록이 비어있다면 대화 내역 기반 초기 추정치 산출
        bootstrapExistingHistoryIfEmpty()
    }
    
    public func recordUsage(roomId: UUID, promptTokens: Int, candidatesTokens: Int) {
        DispatchQueue.main.async {
            var current = self.roomUsages[roomId] ?? RoomTokenUsage()
            current.promptTokens += promptTokens
            current.candidatesTokens += candidatesTokens
            self.roomUsages[roomId] = current
            self.saveUsage()
        }
    }
    
    public func getUsage(for roomId: UUID) -> RoomTokenUsage {
        roomUsages[roomId] ?? RoomTokenUsage()
    }
    
    public var totalPromptTokens: Int {
        roomUsages.values.reduce(0) { $0 + $1.promptTokens }
    }
    
    public var totalCandidatesTokens: Int {
        roomUsages.values.reduce(0) { $0 + $1.candidatesTokens }
    }
    
    public var totalTokens: Int {
        totalPromptTokens + totalCandidatesTokens
    }
    
    public var totalCostUSD: Double {
        roomUsages.values.reduce(0.0) { $0 + $1.costUSD() }
    }
    
    public var totalCostKRW: Double {
        totalCostUSD * exchangeRate
    }
    
    public func resetAllUsage() {
        roomUsages.removeAll()
        saveUsage()
    }
    
    private func saveUsage() {
        DispatchQueue.global(qos: .utility).async {
            let dict = self.roomUsages.reduce(into: [String: RoomTokenUsage]()) { acc, pair in
                acc[pair.key.uuidString] = pair.value
            }
            if let data = try? JSONEncoder().encode(dict) {
                try? data.write(to: self.usageFileURL, options: .atomic)
            }
        }
    }
    
    private func loadUsage() {
        guard fileManager.fileExists(atPath: usageFileURL.path),
              let data = try? Data(contentsOf: usageFileURL),
              let dict = try? JSONDecoder().decode([String: RoomTokenUsage].self, from: data) else {
            return
        }
        var loaded: [UUID: RoomTokenUsage] = [:]
        for (k, v) in dict {
            if let uuid = UUID(uuidString: k) {
                loaded[uuid] = v
            }
        }
        self.roomUsages = loaded
    }
    
    private func bootstrapExistingHistoryIfEmpty() {
        guard roomUsages.isEmpty else { return }
        
        let rooms = ChatRoomManager.shared.rooms
        for room in rooms {
            let messages = ChatRoomManager.shared.loadMessagesForRoom(roomId: room.id)
            guard !messages.isEmpty else { continue }
            
            var estPrompt = 0
            var estCandidates = 0
            
            for msg in messages {
                // 한글 1글자 약 1.5~2토큰, 영문/기호 약 0.5~1토큰 추정
                let charCount = msg.text.count
                let tokens = max(Int(Double(charCount) * 1.6), 10)
                if msg.sender == .user {
                    estPrompt += tokens + 250 // 시스템 프롬프트 가중치
                } else {
                    estCandidates += tokens
                }
            }
            if estPrompt > 0 || estCandidates > 0 {
                roomUsages[room.id] = RoomTokenUsage(promptTokens: estPrompt, candidatesTokens: estCandidates)
            }
        }
        saveUsage()
    }
}

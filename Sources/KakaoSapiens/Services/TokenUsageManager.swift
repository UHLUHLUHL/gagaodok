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
    
    // Gemini 3.6 Flash 공식 단가 ($1.50 / 1M Input, $7.50 / 1M Output)
    public func costUSD() -> Double {
        let inputCost = Double(promptTokens) * 0.00000150
        let outputCost = Double(candidatesTokens) * 0.00000750
        return inputCost + outputCost
    }
    
    public func costKRW(exchangeRate: Double = 1420.0) -> Double {
        return costUSD() * exchangeRate
    }
}

public class TokenUsageManager: ObservableObject {
    public static let shared = TokenUsageManager()
    
    @Published public var roomUsages: [UUID: RoomTokenUsage] = [:]
    @Published public var exchangeRate: Double = 1420.0 // 요청 환율: 1 USD = 1,420 KRW
    
    private let fileManager = FileManager.default
    private let usageFileURL: URL
    
    private init() {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let dir = appSupport?.appendingPathComponent("KakaoSapiens", isDirectory: true) ?? fileManager.temporaryDirectory
        self.usageFileURL = dir.appendingPathComponent("token_usage.json")
        
        loadUsage()
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
                let charCount = msg.text.count
                let tokens = max(Int(Double(charCount) * 1.6), 10)
                if msg.sender == .user {
                    estPrompt += tokens + 250
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

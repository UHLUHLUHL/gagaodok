import CryptoKit
import Foundation

enum SyncRecoveryMnemonicError: Error { case invalidWordList, invalidEntropy, invalidMnemonic }

enum SyncRecoveryMnemonic {
    static func bundledWords(bundle: Bundle = .main) throws -> [String] {
        guard let url = bundle.url(forResource: "english-bip39", withExtension: "txt", subdirectory: "sync") else {
            throw SyncRecoveryMnemonicError.invalidWordList
        }
        return try words(from: String(contentsOf: url, encoding: .utf8))
    }

    static func words(from text: String) throws -> [String] {
        let words = text.split(whereSeparator: \.isNewline).map(String.init)
        guard words.count == 2_048, Set(words).count == 2_048,
              words.allSatisfy({ $0.range(of: "^[a-z]+$", options: .regularExpression) != nil }) else {
            throw SyncRecoveryMnemonicError.invalidWordList
        }
        return words
    }

    static func encode(entropy: Data, words: [String]) throws -> String {
        guard entropy.count == 16, words.count == 2_048 else { throw SyncRecoveryMnemonicError.invalidEntropy }
        let checksum = Array(SHA256.hash(data: entropy))[0] >> 4
        var indices: [Int] = []
        var accumulator = 0
        var bits = 0
        for byte in entropy + Data([checksum << 4]) {
            accumulator = (accumulator << 8) | Int(byte)
            bits += 8
            while bits >= 11 && indices.count < 12 {
                bits -= 11
                indices.append((accumulator >> bits) & 0x7ff)
            }
            accumulator &= bits == 0 ? 0 : (1 << bits) - 1
        }
        guard indices.count == 12 else { throw SyncRecoveryMnemonicError.invalidEntropy }
        return indices.map { words[$0] }.joined(separator: " ")
    }

    static func decode(_ phrase: String, words: [String]) throws -> Data {
        guard words.count == 2_048 else { throw SyncRecoveryMnemonicError.invalidWordList }
        let normalized = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard normalized.count == 12 else { throw SyncRecoveryMnemonicError.invalidMnemonic }
        let lookup = Dictionary(uniqueKeysWithValues: words.enumerated().map { ($1, $0) })
        var accumulator = 0
        var bits = 0
        var bytes: [UInt8] = []
        for word in normalized {
            guard let index = lookup[word] else { throw SyncRecoveryMnemonicError.invalidMnemonic }
            accumulator = (accumulator << 11) | index
            bits += 11
            while bits >= 8 {
                bits -= 8
                bytes.append(UInt8((accumulator >> bits) & 0xff))
            }
            accumulator &= bits == 0 ? 0 : (1 << bits) - 1
        }
        guard bytes.count == 16, bits == 4 else { throw SyncRecoveryMnemonicError.invalidMnemonic }
        let entropy = Data(bytes)
        let expected = Array(SHA256.hash(data: entropy))[0] >> 4
        guard UInt8(accumulator & 0x0f) == expected else { throw SyncRecoveryMnemonicError.invalidMnemonic }
        return entropy
    }
}

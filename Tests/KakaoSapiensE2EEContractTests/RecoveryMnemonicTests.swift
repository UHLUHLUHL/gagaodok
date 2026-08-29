import Foundation

@main
enum RecoveryMnemonicTests {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw Failure() }
        let words = try SyncRecoveryMnemonic.words(
            from: String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
        )
        let entropy = Data(repeating: 0, count: 16)
        let expected = Array(repeating: "abandon", count: 11).joined(separator: " ") + " about"
        guard try SyncRecoveryMnemonic.encode(entropy: entropy, words: words) == expected else { throw Failure() }
        guard try SyncRecoveryMnemonic.decode("  \(expected.uppercased())  ", words: words) == entropy else { throw Failure() }
        var invalid = expected.split(separator:" ").map(String.init); invalid[11]="ability"
        do { _ = try SyncRecoveryMnemonic.decode(invalid.joined(separator:" "),words:words);throw Failure() } catch SyncRecoveryMnemonicError.invalidMnemonic {}
        print("Swift recovery mnemonic: 1 passed")
    }
    struct Failure:Error{}
}

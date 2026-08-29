import Foundation

@main
enum SyncEnrollmentBuilderTests {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw Failure() }
        let words = try SyncRecoveryMnemonic.words(from:String(contentsOfFile:CommandLine.arguments[1],encoding:.utf8))
        let package = try SyncEnrollmentBuilder.build(
            accountID:"11111111-1111-4111-8111-111111111111",deviceID:"22222222-2222-4222-8222-222222222222",enrollmentID:"33333333-3333-4333-8333-333333333333",spaceID:"MAC_SPACE",platform:"macos",accountMasterKey:Data((0..<32).map(UInt8.init)),deviceToken:Data((32..<64).map(UInt8.init)),recoveryEntropy:Data((64..<80).map(UInt8.init)),recoveryNonce:Data((32..<44).map(UInt8.init)),words:words
        )
        let json=try JSONSerialization.jsonObject(with:package.rawRequestBody) as! [String:Any]
        guard json["account_id"] as? String == package.accountID,
              (json["device"] as? [String:Any])?["device_token_hash"] as? String == "72dbb7336c76780023f83da4c355f2eeea85733b13d3477697917790c1229084",
              package.recoveryPhrase.split(separator:" ").count == 12,
              !String(data:package.rawRequestBody,encoding:.utf8)!.contains(package.secrets.deviceToken.base64EncodedString()) else { throw Failure() }
        print("Swift enrollment builder: 1 passed")
    }
    struct Failure:Error{}
}

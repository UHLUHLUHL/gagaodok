import Foundation
import ImageIO

/// 요청에 실릴 토큰 수를 어림합니다.
///
/// 캐시를 만들지 말지 정할 때 씁니다. 예전에는 글자 수만 셌는데, 사진은 글자가 0이라
/// 사진이 가득한 방이 오히려 캐시를 못 받았습니다. 사진 한 장이 대화 두어 턴만큼 무거우니
/// 정확히 거꾸로 동작한 셈입니다.
///
/// 계수는 실제 사용량 장부에서 뽑았습니다. 대화방 두 곳의 요청별 구성과 총 입력 토큰을
/// 연립해서 풀었고, 타일당 258 말고는 앞뒤가 맞는 해가 없었습니다.
public enum TokenEstimator {
    /// 한국어 대화 기준입니다. 영어는 글자당 토큰이 이보다 낮아 조금 넉넉하게 잡힙니다.
    public static let tokensPerCharacter = 0.820

    /// 이미지는 타일로 잘려 들어가고 타일 하나가 258토큰입니다.
    public static let tokensPerImageTile = 258
    public static let imageTileSize = 768

    /// 크기를 못 읽은 이미지는 최소 한 타일로 칩니다. 0으로 치면 예전 버그가 되살아납니다.
    public static let fallbackImageTokens = tokensPerImageTile

    public static func textTokens(_ text: String) -> Int {
        Int((Double(text.count) * tokensPerCharacter).rounded())
    }

    public static func imageTokens(width: Int, height: Int) -> Int {
        guard width > 0, height > 0 else { return fallbackImageTokens }
        let columns = Int(ceil(Double(width) / Double(imageTileSize)))
        let rows = Int(ceil(Double(height) / Double(imageTileSize)))
        return max(1, columns * rows) * tokensPerImageTile
    }

    /// 헤더만 읽어 크기를 알아냅니다. 전체를 디코드하면 큰 스크린샷에서 눈에 띄게 느려집니다.
    public static func imageTokens(data: Data) -> Int {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            return fallbackImageTokens
        }
        return imageTokens(width: width, height: height)
    }

    public static func imageTokens(base64: String) -> Int {
        guard let data = Data(base64Encoded: base64) else { return fallbackImageTokens }
        return imageTokens(data: data)
    }

    /// Gemini `contents` 배열 하나가 몇 토큰쯤 되는지 어림합니다.
    public static func estimatedTokens(contents: [[String: Any]]) -> Int {
        contents.reduce(0) { total, item in
            guard let parts = item["parts"] as? [[String: Any]] else { return total }
            return total + parts.reduce(0) { partial, part in
                if let text = part["text"] as? String {
                    return partial + textTokens(text)
                }
                if let inline = part["inlineData"] as? [String: Any],
                   let base64 = inline["data"] as? String {
                    let mime = inline["mimeType"] as? String ?? ""
                    // PDF는 페이지 단위라 규칙이 다릅니다. 사진 한 장 몫으로만 잡아 둡니다.
                    guard mime.hasPrefix("image/") else { return partial + fallbackImageTokens }
                    return partial + imageTokens(base64: base64)
                }
                return partial
            }
        }
    }
}

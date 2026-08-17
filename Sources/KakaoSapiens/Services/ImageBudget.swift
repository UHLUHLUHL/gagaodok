import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 사진을 몇 화소로 줄여 보낼지 정합니다.
///
/// **요금이 화소 수에 비례하지 않고 타일 수에 비례합니다.** Gemini는 사진을
/// 768×768 타일로 잘라 읽고 타일 하나가 258토큰입니다. 그래서 화소를 조금 줄이는
/// 것은 대개 요금을 한 푼도 못 줄이고, 타일 하나를 없앨 때만 258토큰이 통째로 빠집니다.
///
/// 예전에는 아무것도 안 줄이고 원본을 그대로 보냈습니다. 레티나 맥에서 찍은
/// 스크린샷 한 장(3024×1964)이면 4×3 = 12타일 = 3,096토큰입니다.
/// 지금은 타일 격자를 먼저 고르고 거기 꽉 차게 줄입니다. 같은 사진이 2×1 격자의
/// 1182×768이 되어 2타일 = 516토큰입니다. **6분의 1 값입니다.** (실측)
///
/// 사진은 대화에 남아 있는 한 요청마다 다시 실리므로, 이 차이는 한 번이 아니라
/// 그 사진이 대화창에 있는 내내 매 턴 반복됩니다.
///
/// **아직 확인 못 한 것:** 맥에 붙여넣는 것은 대개 가로로 긴 화면 캡처인데,
/// 위 예에서 세로가 1964 → 768로 0.39배가 됩니다. 레티나 캡처라면 화면에서
/// 보던 크기의 0.78배쯤이라 작은 글씨가 뭉갤 수 있습니다. 실제로 안 읽히는
/// 사진이 나오면 [minimumLongSide]를 올려야 합니다. 1200으로 올리면 같은
/// 캡처가 1536×997(4타일)이 되어 화면에서 보던 크기 그대로가 됩니다.
public enum ImageBudget {
    /// 타일 한 변입니다. 요금 단위가 이 격자로 매겨집니다.
    public static let tile = TokenEstimator.imageTileSize

    /// 이 아래로는 줄이지 않습니다.
    ///
    /// 이 앱에 올라오는 사진은 대개 문제지나 손으로 푼 풀이입니다. 타일을 하나로
    /// 줄이면 긴 변이 768화소가 되는데, 그러면 작은 글씨와 지수·첨자가 뭉갭니다.
    /// 900은 **잰 값이 아니라 정한 값입니다.** 실제로 안 읽히는 사진이 나오면
    /// 올려야 할 값입니다.
    public static let minimumLongSide = 900

    /// 격자를 이 이상은 키우지 않습니다. 3×3이면 9타일 = 2,322토큰입니다.
    private static let maxSideTiles = 3

    /// JPEG로 다시 인코딩할 때의 품질입니다. 글씨가 뭉개지지 않는 선에서 잡았습니다.
    private static let jpegQuality = 0.85

    public struct Plan: Equatable {
        public let width: Int
        public let height: Int
        public let tiles: Int

        public var tokens: Int { tiles * TokenEstimator.tokensPerImageTile }
    }

    public static func tiles(width: Int, height: Int) -> Int {
        guard width > 0, height > 0 else { return 1 }
        let columns = Int(ceil(Double(width) / Double(tile)))
        let rows = Int(ceil(Double(height) / Double(tile)))
        return max(1, columns * rows)
    }

    /// 이 크기의 사진을 어떤 크기로 보낼지 정합니다.
    ///
    /// 타일이 적은 격자부터 넣어 보고, 줄인 결과의 긴 변이 `minimumLongSide` 이상이면
    /// 그걸로 정합니다. 타일 수가 같으면 더 큰 쪽을 고릅니다.
    public static func plan(width: Int, height: Int) -> Plan {
        guard width > 0, height > 0 else { return Plan(width: width, height: height, tiles: 1) }

        // 이미 작은 사진은 그대로 둡니다. 키우면 타일만 늘고 보이는 것은 그대로입니다.
        if max(width, height) <= minimumLongSide {
            return Plan(width: width, height: height, tiles: tiles(width: width, height: height))
        }

        var candidates: [Plan] = []
        for columns in 1...maxSideTiles {
            for rows in 1...maxSideTiles {
                // 격자에 꽉 차게 줄입니다. 키우지는 않습니다.
                let scale = min(
                    min(Double(tile * columns) / Double(width), Double(tile * rows) / Double(height)),
                    1.0
                )
                // 내림으로 잘라야 반올림 때문에 타일이 하나 더 생기는 일이 없습니다.
                let w = max(1, Int(floor(Double(width) * scale)))
                let h = max(1, Int(floor(Double(height) * scale)))
                guard max(w, h) >= minimumLongSide else { continue }
                candidates.append(Plan(width: w, height: h, tiles: tiles(width: w, height: h)))
            }
        }

        // 어떤 격자에도 안 맞을 만큼 극단적인 비율이면 긴 변만 맞춰 둡니다.
        let fallback: Plan = {
            let scale = min(Double(tile * maxSideTiles) / Double(max(width, height)), 1.0)
            let w = max(1, Int(floor(Double(width) * scale)))
            let h = max(1, Int(floor(Double(height) * scale)))
            return Plan(width: w, height: h, tiles: tiles(width: w, height: h))
        }()

        return candidates.min { lhs, rhs in
            if lhs.tiles != rhs.tiles { return lhs.tiles < rhs.tiles }
            return lhs.width * lhs.height > rhs.width * rhs.height
        } ?? fallback
    }

    /// 사진 데이터를 타일 격자에 맞춰 줄입니다. 줄일 것이 없으면 원본을 그대로 돌려줍니다.
    ///
    /// `CGImageSourceCreateThumbnailAtIndex`는 **디코드하면서** 줄이므로,
    /// 1200만 화소를 통째로 펼쳤다가 축소하는 것보다 훨씬 가볍습니다.
    ///
    /// - Returns: 줄인 데이터와 그 MIME 타입. 실패하면 `nil`이고, 그때는 부르는 쪽이
    ///   원본을 그대로 씁니다. 사진을 못 보내는 것보다 비싸게 보내는 것이 낫습니다.
    public static func shrink(_ data: Data) -> (data: Data, mimeType: String, fileExtension: String)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return nil }

        let target = plan(width: width, height: height)
        // 이미 타일 격자에 맞으면 다시 인코딩하지 않습니다. 손댈수록 화질만 나빠집니다.
        guard target.width < width || target.height < height else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(target.width, target.height)
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(
            destination, thumbnail,
            [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }

        // 줄였는데 오히려 커졌으면 원본을 씁니다. 아주 작은 png에서 그럴 수 있습니다.
        guard output.length < data.count else { return nil }
        return (output as Data, "image/jpeg", "jpg")
    }
}

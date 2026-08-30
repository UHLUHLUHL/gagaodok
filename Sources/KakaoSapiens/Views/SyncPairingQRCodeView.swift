import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

enum SyncPairingQRCodeRenderer {
    /// Produces pixels only. The canonical payload text is never persisted or
    /// placed on a pasteboard, URL, log, or accessibility label.
    static func cgImage(from text: String, scale: CGFloat = 8) -> CGImage? {
        guard !text.isEmpty, scale >= 1 else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(
            by: CGAffineTransform(scaleX: scale, y: scale)
        ) else { return nil }
        return CIContext(options: [.useSoftwareRenderer: false]).createCGImage(
            output,
            from: output.extent
        )
    }
}

struct SyncPairingQRCodeView: View {
    let text: String

    var body: some View {
        Group {
            if let image = SyncPairingQRCodeRenderer.cgImage(from: text) {
                Image(image, scale: 1, label: Text("새 기기 합류 QR"))
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
            } else {
                Text("QR을 만들지 못했습니다")
            }
        }
    }
}

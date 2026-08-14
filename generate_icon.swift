import Cocoa
import CoreGraphics

func createKakaoAppIcon() -> NSImage {
    let size: CGFloat = 1024
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    
    guard let ctx = NSGraphicsContext.current?.cgContext else {
        img.unlockFocus()
        return img
    }

    // ImageGen으로 확정한 브랜드 원본을 macOS 아이콘 안전 영역 안에 배치합니다.
    // 원본 파일의 모서리 배경은 스퀘어클 클리핑으로 제거합니다.
    if let source = NSImage(contentsOfFile: "AppIconSource.png") {
        ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))
        let sourceRect = CGRect(x: 100, y: 100, width: 824, height: 824)
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: sourceRect, cornerWidth: 185, cornerHeight: 185, transform: nil))
        ctx.clip()
        source.draw(
            in: sourceRect,
            from: NSRect(origin: .zero, size: source.size),
            operation: .copy,
            fraction: 1
        )
        ctx.restoreGState()
        img.unlockFocus()
        return img
    }
    
    // 투명 배경 (흰색 테두리 원천 방지)
    ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))
    
    // macOS Big Sur+ 정석 아이콘 규격: 1024x1024 캔버스 내 824x824 스퀘어클 (중앙 배치)
    let iconRect = CGRect(x: 100, y: 100, width: 824, height: 824)
    let cornerRadius: CGFloat = 185
    
    // 1. 은은한 macOS 시스템 드롭 섀도우
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -20), blur: 36, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.22))
    
    // 2. 사피엔스 시그니처 다크 브라운 스퀘어클 배경 (#381E1F)
    let squirclePath = CGPath(roundedRect: iconRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    ctx.addPath(squirclePath)
    ctx.setFillColor(CGColor(red: 0.224, green: 0.118, blue: 0.122, alpha: 1.0)) // #381E1F
    ctx.fillPath()
    ctx.restoreGState()
    
    // 3. 색 위치를 뒤집은 카카오 옐로우 말풍선 (#FEE500)
    let bubbleColor = CGColor(red: 0.996, green: 0.898, blue: 0.0, alpha: 1.0) // #FEE500
    ctx.setFillColor(bubbleColor)
    
    let bubblePath = CGMutablePath()
    // 말풍선 본체 (타원형/라운드 렉트)
    let bCenter = CGPoint(x: 512, y: 535)
    let bWidth: CGFloat = 530
    let bHeight: CGFloat = 430
    let bRect = CGRect(x: bCenter.x - bWidth/2, y: bCenter.y - bHeight/2, width: bWidth, height: bHeight)
    
    bubblePath.addEllipse(in: bRect)
    
    // 말꼬리 (좌하단으로 향하는 시그니처 꼬리)
    let tailPath = CGMutablePath()
    tailPath.move(to: CGPoint(x: 350, y: 400))
    tailPath.addQuadCurve(to: CGPoint(x: 275, y: 260), control: CGPoint(x: 310, y: 320))
    tailPath.addQuadCurve(to: CGPoint(x: 430, y: 360), control: CGPoint(x: 355, y: 295))
    tailPath.closeSubpath()
    
    ctx.addPath(bubblePath)
    ctx.fillPath()
    ctx.addPath(tailPath)
    ctx.fillPath()
    
    // 4. 'TALK' 다크 브라운 텍스트 (#381E1F)
    let font = NSFont(name: "Arial-Black", size: 130) ?? NSFont.systemFont(ofSize: 130, weight: .heavy)
    let text = "TALK"
    let textAttrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor(red: 0.224, green: 0.118, blue: 0.122, alpha: 1.0),
        .kern: 3.0
    ]
    let attrStr = NSAttributedString(string: text, attributes: textAttrs)
    let textSize = attrStr.size()
    let textPoint = NSPoint(x: bCenter.x - textSize.width / 2, y: bCenter.y - textSize.height / 2 - 4)
    
    attrStr.draw(at: textPoint)
    
    img.unlockFocus()
    return img
}

// 1024x1024 고해상도 생성 및 iconset 저장
let masterIcon = createKakaoAppIcon()
let fileManager = FileManager.default
let iconsetDir = "AppIcon.iconset"

try? fileManager.removeItem(atPath: iconsetDir)
try? fileManager.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true, attributes: nil)

let sizes: [(String, CGFloat)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for (name, px) in sizes {
    let resized = NSImage(size: NSSize(width: px, height: px))
    resized.lockFocus()
    masterIcon.draw(in: NSRect(x: 0, y: 0, width: px, height: px), from: NSRect(x: 0, y: 0, width: 1024, height: 1024), operation: .copy, fraction: 1.0)
    resized.unlockFocus()
    
    if let tiff = resized.tiffRepresentation,
       let bitmap = NSBitmapImageRep(data: tiff),
       let png = bitmap.representation(using: .png, properties: [:]) {
        let dest = "\(iconsetDir)/\(name)"
        try? png.write(to: URL(fileURLWithPath: dest))
    }
}

print("✅ AppIcon.iconset created successfully!")

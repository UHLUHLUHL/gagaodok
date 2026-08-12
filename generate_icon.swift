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
    
    // 투명 배경 (흰색 테두리 원천 방지)
    ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))
    
    // macOS Big Sur+ 정석 아이콘 규격: 1024x1024 캔버스 내 824x824 스퀘어클 (중앙 배치)
    let iconRect = CGRect(x: 100, y: 100, width: 824, height: 824)
    let cornerRadius: CGFloat = 185
    
    // 1. 은은한 macOS 시스템 드롭 섀도우
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -20), blur: 36, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.22))
    
    // 2. 카카오톡 시그니처 옐로우 스퀘어클 배경 (#FEE500)
    let squirclePath = CGPath(roundedRect: iconRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    ctx.addPath(squirclePath)
    ctx.setFillColor(CGColor(red: 0.996, green: 0.898, blue: 0.0, alpha: 1.0)) // #FEE500
    ctx.fillPath()
    ctx.restoreGState()
    
    // 3. 내부 미세 그라디언트 하이라이트 (더욱 입체감 있고 프리미엄한 룩)
    ctx.saveGState()
    ctx.addPath(squirclePath)
    ctx.clip()
    
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let gradColors = [
        CGColor(red: 1.0, green: 0.93, blue: 0.15, alpha: 0.35),
        CGColor(red: 0.98, green: 0.86, blue: 0.0, alpha: 0.0)
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: colorSpace, colors: gradColors, locations: [0.0, 1.0]) {
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 300), options: [])
    }
    
    // 4. 카카오톡 다크 브라운 말풍선 (#381E1F)
    let bubbleColor = CGColor(red: 0.224, green: 0.118, blue: 0.122, alpha: 1.0) // #381E1F
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
    
    // 5. 'TALK' 옐로우 텍스트 (#FEE500)
    let font = NSFont(name: "Arial-Black", size: 130) ?? NSFont.systemFont(ofSize: 130, weight: .heavy)
    let text = "TALK"
    let textAttrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor(red: 0.996, green: 0.898, blue: 0.0, alpha: 1.0),
        .kern: 3.0
    ]
    let attrStr = NSAttributedString(string: text, attributes: textAttrs)
    let textSize = attrStr.size()
    let textPoint = NSPoint(x: bCenter.x - textSize.width / 2, y: bCenter.y - textSize.height / 2 - 4)
    
    attrStr.draw(at: textPoint)
    
    ctx.restoreGState()
    
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

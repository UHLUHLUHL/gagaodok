import Foundation
import AppKit
import CoreGraphics

public struct MathGraphSpec {
    public var title: String
    public var type: GraphType // .parametric or .cartesian
    public var xExpr: String // for parametric
    public var yExpr: String // for parametric or cartesian
    public var tangentSlope: Double?
    public var tangentPoint: CGPoint?
    public var tMin: Double
    public var tMax: Double
    public var xMin: Double
    public var xMax: Double
    public var yMin: Double
    public var yMax: Double
    
    public enum GraphType {
        case parametric
        case cartesian
    }
    
    public init(
        title: String = "수학 그래프",
        type: GraphType = .cartesian,
        xExpr: String = "t",
        yExpr: String = "x",
        tangentSlope: Double? = nil,
        tangentPoint: CGPoint? = nil,
        tMin: Double = 0,
        tMax: Double = Double.pi * 2,
        xMin: Double = -5,
        xMax: Double = 5,
        yMin: Double = -5,
        yMax: Double = 5
    ) {
        self.title = title
        self.type = type
        self.xExpr = xExpr
        self.yExpr = yExpr
        self.tangentSlope = tangentSlope
        self.tangentPoint = tangentPoint
        self.tMin = tMin
        self.tMax = tMax
        self.xMin = xMin
        self.xMax = xMax
        self.yMin = yMin
        self.yMax = yMax
    }
}

public class MathGraphRenderer {
    public static let shared = MathGraphRenderer()
    
    private init() {}
    
    // MARK: - [GRAPH: ...] 태그 파싱
    public static func extractGraphSpecs(from text: String) -> (cleanedText: String, specs: [MathGraphSpec]) {
        var specs: [MathGraphSpec] = []
        var cleaned = text
        
        let pattern = "\\[GRAPH:([^\\]]+)\\]"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return (text, [])
        }
        
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: text.utf16.count))
        
        for match in matches {
            if let fullRange = Range(match.range, in: text),
               let paramRange = Range(match.range(at: 1), in: text) {
                let paramStr = String(text[paramRange])
                if let spec = parseSpec(from: paramStr) {
                    specs.append(spec)
                }
                cleaned = cleaned.replacingOccurrences(of: String(text[fullRange]), with: "")
            }
        }
        
        return (cleaned.trimmingCharacters(in: .whitespacesAndNewlines), specs)
    }
    
    private static func parseSpec(from str: String) -> MathGraphSpec? {
        var spec = MathGraphSpec()
        
        let components = str.components(separatedBy: ",")
        for comp in components {
            let pair = comp.components(separatedBy: "=")
            guard pair.count == 2 else { continue }
            let key = pair[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let val = pair[1].trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\"", with: "")
            
            switch key {
            case "title":
                spec.title = val
            case "type":
                if val == "parametric" { spec.type = .parametric }
                else { spec.type = .cartesian }
            case "x":
                spec.xExpr = val
            case "y", "func", "function":
                spec.yExpr = val
            case "tmin", "t_min":
                spec.tMin = Double(val) ?? 0
            case "tmax", "t_max":
                spec.tMax = Double(val) ?? (Double.pi * 2)
            case "xmin", "x_min":
                spec.xMin = Double(val) ?? -5
            case "xmax", "x_max":
                spec.xMax = Double(val) ?? 5
            case "ymin", "y_min":
                spec.yMin = Double(val) ?? -5
            case "ymax", "y_max":
                spec.yMax = Double(val) ?? 5
            case "slope", "m":
                spec.tangentSlope = Double(val)
            case "point":
                let xy = val.components(separatedBy: ":")
                if xy.count == 2, let px = Double(xy[0]), let py = Double(xy[1]) {
                    spec.tangentPoint = CGPoint(x: px, y: py)
                }
            default:
                break
            }
        }
        
        return spec
    }
    
    // MARK: - CoreGraphics 고해상도 그래프 렌더링
    public func renderGraph(spec: MathGraphSpec) -> NSImage {
        let width: CGFloat = 800
        let height: CGFloat = 600
        let padding: CGFloat = 60
        
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        
        guard let ctx = NSGraphicsContext.current?.cgContext else {
            image.unlockFocus()
            return image
        }
        
        // 1. 부드러운 화이트 배경 & 둥근 테두리
        ctx.setFillColor(CGColor(red: 0.98, green: 0.985, blue: 0.99, alpha: 1.0))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        
        // 그래프 뷰포트
        let plotRect = CGRect(x: padding, y: padding, width: width - padding * 2, height: height - padding * 2 - 30)
        ctx.setFillColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0))
        ctx.fill(plotRect)
        
        // 2. 그리드 (격자선)
        let xMin = spec.xMin
        let xMax = spec.xMax
        let yMin = spec.yMin
        let yMax = spec.yMax
        
        func toScreenX(_ x: Double) -> CGFloat {
            plotRect.minX + CGFloat((x - xMin) / (xMax - xMin)) * plotRect.width
        }
        
        func toScreenY(_ y: Double) -> CGFloat {
            plotRect.minY + CGFloat((y - yMin) / (yMax - yMin)) * plotRect.height
        }
        
        ctx.setStrokeColor(CGColor(red: 0.90, green: 0.92, blue: 0.94, alpha: 1.0))
        ctx.setLineWidth(1.0)
        
        // X 그리드
        let xStep = (xMax - xMin) / 10.0
        for i in 0...10 {
            let xVal = xMin + Double(i) * xStep
            let sx = toScreenX(xVal)
            ctx.move(to: CGPoint(x: sx, y: plotRect.minY))
            ctx.addLine(to: CGPoint(x: sx, y: plotRect.maxY))
        }
        
        // Y 그리드
        let yStep = (yMax - yMin) / 8.0
        for i in 0...8 {
            let yVal = yMin + Double(i) * yStep
            let sy = toScreenY(yVal)
            ctx.move(to: CGPoint(x: plotRect.minX, y: sy))
            ctx.addLine(to: CGPoint(x: plotRect.maxX, y: sy))
        }
        ctx.strokePath()
        
        // 3. X축 & Y축 (메인 축)
        ctx.setStrokeColor(CGColor(red: 0.25, green: 0.28, blue: 0.32, alpha: 1.0))
        ctx.setLineWidth(1.8)
        
        let originX = toScreenX(0)
        let originY = toScreenY(0)
        
        // X축
        if originY >= plotRect.minY && originY <= plotRect.maxY {
            ctx.move(to: CGPoint(x: plotRect.minX, y: originY))
            ctx.addLine(to: CGPoint(x: plotRect.maxX, y: originY))
        }
        // Y축
        if originX >= plotRect.minX && originX <= plotRect.maxX {
            ctx.move(to: CGPoint(x: originX, y: plotRect.minY))
            ctx.addLine(to: CGPoint(x: originX, y: plotRect.maxY))
        }
        ctx.strokePath()
        
        // 4. 곡선 렌더링
        ctx.saveGState()
        ctx.clip(to: plotRect)
        
        if spec.type == .parametric {
            // 매개변수 곡선 x(t), y(t)
            ctx.setStrokeColor(CGColor(red: 0.16, green: 0.50, blue: 0.95, alpha: 1.0)) // 사파이어 블루
            ctx.setLineWidth(3.0)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            
            let steps = 400
            let dt = (spec.tMax - spec.tMin) / Double(steps)
            // 식은 한 번만 파싱하고 점마다 값만 구합니다.
            let xFormula = MathExpression(spec.xExpr)
            let yFormula = MathExpression(spec.yExpr)
            var penIsDown = false

            for i in 0...steps {
                let t = spec.tMin + Double(i) * dt
                guard let x = xFormula?.value(["t": t]), let y = yFormula?.value(["t": t]) else {
                    // 정의되지 않는 지점에서는 선을 끊습니다.
                    penIsDown = false
                    continue
                }
                let point = CGPoint(x: toScreenX(x), y: toScreenY(y))
                if penIsDown {
                    ctx.addLine(to: point)
                } else {
                    ctx.move(to: point)
                    penIsDown = true
                }
            }
            ctx.strokePath()
        } else {
            // 일반 직교함수 y = f(x)
            ctx.setStrokeColor(CGColor(red: 0.16, green: 0.50, blue: 0.95, alpha: 1.0))
            ctx.setLineWidth(3.0)
            ctx.setLineCap(.round)
            
            let steps = 500
            let dx = (xMax - xMin) / Double(steps)
            let formula = MathExpression(spec.yExpr)
            var penIsDown = false
            // 세로 점근선을 가로지르며 화면을 종단하는 가짜 선이 생기지 않도록,
            // 값이 표시 범위를 크게 벗어나면 선을 끊습니다. (tan(x), 1/x 등)
            let verticalGuard = (yMax - yMin) * 4

            for i in 0...steps {
                let x = xMin + Double(i) * dx
                guard let y = formula?.value(["x": x]), abs(y) < abs(verticalGuard) + abs(yMax) + abs(yMin) else {
                    penIsDown = false
                    continue
                }
                let point = CGPoint(x: toScreenX(x), y: toScreenY(y))
                if penIsDown {
                    ctx.addLine(to: point)
                } else {
                    ctx.move(to: point)
                    penIsDown = true
                }
            }
            ctx.strokePath()
        }
        
        // 5. 접선 및 접점 렌더링 (있는 경우)
        if let pt = spec.tangentPoint, let slope = spec.tangentSlope {
            // 접선: y - y0 = m(x - x0) -> y = m(x - x0) + y0
            ctx.setStrokeColor(CGColor(red: 0.94, green: 0.25, blue: 0.25, alpha: 0.85)) // 레드
            ctx.setLineWidth(2.0)
            ctx.setLineDash(phase: 0, lengths: [6, 4])
            
            let sx1 = plotRect.minX
            let sx2 = plotRect.maxX
            let x1 = xMin
            let x2 = xMax
            let y1 = slope * (x1 - Double(pt.x)) + Double(pt.y)
            let y2 = slope * (x2 - Double(pt.x)) + Double(pt.y)
            
            ctx.move(to: CGPoint(x: sx1, y: toScreenY(y1)))
            ctx.addLine(to: CGPoint(x: sx2, y: toScreenY(y2)))
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
            
            // 접점 마킹
            let sptX = toScreenX(Double(pt.x))
            let sptY = toScreenY(Double(pt.y))
            ctx.setFillColor(CGColor(red: 0.94, green: 0.25, blue: 0.25, alpha: 1.0))
            ctx.fillEllipse(in: CGRect(x: sptX - 5, y: sptY - 5, width: 10, height: 10))
            ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1.0))
            ctx.setLineWidth(2)
            ctx.strokeEllipse(in: CGRect(x: sptX - 5, y: sptY - 5, width: 10, height: 10))
        }
        
        ctx.restoreGState()
        
        // 6. 외곽 테두리
        ctx.setStrokeColor(CGColor(red: 0.80, green: 0.82, blue: 0.85, alpha: 1.0))
        ctx.setLineWidth(1.2)
        ctx.stroke(plotRect)
        
        // 7. 상단 타이틀 텍스트
        let titleAttr: [NSAttributedString.Key: Any] = [
            .font: NSFont(name: "Pretendard-Bold", size: 16) ?? NSFont.boldSystemFont(ofSize: 16),
            .foregroundColor: NSColor(red: 0.15, green: 0.15, blue: 0.15, alpha: 1.0)
        ]
        let titleString = NSAttributedString(string: spec.title, attributes: titleAttr)
        titleString.draw(at: NSPoint(x: padding, y: height - padding + 4))
        
        image.unlockFocus()
        return image
    }
    
    // MARK: - 수식 평가
    // 파싱에 실패하거나 정의역을 벗어난 지점은 nil을 돌려주고, 호출부에서 그 구간을 건너뜁니다.
    // 예전처럼 해석 못 한 식을 y = x로 대신 그리지 않습니다.

    /// 그래프를 그릴 수 있는 식인지 미리 확인합니다.
    /// 해석하지 못하는 식이면 그래프 자체를 만들지 않는 편이 틀린 그림보다 낫습니다.
    public static func canRender(_ spec: MathGraphSpec) -> Bool {
        if spec.type == .parametric {
            guard let x = MathExpression(spec.xExpr), let y = MathExpression(spec.yExpr) else { return false }
            // 표본 몇 점이라도 값이 나와야 의미가 있습니다.
            let samples = stride(from: spec.tMin, through: spec.tMax, by: max((spec.tMax - spec.tMin) / 12, 0.0001))
            return samples.contains { x.value(["t": $0]) != nil && y.value(["t": $0]) != nil }
        }
        guard let formula = MathExpression(spec.yExpr) else { return false }
        let samples = stride(from: spec.xMin, through: spec.xMax, by: max((spec.xMax - spec.xMin) / 12, 0.0001))
        return samples.contains { formula.value(["x": $0]) != nil }
    }
}

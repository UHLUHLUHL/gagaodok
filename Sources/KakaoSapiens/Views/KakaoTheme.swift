import SwiftUI
import AppKit

/// 라이트·다크에서 각각 쓸 색을 한곳에 모아 둡니다.
///
/// 값은 실제 카카오톡을 다크 모드로 바꿔 화면에서 뽑았습니다.
/// 채팅방 배경 #111111, 목록·헤더 #1A1A1A, 사이드바 #222222입니다.
/// 사이드바가 목록보다 밝은 것이 특징인데, 라이트 모드에서는 반대입니다.
///
/// `NSColor`의 동적 공급자를 쓰므로 색 자체가 현재 외형을 보고 알아서 갈라집니다.
/// 뷰마다 colorScheme을 받아 분기하지 않아도 되고, 웹뷰가 아닌 기본 컨트롤도 함께 따라옵니다.
public enum KakaoTheme {
    static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: nsDynamic(light: light, dark: dark))
    }

    /// AppKit 컨트롤에 그대로 물릴 수 있는 동적 색입니다.
    ///
    /// `NSTextView`처럼 SwiftUI를 거치지 않는 뷰는 `Color`를 못 받습니다.
    /// 그렇다고 고정 색을 박으면 한쪽 외형에서 바탕과 같은 색이 되어 안 보입니다.
    static func nsDynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }

    static func hex(_ value: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    static func white(_ w: CGFloat, _ a: CGFloat = 1) -> NSColor {
        NSColor(white: w, alpha: a)
    }

    // MARK: - 바탕

    /// 대화방 바탕. 라이트는 카카오톡 시그니처 하늘색입니다.
    public static let chatBackground = dynamic(light: hex(0xBACEE0), dark: hex(0x111111))
    /// 대화방 상단 바. 라이트에서는 바탕과 같은 색으로 이어집니다.
    public static let chatHeader = dynamic(light: hex(0xBACEE0), dark: hex(0x1A1A1A))
    /// 목록·설정 등 흰 판.
    public static let surface = dynamic(light: hex(0xFFFFFF), dark: hex(0x1A1A1A))
    /// 왼쪽 세로 막대.
    public static let rail = dynamic(light: hex(0xF7F7F8), dark: hex(0x222222))
    /// 살짝 눌린 판. 검색창 안이나 카드 배경에 씁니다.
    public static let sunken = dynamic(light: hex(0xF2F3F5), dark: hex(0x262626))
    /// 마우스를 올린 행.
    public static let rowHover = dynamic(light: hex(0xF0F2F5), dark: hex(0x2A2A2A))

    // MARK: - 말풍선

    /// 내 말풍선. 카카오 옐로우는 브랜드 색이라 다크에서도 그대로 둡니다.
    public static let bubbleMine = Color(nsColor: hex(0xFEE500))
    /// 상대 말풍선. 다크 값만 화면에서 못 재 추정했습니다.
    /// 나와의 채팅에는 받은 말풍선이 없어서, 바탕(#111)에서 한 단 떠 보이는 값으로 잡았습니다.
    public static let bubbleTheirs = dynamic(light: hex(0xFFFFFF), dark: hex(0x2B2B2B))
    /// 말풍선 안 글자.
    public static let bubbleMineText = Color(nsColor: hex(0x1A1A1A))
    public static let bubbleTheirsText = dynamic(light: hex(0x1A1A1A), dark: hex(0xECECEC))
    /// 날짜 구분선 알약.
    public static let dateDivider = dynamic(light: white(0, 0.10), dark: hex(0x2E2E2E))
    public static let dateDividerText = dynamic(light: white(0, 0.55), dark: hex(0xB8B8B8))

    // MARK: - 글자

    public static let textPrimary = dynamic(light: hex(0x1A1A1A), dark: hex(0xECECEC))
    /// `textPrimary`와 같은 색의 AppKit판입니다. 입력창의 `NSTextView`가 씁니다.
    public static let nsTextPrimary = nsDynamic(light: hex(0x1A1A1A), dark: hex(0xECECEC))
    /// 입력창 커서입니다. 알파를 나중에 씌우지 않고 양쪽 값에 미리 넣습니다.
    /// 동적 색에 `withAlphaComponent`를 걸면 그 자리에서 한쪽으로 굳을 수 있습니다.
    public static let nsCaret = nsDynamic(
        light: hex(0x1A1A1A).withAlphaComponent(0.85),
        dark: hex(0xECECEC).withAlphaComponent(0.85)
    )
    public static let textSecondary = dynamic(light: white(0, 0.58), dark: hex(0x9A9A9A))
    public static let textTertiary = dynamic(light: white(0, 0.40), dark: hex(0x6E6E6E))
    /// 대화방 상단 바 위의 글자·아이콘. 라이트에서는 하늘색 위라 검정 계열입니다.
    public static let onChatHeader = dynamic(light: white(0, 0.78), dark: hex(0xE4E4E4))
    public static let onChatHeaderDim = dynamic(light: white(0, 0.45), dark: hex(0x9A9A9A))

    // MARK: - 선과 강조

    public static let hairline = dynamic(light: white(0, 0.08), dark: white(1, 0.10))
    public static let border = dynamic(light: white(0, 0.14), dark: white(1, 0.16))
    /// 드래그로 고른 말풍선에 덧씌우는 색.
    public static let selection = dynamic(light: white(0, 0.16), dark: white(1, 0.18))
    /// 검색 결과 표시. 노란 말풍선 위에서도 보이도록 파랑을 씁니다.
    public static let searchHit = dynamic(light: hex(0xA8D9FF), dark: hex(0x2C5A88))
    public static let searchHitCurrent = dynamic(light: hex(0x59A8FF), dark: hex(0x1F6FBF))
}

/// 앱 전체 화면 모드입니다. 카카오톡 환경설정의 '화면 모드'와 같은 구성입니다.
public enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .system: return "시스템 설정"
        case .light: return "라이트 모드"
        case .dark: return "다크 모드"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

public final class AppearanceManager: ObservableObject {
    public static let shared = AppearanceManager()

    private static let key = "appearanceMode"

    @Published public var mode: AppearanceMode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: Self.key)
            apply()
        }
    }

    private init() {
        let saved = UserDefaults.standard.string(forKey: Self.key) ?? ""
        mode = AppearanceMode(rawValue: saved) ?? .system
    }

    /// 앱 전체 외형을 바꿉니다. 동적 색은 이 값을 보고 스스로 갈라집니다.
    public func apply() {
        NSApp?.appearance = mode.nsAppearance
    }
}

/// 얇은 구분선입니다.
///
/// SwiftUI의 `Divider()`는 다크 모드에서 순백(#FFFFFF)으로 그려져 화면을 가릅니다.
/// 실제로 재 보고 알았습니다. 색을 직접 정해 그립니다.
public struct HairlineDivider: View {
    var axis: Axis
    var color: Color

    public init(_ axis: Axis = .horizontal, color: Color = KakaoTheme.hairline) {
        self.axis = axis
        self.color = color
    }

    public var body: some View {
        Rectangle()
            .fill(color)
            .frame(
                width: axis == .vertical ? 1 : nil,
                height: axis == .horizontal ? 1 : nil
            )
    }
}

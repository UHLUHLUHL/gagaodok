import SwiftUI
import AppKit

// 앱 창을 띄우지 않고 아이콘만 따로 그려 PNG로 떨어뜨립니다.
// 창이 다른 데스크톱에 있으면 화면 캡처가 전부 검게 나와서, 화면에 의존하지 않는
// 방법이 필요했습니다. 뷰는 앱과 같은 파일을 그대로 씁니다.

let scale: CGFloat = 8

@MainActor
func shoot<V: View>(_ view: V, size: CGSize, name: String) {
    let renderer = ImageRenderer(content:
        view.frame(width: size.width, height: size.height)
            .padding(4)
            .background(Color.white)
    )
    renderer.scale = scale
    guard let cg = renderer.cgImage else { print("fail \(name)"); return }
    let rep = NSBitmapImageRep(cgImage: cg)
    guard let data = rep.representation(using: .png, properties: [:]) else { return }
    try? data.write(to: URL(fileURLWithPath: "out_\(name).png"))
    print("\(name) \(cg.width)x\(cg.height)")
}

/// 앱의 헤더 오른쪽 묶음을 그대로 옮겨 옵니다. 버튼 28, 사이 13 → 중심 간격 41.
@MainActor
func headerRow<A: View, B: View>(_ a: A, _ aSize: CGSize, _ b: B, _ bSize: CGSize) -> some View {
    HStack(spacing: 0) {
        a.frame(width: aSize.width, height: aSize.height)
            .frame(width: 28, height: 28)
        Spacer().frame(width: 13)
        b.frame(width: bSize.width, height: bSize.height)
            .frame(width: 28, height: 28)
    }
}

/// 앱의 왼쪽 레일을 그대로 옮겨 옵니다. 버튼 48 x 44, 사이 13.5 → 중심 간격 57.5.
@MainActor
func railColumn() -> some View {
    VStack(spacing: 13.5) {
        PersonGlyph(color: .black).frame(width: 23, height: 23)
            .frame(width: 48, height: 44)
        ChatBubbleGlyph(color: .black).frame(width: 22, height: 22)
            .frame(width: 48, height: 44)
    }
}

MainActor.assumeIsolated {
    // 앱에서 쓰는 프레임 그대로입니다.
    shoot(MagnifierIcon(color: .black), size: CGSize(width: 16.5, height: 16.5), name: "magnifier")
    shoot(ComposeChatIcon(color: .black), size: CGSize(width: 19.5, height: 16.0), name: "compose")
    shoot(AddFriendIcon(color: .black), size: CGSize(width: 22, height: 17), name: "addfriend")
    shoot(PersonGlyph(color: .black), size: CGSize(width: 23, height: 23), name: "rail_person")
    shoot(ChatBubbleGlyph(color: .black), size: CGSize(width: 22, height: 22), name: "rail_chat")

    // 묶음으로도 찍어 간격과 높이를 확인합니다.
    shoot(headerRow(MagnifierIcon(color: .black), CGSize(width: 16.5, height: 16.5),
                    ComposeChatIcon(color: .black), CGSize(width: 19.5, height: 16)),
          size: CGSize(width: 69, height: 28), name: "row_chats")
    shoot(headerRow(MagnifierIcon(color: .black), CGSize(width: 16.5, height: 16.5),
                    AddFriendIcon(color: .black), CGSize(width: 22, height: 17)),
          size: CGSize(width: 69, height: 28), name: "row_friends")
    shoot(railColumn(), size: CGSize(width: 48, height: 101.5), name: "rail")
}

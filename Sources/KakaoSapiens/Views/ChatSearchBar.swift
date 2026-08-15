import SwiftUI
import AppKit

/// 대화방 안에서 말을 찾습니다.
///
/// 카카오톡처럼 헤더 아래에 줄이 하나 열리고, 찾은 개수와 위아래 이동 버튼이 붙습니다.
/// 최신 대화부터 보는 자리이므로 아래쪽(최근)이 1번이고 위로 올라갈수록 번호가 커집니다.
public struct ChatSearchBar: View {
    @Binding var query: String
    let hitCount: Int
    let currentIndex: Int      // 0부터
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onClose: () -> Void

    @FocusState private var isFocused: Bool

    public init(
        query: Binding<String>,
        hitCount: Int,
        currentIndex: Int,
        onPrevious: @escaping () -> Void,
        onNext: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        self._query = query
        self.hitCount = hitCount
        self.currentIndex = currentIndex
        self.onPrevious = onPrevious
        self.onNext = onNext
        self.onClose = onClose
    }

    private var hasQuery: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    public var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Color.black.opacity(0.4))

            ZStack(alignment: .leading) {
                if query.isEmpty {
                    Text("대화 내용 검색")
                        .font(.custom("Pretendard-Regular", size: 13))
                        .foregroundColor(Color.black.opacity(0.32))
                        .allowsHitTesting(false)
                }
                TextField("", text: $query)
                    .textFieldStyle(.plain)
                    .font(.custom("Pretendard-Regular", size: 13))
                    .foregroundColor(Color(red: 0.1, green: 0.1, blue: 0.1))
                    .focused($isFocused)
                    .onSubmit(onNext)
            }

            if hasQuery {
                Text(hitCount == 0 ? "없음" : "\(currentIndex + 1)/\(hitCount)")
                    .font(.custom("Pretendard-Regular", size: 11.5))
                    .foregroundColor(Color.black.opacity(hitCount == 0 ? 0.35 : 0.55))
                    .monospacedDigit()

                arrowButton("chevron.up", action: onPrevious)
                arrowButton("chevron.down", action: onNext)
            }

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color.black.opacity(0.45))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(Color.white)
        .overlay(Divider(), alignment: .bottom)
        .environment(\.colorScheme, .light)
        .onAppear { isFocused = true }
    }

    @ViewBuilder
    private func arrowButton(_ name: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(hitCount == 0 ? Color.black.opacity(0.2) : Color.black.opacity(0.6))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .disabled(hitCount == 0)
    }
}

/// 찾은 말을 노랗게 칠한 글을 만듭니다.
///
/// 수식 말풍선은 웹뷰로 그려서 여기서 손대지 못합니다. 그쪽은 칠하지 않고 세기와 이동만 됩니다.
public enum SearchHighlighter {
    public static func attributed(_ text: String, query: String, isCurrent: Bool) -> AttributedString {
        var result = AttributedString(text)
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return result }

        var searchRange = text.startIndex..<text.endIndex
        while let found = text.range(of: needle, options: .caseInsensitive, range: searchRange) {
            if let lower = AttributedString.Index(found.lowerBound, within: result),
               let upper = AttributedString.Index(found.upperBound, within: result) {
                // 노란 말풍선 위에서도 보여야 하므로 노랑 계열을 쓰지 않습니다.
                // 흰 배경과 카카오 옐로우 양쪽에서 모두 눈에 띄는 파랑으로 칠합니다.
                result[lower..<upper].backgroundColor = isCurrent
                    ? Color(red: 0.35, green: 0.66, blue: 1.0)
                    : Color(red: 0.66, green: 0.85, blue: 1.0)
            }
            guard found.upperBound < text.endIndex else { break }
            searchRange = found.upperBound..<text.endIndex
        }
        return result
    }
}

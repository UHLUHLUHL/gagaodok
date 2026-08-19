import SwiftUI
import AppKit

public struct MessageBubbleView: View {
    let message: ChatMessage
    let isFirstInGroup: Bool
    let isLastInGroup: Bool
    let botName: String
    let customAvatar: NSImage?
    let isEditingThisMessage: Bool
    let isSelected: Bool
    let isRichContentActive: Bool
    let onImageTapped: ((ChatAttachment) -> Void)?
    let onEditMessage: ((ChatMessage) -> Void)?
    let onDeleteMessage: ((ChatMessage) -> Void)?
    let allowsObsidianExport: Bool
    let onExportToObsidian: ((ChatMessage) -> Void)?
    var onAvatarTapped: (() -> Void)? = nil
    var onResendMessage: ((ChatMessage) -> Void)? = nil
    /// 검색 중일 때만 채워집니다. 찾은 글자를 노랗게 칠하는 데 씁니다.
    var searchQuery: String = ""
    /// 지금 보고 있는 검색 결과이면 더 진하게 칠합니다.
    var isCurrentSearchHit: Bool = false

    /// 검색어가 있으면 그 부분만 노랗게 칠한 글을 돌려줍니다.
    private var highlightedText: AttributedString {
        SearchHighlighter.attributed(message.text, query: searchQuery, isCurrent: isCurrentSearchHit)
    }

    /// 드래그로 고른 말풍선에 덧씌우는 회색입니다. 카카오톡과 같은 농도로 맞췄습니다.
    private var selectionTint: Color {
        isSelected ? KakaoTheme.selection : Color.clear
    }

    @State private var webViewHeight: CGFloat
    @State private var isHovering: Bool = false
    @State private var hoverDismissTask: Task<Void, Never>?
    
    public init(
        message: ChatMessage,
        isFirstInGroup: Bool,
        isLastInGroup: Bool,
        botName: String = "사피엔스",
        customAvatar: NSImage? = nil,
        isEditingThisMessage: Bool = false,
        isSelected: Bool = false,
        isRichContentActive: Bool = true,
        searchQuery: String = "",
        isCurrentSearchHit: Bool = false,
        onImageTapped: ((ChatAttachment) -> Void)? = nil,
        onEditMessage: ((ChatMessage) -> Void)? = nil,
        onDeleteMessage: ((ChatMessage) -> Void)? = nil,
        allowsObsidianExport: Bool = false,
        onExportToObsidian: ((ChatMessage) -> Void)? = nil,
        onAvatarTapped: (() -> Void)? = nil,
        onResendMessage: ((ChatMessage) -> Void)? = nil
    ) {
        self.onResendMessage = onResendMessage
        self.searchQuery = searchQuery
        self.isCurrentSearchHit = isCurrentSearchHit
        self.message = message
        self.isFirstInGroup = isFirstInGroup
        self.isLastInGroup = isLastInGroup
        self.botName = botName
        self.customAvatar = customAvatar
        self.isEditingThisMessage = isEditingThisMessage
        self.isSelected = isSelected
        self.isRichContentActive = isRichContentActive
        _webViewHeight = State(initialValue: BubbleMessageHeightCache.shared.height(for: message.id, content: message.text) ?? 30)
        self.onImageTapped = onImageTapped
        self.onEditMessage = onEditMessage
        self.onDeleteMessage = onDeleteMessage
        self.allowsObsidianExport = allowsObsidianExport
        self.onExportToObsidian = onExportToObsidian
        self.onAvatarTapped = onAvatarTapped
    }
    
    public var body: some View {
        if message.kind == .narration {
            narrationLine
        } else {
            speechRow
        }
    }

    /// 상황 묘사는 말풍선에 넣지 않습니다.
    ///
    /// 카카오톡에는 이미 "누가 들어왔습니다" 같은 안내를 가운데에 흐리게 놓는 자리가
    /// 있습니다. 그 자리를 그대로 빌려 씁니다. 새 모양을 만들지 않아도 사람들이 이미
    /// "이건 누가 한 말이 아니다"로 읽는 자리라서, 설명 없이도 바로 통합니다.
    ///
    /// 프로필 사진도 이름도 시간도 붙이지 않습니다. 말한 사람이 없기 때문입니다.
    private var narrationLine: some View {
        Text(highlightedText)
            .font(.custom("Pretendard-Regular", size: 12))
            .foregroundColor(KakaoTheme.dateDividerText)
            .multilineTextAlignment(.center)
            .lineSpacing(3)
            .frame(maxWidth: .infinity)
            // 말풍선보다 확실히 안쪽으로 넣습니다. 폭이 다르면 훑어볼 때 먼저 갈립니다.
            .padding(.horizontal, 46)
            .padding(.vertical, 7)
            .background(selectionTint)
            .contentShape(Rectangle())
    }

    private var speechRow: some View {
        HStack(alignment: .bottom, spacing: 4) {
            if message.sender == .user {
                Spacer(minLength: 36)

                // 시간과 실패 표시는 userBubbleContent 안에서 말풍선 바로 옆에 붙입니다.
                // 여기 바깥에 두면 사진이 붙은 메시지에서 사진 폭만큼 밀려나
                // 말풍선과 저 멀리 떨어져 보입니다.
                userBubbleContent
            } else {
                // 사피엔스/챗봇 말풍선 (화이트 #FFFFFF)
                sapiensBubbleWithProfile
                
                // 받은 시간
                if isLastInGroup {
                    Text(message.formattedTime)
                        .font(.custom("Pretendard-Regular", size: 9.5))
                        .foregroundColor(KakaoTheme.textTertiary)
                        .padding(.bottom, 1)
                }
                
                Spacer(minLength: 36)
            }
        }
        .padding(.horizontal, 11)
        .padding(.top, isFirstInGroup ? 4 : 1)
        .padding(.bottom, isLastInGroup ? 4 : 1)
    }
    
    /// 내 말풍선 왼편에 붙는 표시입니다. 실패했으면 재전송 배지를, 아니면 보낸 시간을 놓습니다.
    ///
    /// 말풍선과 같은 HStack 안에 두어야 사진이 붙은 메시지에서도 말풍선 옆에 딱 붙습니다.
    @ViewBuilder
    private func sideMarkers(bottomInset: CGFloat) -> some View {
        if message.deliveryFailed {
            DeliveryFailureBadge(
                onResend: { onResendMessage?(message) },
                onDelete: { onDeleteMessage?(message) }
            )
            .padding(.bottom, bottomInset)
        } else if isLastInGroup {
            Text(message.formattedTime)
                .font(.custom("Pretendard-Regular", size: 9.5))
                .foregroundColor(KakaoTheme.textTertiary)
                .padding(.bottom, bottomInset - 1)
        }
    }

    // MARK: - 내 말풍선 (User) - 플로팅 툴바로 찌그러짐 원천 방지
    @ViewBuilder
    private var userBubbleContent: some View {
        VStack(alignment: .trailing, spacing: 3) {
            if let attachment = message.attachment {
                // 사진만 보낸 메시지는 사진 옆에 시간이 붙습니다.
                HStack(alignment: .bottom, spacing: 4) {
                    if message.text.isEmpty { sideMarkers(bottomInset: 2) }
                    attachmentView(attachment: attachment, isUser: true)
                }
            }

            if !message.text.isEmpty {
                HStack(alignment: .bottom, spacing: 4) {
                    // 말풍선 아래 투명한 액션 줄(간격 2 + 높이 18)만큼 끌어올립니다.
                    sideMarkers(bottomInset: 22)
                    VStack(alignment: .trailing, spacing: 2) {
                    Group {
                        if message.containsLaTeXOrMarkdown {
                            LaTeXMarkdownView(messageID: message.id, content: message.text, isUser: true,
                                              dynamicHeight: $webViewHeight,
                                              isRenderingEnabled: isRichContentActive,
                                              searchQuery: searchQuery, isCurrentSearchHit: isCurrentSearchHit)
                                .frame(height: webViewHeight)
                                .frame(minWidth: 36, maxWidth: 300)
                        } else {
                            Text(highlightedText)
                                .font(.custom("Pretendard-Regular", size: 13.5))
                                .foregroundColor(KakaoTheme.bubbleMineText)
                                .lineSpacing(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6.5)
                    .background(
                        KakaoAlignedUserBubbleShape(isFirst: isFirstInGroup)
                            .fill(KakaoTheme.bubbleMine) // 카카오 옐로우 #FEE500
                    )
                    .overlay(
                        KakaoAlignedUserBubbleShape(isFirst: isFirstInGroup)
                            .fill(selectionTint)
                    )
                    .overlay(
                        // 수정 중 하이라이트 테두리
                        KakaoAlignedUserBubbleShape(isFirst: isFirstInGroup)
                            .stroke(isEditingThisMessage ? Color.orange : Color.clear, lineWidth: 1.5)
                    )
                    
                    // 항상 같은 높이의 액션 영역을 확보해 호버 중 말풍선이 움직이거나
                    // 커서 아래에서 버튼이 사라지지 않게 합니다.
                    HStack(spacing: 5) {
                            Button(action: {
                                onEditMessage?(message)
                            }) {
                                Image(systemName: "pencil")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(KakaoTheme.textSecondary)
                                    .frame(width: 22, height: 18)
                                    .background(Capsule().fill(KakaoTheme.surface.opacity(0.94)))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("메시지 수정")
                            .help("메시지 수정 후 다시 답변받기")
                            
                            Button(action: {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(message.text, forType: .string)
                            }) {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 9.5, weight: .semibold))
                                    .foregroundColor(KakaoTheme.textSecondary)
                                    .frame(width: 22, height: 18)
                                    .background(Capsule().fill(KakaoTheme.surface.opacity(0.94)))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("메시지 복사")
                            .help("복사")
                        }
                        .padding(.trailing, 2)
                        .frame(height: 18)
                        .contentShape(Rectangle())
                        .onHover(perform: updateHoverState)
                        .opacity(isHovering ? 1 : 0)
                        .allowsHitTesting(isHovering)
                        .animation(.easeOut(duration: 0.12), value: isHovering)
                }
                .contextMenu {
                    Button("✏️ 메시지 수정") {
                        onEditMessage?(message)
                    }
                    Button("복사") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(message.text, forType: .string)
                    }
                    Divider()
                    Button("삭제", role: .destructive) {
                        onDeleteMessage?(message)
                    }
                }
                }
            }
        }
        // 투명한 여백까지 하나의 직사각형 호버 영역으로 만듭니다. 말풍선과
        // 아래 액션 버튼 사이를 지날 때도 exit 이벤트가 발생하지 않습니다.
        .contentShape(Rectangle())
        .background(Color.clear)
        .onHover(perform: updateHoverState)
        .onDisappear {
            hoverDismissTask?.cancel()
        }
    }

    /// 자식 버튼으로 포인터가 넘어갈 때 SwiftUI가 부모의 hover-exit을 먼저
    /// 보내는 경우가 있어, 짧은 유예 시간 동안 버튼 hover 진입을 기다립니다.
    private func updateHoverState(_ hovering: Bool) {
        hoverDismissTask?.cancel()

        if hovering {
            isHovering = true
            return
        }

        hoverDismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            isHovering = false
        }
    }
    
    // MARK: - 챗봇 말풍선 (상대방)
    @ViewBuilder
    private var sapiensBubbleWithProfile: some View {
        HStack(alignment: .top, spacing: 7) {
            if isFirstInGroup {
                RoomAvatarView(image: customAvatar, size: 38)
                    .contentShape(Rectangle())
                    .onTapGesture { onAvatarTapped?() }
                    .padding(.top, 1)
            } else {
                Color.clear
                    .frame(width: 38, height: 0)
            }
            
            VStack(alignment: .leading, spacing: 2.5) {
                if isFirstInGroup {
                    Text(botName)
                        .font(.custom("Pretendard-Regular", size: 12))
                        .foregroundColor(KakaoTheme.textSecondary)
                        .padding(.leading, 1)
                }
                
                if let attachment = message.attachment {
                    attachmentView(attachment: attachment, isUser: false)
                }
                
                if !message.text.isEmpty {
                    Group {
                        if message.containsLaTeXOrMarkdown {
                            LaTeXMarkdownView(messageID: message.id, content: message.text, isUser: false,
                                              dynamicHeight: $webViewHeight,
                                              isRenderingEnabled: isRichContentActive,
                                              searchQuery: searchQuery, isCurrentSearchHit: isCurrentSearchHit)
                                .frame(height: webViewHeight)
                                .frame(minWidth: 36, maxWidth: 320)
                        } else {
                            Text(highlightedText)
                                .font(.custom("Pretendard-Regular", size: 13.5))
                                .foregroundColor(KakaoTheme.bubbleTheirsText)
                                .lineSpacing(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6.5)
                    .background(
                        KakaoAlignedSapiensBubbleShape(isFirst: isFirstInGroup)
                            .fill(KakaoTheme.bubbleTheirs)
                    )
                    .overlay(
                        KakaoAlignedSapiensBubbleShape(isFirst: isFirstInGroup)
                            .fill(selectionTint)
                    )
                    .contextMenu {
                        if allowsObsidianExport {
                            Button("Obsidian에 정리") {
                                onExportToObsidian?(message)
                            }
                            Divider()
                        }
                        Button("복사") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(message.text, forType: .string)
                        }
                        Divider()
                        Button("삭제", role: .destructive) {
                            onDeleteMessage?(message)
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - 첨부파일 / 그래프 이미지 뷰
    @ViewBuilder
    private func attachmentView(attachment: ChatAttachment, isUser: Bool) -> some View {
        if attachment.type == .image, let nsImage = attachment.nsImage {
            Button(action: {
                onImageTapped?(attachment)
            }) {
                // 카카오톡은 사진 아래에 파일명을 쓰지 않습니다.
                // 붙여넣은 사진은 이름이 UUID라 더더욱 보여줄 이유가 없습니다.
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 280, maxHeight: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(KakaoTheme.border, lineWidth: 0.5)
                    )
            }
            .buttonStyle(.plain)
        } else {
            HStack(spacing: 10) {
                Image(systemName: "doc.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.blue)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(attachment.fileName)
                        .font(.custom("Pretendard-Medium", size: 12.5))
                        .foregroundColor(isUser ? KakaoTheme.bubbleMineText : KakaoTheme.bubbleTheirsText)
                        .lineLimit(1)
                    
                    Text(attachment.formattedSize)
                        .font(.custom("Pretendard-Regular", size: 10.5))
                        .foregroundColor(KakaoTheme.textSecondary)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isUser ? KakaoTheme.bubbleMine.opacity(0.92) : Color.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(KakaoTheme.hairline, lineWidth: 0.5)
            )
        }
    }
}

// MARK: - 카카오톡 본체 정렬 상대방 말풍선 Shape
public struct KakaoAlignedSapiensBubbleShape: Shape {
    let isFirst: Bool
    
    public func path(in rect: CGRect) -> Path {
        let r: CGFloat = 10
        var path = Path()
        
        if !isFirst {
            path.addRoundedRect(in: rect, cornerRadii: RectangleCornerRadii(topLeading: r, bottomLeading: r, bottomTrailing: r, topTrailing: r), style: .continuous)
            return path
        }
        
        let tailTip = CGPoint(x: rect.minX - 4.5, y: rect.minY + 2.5)
        let topStart = CGPoint(x: rect.minX + 3.0, y: rect.minY)
        
        path.move(to: topStart)
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        path.addArc(center: CGPoint(x: rect.maxX - r, y: rect.minY + r), radius: r, startAngle: Angle(degrees: -90), endAngle: Angle(degrees: 0), clockwise: false)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addArc(center: CGPoint(x: rect.maxX - r, y: rect.maxY - r), radius: r, startAngle: Angle(degrees: 0), endAngle: Angle(degrees: 90), clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addArc(center: CGPoint(x: rect.minX + r, y: rect.maxY - r), radius: r, startAngle: Angle(degrees: 90), endAngle: Angle(degrees: 180), clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + 11.5))
        path.addQuadCurve(to: tailTip, control: CGPoint(x: rect.minX - 3.5, y: rect.minY + 7.0))
        path.addQuadCurve(to: topStart, control: CGPoint(x: rect.minX - 2.0, y: rect.minY + 0.5))
        path.closeSubpath()
        return path
    }
}

// MARK: - 카카오톡 본체 정렬 내 말풍선 Shape
public struct KakaoAlignedUserBubbleShape: Shape {
    let isFirst: Bool
    
    public func path(in rect: CGRect) -> Path {
        let r: CGFloat = 10
        var path = Path()
        
        if !isFirst {
            path.addRoundedRect(in: rect, cornerRadii: RectangleCornerRadii(topLeading: r, bottomLeading: r, bottomTrailing: r, topTrailing: r), style: .continuous)
            return path
        }
        
        let tailTip = CGPoint(x: rect.maxX + 4.5, y: rect.minY + 2.5)
        let topEnd = CGPoint(x: rect.maxX - 3.0, y: rect.minY)
        
        path.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
        path.addLine(to: topEnd)
        path.addQuadCurve(to: tailTip, control: CGPoint(x: rect.maxX + 2.0, y: rect.minY + 0.5))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + 11.5), control: CGPoint(x: rect.maxX + 3.5, y: rect.minY + 7.0))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addArc(center: CGPoint(x: rect.maxX - r, y: rect.maxY - r), radius: r, startAngle: Angle(degrees: 0), endAngle: Angle(degrees: 90), clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addArc(center: CGPoint(x: rect.minX + r, y: rect.maxY - r), radius: r, startAngle: Angle(degrees: 90), endAngle: Angle(degrees: 180), clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        path.addArc(center: CGPoint(x: rect.minX + r, y: rect.minY + r), radius: r, startAngle: Angle(degrees: 180), endAngle: Angle(degrees: 270), clockwise: false)
        path.closeSubpath()
        return path
    }
}

// MARK: - 룸 아바타 뷰
public struct RoomAvatarView: View {
    let image: NSImage?
    let size: CGFloat
    
    public init(image: NSImage?, size: CGFloat = 38) {
        self.image = image
        self.size = size
    }
    
    public var body: some View {
        ZStack {
            if let img = image {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
            } else {
                RoundedRectangle(cornerRadius: size * 0.40, style: .continuous)
                    .fill(Color(red: 0.51, green: 0.76, blue: 0.85)) // 카카오 민트-스카이블루
                
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.58))
                    .foregroundColor(.white.opacity(0.96))
                    .offset(y: size * 0.07)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.40, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: size * 0.40, style: .continuous)
                .stroke(KakaoTheme.hairline, lineWidth: 0.5)
        )
    }
}

// MARK: - KakaoTalk Date Divider (카카오톡 날짜 구분선 뱃지)
public struct KakaoDateDividerView: View {
    let date: Date
    
    public init(date: Date) {
        self.date = date
    }
    
    private var formattedDateString: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "yyyy년 M월 d일 EEEE"
        return formatter.string(from: date)
    }
    
    public var body: some View {
        HStack {
            Spacer()
            HStack(spacing: 4) {
                Image(systemName: "calendar")
                    .font(.system(size: 9))
                    .foregroundColor(KakaoTheme.dateDividerText)
                
                Text(formattedDateString)
                    .font(.custom("Pretendard-Regular", size: 10.5))
                    .foregroundColor(KakaoTheme.dateDividerText)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 3.5)
            .background(
                Capsule()
                    .fill(KakaoTheme.dateDivider)
            )
            Spacer()
        }
    }
}

// MARK: - 전송 실패 표시
/// 카카오톡은 실패한 메시지 왼쪽에 흰 동그라미를 붙이고, 누르면 재전송·삭제를 고르게 합니다.
/// 답변자 쪽에 오류 말풍선을 남기는 것보다 이 방식이 낫습니다.
/// 실패한 것은 어차피 내가 보낸 말이고, 다시 보내거나 지우는 것도 내 몫이기 때문입니다.
struct DeliveryFailureBadge: View {
    let onResend: () -> Void
    let onDelete: () -> Void

    @State private var isPresented = false
    @State private var isHovering = false

    var body: some View {
        Button(action: { isPresented = true }) {
            ZStack {
                Circle()
                    .fill(KakaoTheme.bubbleTheirs)
                    .frame(width: 19, height: 19)
                    .shadow(color: .black.opacity(0.16), radius: 1.5, x: 0, y: 0.5)
                Image(systemName: "exclamationmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(Color(nsColor: KakaoTheme.hex(0xED423D)))
            }
            .scaleEffect(isHovering ? 1.08 : 1.0)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { isHovering = $0 }
        .help("전송 실패 — 눌러서 재전송하거나 삭제합니다")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(spacing: 0) {
                Text("메시지를 보내지 못했습니다")
                    .font(.custom("Pretendard-Medium", size: 12))
                    .foregroundColor(KakaoTheme.textSecondary)
                    .padding(.horizontal, 14)
                    .padding(.top, 11)
                    .padding(.bottom, 9)

                Divider()

                failureAction(title: "재전송", systemImage: "arrow.clockwise") {
                    isPresented = false
                    onResend()
                }

                Divider()

                failureAction(title: "삭제", systemImage: "trash", isDestructive: true) {
                    isPresented = false
                    onDelete()
                }
            }
            .frame(width: 172)
            .background(KakaoTheme.surface)
            
        }
    }

    @ViewBuilder
    private func failureAction(
        title: String,
        systemImage: String,
        isDestructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 11.5))
                    .frame(width: 15)
                Text(title)
                    .font(.custom("Pretendard-Regular", size: 13))
                Spacer()
            }
            .foregroundColor(isDestructive ? Color(nsColor: KakaoTheme.hex(0xDB3833)) : KakaoTheme.textPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
    }
}

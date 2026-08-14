import SwiftUI
import AppKit

public struct MessageBubbleView: View {
    let message: ChatMessage
    let isFirstInGroup: Bool
    let isLastInGroup: Bool
    let botName: String
    let customAvatar: NSImage?
    let isEditingThisMessage: Bool
    let onImageTapped: ((ChatAttachment) -> Void)?
    let onEditMessage: ((ChatMessage) -> Void)?
    let onDeleteMessage: ((ChatMessage) -> Void)?
    var onAvatarTapped: (() -> Void)? = nil
    
    @State private var webViewHeight: CGFloat = 30
    @State private var isHovering: Bool = false
    @State private var hoverDismissTask: Task<Void, Never>?
    
    public init(
        message: ChatMessage,
        isFirstInGroup: Bool,
        isLastInGroup: Bool,
        botName: String = "사피엔스",
        customAvatar: NSImage? = nil,
        isEditingThisMessage: Bool = false,
        onImageTapped: ((ChatAttachment) -> Void)? = nil,
        onEditMessage: ((ChatMessage) -> Void)? = nil,
        onDeleteMessage: ((ChatMessage) -> Void)? = nil,
        onAvatarTapped: (() -> Void)? = nil
    ) {
        self.message = message
        self.isFirstInGroup = isFirstInGroup
        self.isLastInGroup = isLastInGroup
        self.botName = botName
        self.customAvatar = customAvatar
        self.isEditingThisMessage = isEditingThisMessage
        self.onImageTapped = onImageTapped
        self.onEditMessage = onEditMessage
        self.onDeleteMessage = onDeleteMessage
        self.onAvatarTapped = onAvatarTapped
    }
    
    public var body: some View {
        HStack(alignment: .bottom, spacing: 4) {
            if message.sender == .user {
                Spacer(minLength: 36)
                
                // 보낸 시간
                if isLastInGroup {
                    Text(message.formattedTime)
                        .font(.custom("Pretendard-Regular", size: 9.5))
                        .foregroundColor(Color.black.opacity(0.45))
                        .padding(.bottom, 1)
                }
                
                // 내 말풍선 (카카오 옐로우 #FEE500)
                userBubbleContent
            } else {
                // 사피엔스/챗봇 말풍선 (화이트 #FFFFFF)
                sapiensBubbleWithProfile
                
                // 받은 시간
                if isLastInGroup {
                    Text(message.formattedTime)
                        .font(.custom("Pretendard-Regular", size: 9.5))
                        .foregroundColor(Color.black.opacity(0.45))
                        .padding(.bottom, 1)
                }
                
                Spacer(minLength: 36)
            }
        }
        .padding(.horizontal, 11)
        .padding(.top, isFirstInGroup ? 4 : 1)
        .padding(.bottom, isLastInGroup ? 4 : 1)
    }
    
    // MARK: - 내 말풍선 (User) - 플로팅 툴바로 찌그러짐 원천 방지
    @ViewBuilder
    private var userBubbleContent: some View {
        VStack(alignment: .trailing, spacing: 3) {
            if let attachment = message.attachment {
                attachmentView(attachment: attachment, isUser: true)
            }
            
            if !message.text.isEmpty {
                VStack(alignment: .trailing, spacing: 2) {
                    Group {
                        if message.containsLaTeXOrMarkdown {
                            LaTeXMarkdownView(content: message.text, isUser: true, dynamicHeight: $webViewHeight)
                                .frame(height: webViewHeight)
                                .frame(minWidth: 36, maxWidth: 300)
                        } else {
                            Text(message.text)
                                .font(.custom("Pretendard-Regular", size: 13.5))
                                .foregroundColor(Color(red: 0.1, green: 0.1, blue: 0.1))
                                .lineSpacing(2)
                                .textSelection(.enabled) // 마우스 긁기/선택 활성화
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6.5)
                    .background(
                        KakaoAlignedUserBubbleShape(isFirst: isFirstInGroup)
                            .fill(Color(red: 0.996, green: 0.902, blue: 0.0)) // 카카오 옐로우 #FEE500
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
                                    .foregroundColor(Color.black.opacity(0.58))
                                    .frame(width: 22, height: 18)
                                    .background(Capsule().fill(Color.white.opacity(0.92)))
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
                                    .foregroundColor(Color.black.opacity(0.58))
                                    .frame(width: 22, height: 18)
                                    .background(Capsule().fill(Color.white.opacity(0.92)))
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
                        .foregroundColor(Color(red: 0.35, green: 0.35, blue: 0.35))
                        .padding(.leading, 1)
                }
                
                if let attachment = message.attachment {
                    attachmentView(attachment: attachment, isUser: false)
                }
                
                if !message.text.isEmpty {
                    Group {
                        if message.containsLaTeXOrMarkdown {
                            LaTeXMarkdownView(content: message.text, isUser: false, dynamicHeight: $webViewHeight)
                                .frame(height: webViewHeight)
                                .frame(minWidth: 36, maxWidth: 320)
                        } else {
                            Text(message.text)
                                .font(.custom("Pretendard-Regular", size: 13.5))
                                .foregroundColor(Color(red: 0.1, green: 0.1, blue: 0.1))
                                .lineSpacing(2)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6.5)
                    .background(
                        KakaoAlignedSapiensBubbleShape(isFirst: isFirstInGroup)
                            .fill(Color.white)
                    )
                    .contextMenu {
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
                VStack(alignment: .leading, spacing: 4) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 280, maxHeight: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(Color.black.opacity(0.12), lineWidth: 0.5)
                        )
                    
                    if !attachment.fileName.isEmpty && !attachment.fileName.hasPrefix("image_") {
                        Text(attachment.fileName)
                            .font(.custom("Pretendard-Medium", size: 10.5))
                            .foregroundColor(Color.black.opacity(0.6))
                            .padding(.leading, 2)
                    }
                }
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
                        .foregroundColor(.black)
                        .lineLimit(1)
                    
                    Text(attachment.formattedSize)
                        .font(.custom("Pretendard-Regular", size: 10.5))
                        .foregroundColor(Color.black.opacity(0.5))
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isUser ? Color(red: 0.95, green: 0.86, blue: 0.0) : Color.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.black.opacity(0.08), lineWidth: 0.5)
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
                .stroke(Color.black.opacity(0.06), lineWidth: 0.5)
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
                    .foregroundColor(Color.black.opacity(0.4))
                
                Text(formattedDateString)
                    .font(.custom("Pretendard-Regular", size: 10.5))
                    .foregroundColor(Color.black.opacity(0.55))
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 3.5)
            .background(
                Capsule()
                    .fill(Color.black.opacity(0.07))
            )
            Spacer()
        }
    }
}

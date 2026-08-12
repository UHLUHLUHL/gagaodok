import SwiftUI
import AppKit

public struct ChatInputView: View {
    @Binding var text: String
    @Binding var selectedAttachment: ChatAttachment?
    var onSend: () -> Void
    
    @AppStorage("isSendWithEnter") private var isSendWithEnter: Bool = true
    
    public init(
        text: Binding<String>,
        selectedAttachment: Binding<ChatAttachment?>,
        onSend: @escaping () -> Void
    ) {
        self._text = text
        self._selectedAttachment = selectedAttachment
        self.onSend = onSend
    }
    
    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedAttachment != nil
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            Divider()
                .background(Color.black.opacity(0.08))
            
            // 첨부파일 미리보기 바
            if let attachment = selectedAttachment {
                HStack(spacing: 8) {
                    if attachment.type == .image, let nsImage = attachment.nsImage {
                        Image(nsImage: nsImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 38, height: 38)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    } else {
                        Image(systemName: "doc.fill")
                            .font(.system(size: 24))
                            .foregroundColor(.blue)
                    }
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(attachment.fileName)
                            .font(.custom("Pretendard-Medium", size: 12))
                            .lineLimit(1)
                        Text(attachment.formattedSize)
                            .font(.custom("Pretendard-Regular", size: 10))
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    Button(action: {
                        selectedAttachment = nil
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundColor(Color.black.opacity(0.45))
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Color(red: 0.96, green: 0.96, blue: 0.96))
                .overlay(
                    Divider(), alignment: .top
                )
            }
            
            // 텍스트 입력창 + 플레이스홀더 ZStack (커서와 플레이스홀더 위치 1:1 완벽 정렬)
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text("메시지 입력")
                        .font(.custom("Pretendard-Regular", size: 13.5))
                        .foregroundColor(Color.black.opacity(0.35))
                        .padding(.leading, 14)
                        .padding(.top, 9)
                        .allowsHitTesting(false)
                }
                
                NativeChatTextView(
                    text: $text,
                    isSendWithEnter: isSendWithEnter,
                    onSend: {
                        if canSend {
                            onSend()
                        }
                    }
                )
                .padding(.horizontal, 0)
                .padding(.top, 0)
            }
            .frame(minHeight: 52, maxHeight: 105)
            
            // 하단 도구 툴바
            HStack(alignment: .center, spacing: 14) {
                // + 버튼 (사진/파일 선택)
                Button(action: {
                    selectFile(allowImagesOnly: false)
                }) {
                    Image(systemName: "plus")
                        .font(.system(size: 16.5, weight: .regular))
                        .foregroundColor(Color.black.opacity(0.65))
                }
                .buttonStyle(.plain)
                .focusable(false)
                
                // 이모티콘 아이콘 (빨간 알림점 뱃지)
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "face.smiling")
                        .font(.system(size: 16.5, weight: .regular))
                        .foregroundColor(Color.black.opacity(0.65))
                    
                    Circle()
                        .fill(Color(red: 0.96, green: 0.30, blue: 0.25)) // 빨간 알림 점
                        .frame(width: 5.5, height: 5.5)
                        .offset(x: 2, y: -2)
                }
                
                // 파일 첨부 아이콘
                Button(action: {
                    selectFile(allowImagesOnly: false)
                }) {
                    Image(systemName: "doc")
                        .font(.system(size: 15.5, weight: .regular))
                        .foregroundColor(Color.black.opacity(0.65))
                }
                .buttonStyle(.plain)
                .focusable(false)
                
                Spacer()
                
                // 카카오톡 전송 버튼 그룹 (분할 버튼 디자인 - 단일 깔끔한 화살표)
                HStack(spacing: 0) {
                    Button(action: {
                        if canSend {
                            onSend()
                        }
                    }) {
                        Text("전송")
                            .font(.custom("Pretendard-Medium", size: 12.5))
                            .foregroundColor(canSend ? Color(red: 0.1, green: 0.1, blue: 0.1) : Color(red: 0.72, green: 0.72, blue: 0.72))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 5.5)
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .disabled(!canSend)
                    
                    // 드롭다운 메뉴 (전송 방식 설정 - macOS Menu 기본 화살표만 깔끔하게 사용)
                    Menu {
                        Button(action: { isSendWithEnter = true }) {
                            if isSendWithEnter {
                                Label("Enter로 전송", systemImage: "checkmark")
                            } else {
                                Text("Enter로 전송")
                            }
                        }
                        Button(action: { isSendWithEnter = false }) {
                            if !isSendWithEnter {
                                Label("⌘ + Enter로 전송", systemImage: "checkmark")
                            } else {
                                Text("⌘ + Enter로 전송")
                            }
                        }
                    } label: {
                        EmptyView()
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.visible)
                    .frame(width: 16, height: 24)
                    .padding(.trailing, 4)
                    .focusable(false)
                }
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(canSend ? Color(red: 0.996, green: 0.902, blue: 0.0) : Color(red: 0.93, green: 0.93, blue: 0.93))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(canSend ? Color.black.opacity(0.06) : Color.black.opacity(0.04), lineWidth: 0.5)
                )
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
            .padding(.top, 4)
        }
        .background(Color.white)
    }
    
    private func selectFile(allowImagesOnly: Bool) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        
        if allowImagesOnly {
            panel.allowedContentTypes = [.image]
        } else {
            panel.allowedContentTypes = [.item]
        }
        
        if panel.runModal() == .OK, let url = panel.url {
            if let attachment = ChatAttachment.fromURL(url) {
                selectedAttachment = attachment
            }
        }
    }
}

// MARK: - AppKit Native NSTextView Wrapping (한글 조합 완벽 처리 & 커서 Inset 정밀 정렬)
public struct NativeChatTextView: NSViewRepresentable {
    @Binding var text: String
    var isSendWithEnter: Bool
    var onSend: () -> Void
    
    public init(text: Binding<String>, isSendWithEnter: Bool, onSend: @escaping () -> Void) {
        self._text = text
        self.isSendWithEnter = isSendWithEnter
        self.onSend = onSend
    }
    
    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    public func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        
        let textView = CustomAppKitTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textColor = NSColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1.0)
        textView.font = NSFont(name: "Pretendard-Regular", size: 13.5) ?? NSFont.systemFont(ofSize: 13.5)
        textView.insertionPointColor = NSColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 0.85)
        
        // 텍스트 인셋 및 라인 패딩 정밀 정렬 (플레이스홀더와 1:1 일치)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainerInset = NSSize(width: 14, height: 9)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        
        textView.onEnterPressed = { [weak textView] in
            guard let tv = textView else { return }
            if self.isSendWithEnter {
                // 한글 조합 중이 아닐 때만 전송
                if !tv.hasMarkedText() {
                    self.onSend()
                }
            } else {
                tv.insertNewline(nil)
            }
        }
        
        textView.onCmdEnterPressed = {
            self.onSend()
        }
        
        scrollView.documentView = textView
        return scrollView
    }
    
    public func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? CustomAppKitTextView else { return }
        if textView.string != text {
            textView.string = text
        }
    }
    
    public class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativeChatTextView
        
        init(_ parent: NativeChatTextView) {
            self.parent = parent
        }
        
        public func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}

class CustomAppKitTextView: NSTextView {
    var onEnterPressed: (() -> Void)?
    var onCmdEnterPressed: (() -> Void)?
    
    override func keyDown(with event: NSEvent) {
        let isEnter = event.keyCode == 36 || event.keyCode == 76
        let isCmd = event.modifierFlags.contains(.command)
        let isShift = event.modifierFlags.contains(.shift)
        
        if isEnter {
            if isCmd {
                onCmdEnterPressed?()
                return
            } else if isShift {
                insertNewline(nil)
                return
            } else {
                onEnterPressed?()
                return
            }
        }
        
        super.keyDown(with: event)
    }
}

import SwiftUI
import AppKit

public struct ImageViewerModal: View {
    let attachment: ChatAttachment
    let onClose: () -> Void
    
    public init(attachment: ChatAttachment, onClose: @escaping () -> Void) {
        self.attachment = attachment
        self.onClose = onClose
    }
    
    public var body: some View {
        ZStack {
            // 어두운 배경 오버레이
            KakaoTheme.textPrimary
                .ignoresSafeArea()
                .onTapGesture {
                    onClose()
                }
            
            VStack {
                // 상단 툴바
                HStack {
                    Text(attachment.fileName)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white)
                    
                    Spacer()
                    
                    Button(action: {
                        saveImageToDownloads()
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "square.and.arrow.down")
                            Text("저장")
                        }
                        .font(.system(size: 13))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.white.opacity(0.2))
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.white)
                            .padding(8)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                
                Spacer()
                
                // 확대된 이미지
                if let nsImage = attachment.nsImage {
                    Image(nsImage: nsImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 800, maxHeight: 600)
                        .cornerRadius(8)
                        .shadow(radius: 20)
                }
                
                Spacer()
            }
        }
    }
    
    private func saveImageToDownloads() {
        guard let data = Data(base64Encoded: attachment.dataBase64),
              let downloadsDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return }
        
        let destinationURL = downloadsDir.appendingPathComponent(attachment.fileName)
        do {
            try data.write(to: destinationURL)
            NSWorkspace.shared.activateFileViewerSelecting([destinationURL])
        } catch {
            print("Failed to save image: \(error)")
        }
    }
}

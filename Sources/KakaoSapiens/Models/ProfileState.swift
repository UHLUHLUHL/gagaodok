import SwiftUI
import AppKit

public class ProfileState: ObservableObject {
    public static let shared = ProfileState()
    
    @Published public var name: String = "나"
    @Published public var statusMessage: String = ""
    @Published public var musicTitle: String = "1-800 (Explicit Ver.)"
    @Published public var musicArtist: String = "bbno$"
    @Published public var customImage: NSImage? = nil
    
    private init() {
        // 앱 실행 시 저장된 프로필 정보 로드
        if let savedProfile = StorageService.shared.loadProfile() {
            self.name = savedProfile.name
            self.statusMessage = savedProfile.statusMessage
            self.musicTitle = savedProfile.musicTitle
            self.musicArtist = savedProfile.musicArtist
        }
        
        // 저장된 커스텀 아바타 이미지 로드
        if let savedImage = StorageService.shared.loadAvatarImage() {
            self.customImage = savedImage
        }
    }
    
    public func updateProfile(name: String, statusMessage: String) {
        self.name = name
        self.statusMessage = statusMessage
        
        // 영구 저장
        StorageService.shared.saveProfile(
            name: self.name,
            statusMessage: self.statusMessage,
            musicTitle: self.musicTitle,
            musicArtist: self.musicArtist
        )
    }
    
    /// 편집 시트에서 고른 이미지를 그대로 반영합니다.
    public func setProfileImage(_ image: NSImage?) {
        self.customImage = image
        StorageService.shared.saveAvatarImage(image)
    }

    public func selectNewProfileImage() {
        let openPanel = NSOpenPanel()
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.canChooseFiles = true
        openPanel.allowedContentTypes = [.image]
        
        if openPanel.runModal() == .OK, let url = openPanel.url {
            if let image = NSImage(contentsOf: url) {
                self.customImage = image
                StorageService.shared.saveAvatarImage(image)
            }
        }
    }
    
    public func resetToDefaultImage() {
        self.customImage = nil
        StorageService.shared.saveAvatarImage(nil)
    }
}

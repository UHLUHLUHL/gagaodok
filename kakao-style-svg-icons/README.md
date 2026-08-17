# Kakao-style SVG icon set

Transparent 64 × 64 vector assets recreated from the supplied reference:

- `sidebar-profile-active.svg` / `sidebar-profile-inactive.svg` — black / gray profile icon
- `sidebar-chat-active.svg` / `sidebar-chat-inactive.svg` — black / gray speech bubble
- `sidebar-status.svg` — orange notification and pagination dots
- `search.svg` — search action
- `new-chat.svg` — new conversation action

## Swift / Xcode use

Drag each SVG into `Assets.xcassets` and select **Single Scale**. The icons are
designed at 64 × 64, so size them in SwiftUI with `.frame(width: 28, height: 28)`
or the matching target size. Choose the active or inactive asset from the
selection state. For a tintable version, set **Render As → Template Image** in
the asset inspector and use `.foregroundStyle(...)`.

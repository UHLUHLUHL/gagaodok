#!/bin/bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
cd "$DIR"

echo "🔨 building KakaoSapiens macOS Native App..."
swift build -c release

APP_NAME="KakaoSapiens"
APP_BUNDLE="${APP_NAME}.app"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

# 디렉토리 생성
mkdir -p "${MACOS_DIR}"
mkdir -p "${RESOURCES_DIR}"

# 1. 앱 아이콘 생성 및 복사
if [ ! -f "AppIcon.icns" ]; then
    echo "🎨 Generating AppIcon.icns..."
    swift generate_icon.swift
    iconutil -c icns AppIcon.iconset -o AppIcon.icns
fi

cp -f "AppIcon.icns" "${RESOURCES_DIR}/AppIcon.icns"

# 2. 바이너리 복사
BIN_PATH=$(find .build -name "KakaoSapiens" -type f -not -path "*.dSYM*" | grep -E "release|debug" | head -n 1)

if [ -z "$BIN_PATH" ]; then
    echo "❌ Binary not found!"
    exit 1
fi

echo "📦 Using binary from: $BIN_PATH"
cp -f "$BIN_PATH" "${MACOS_DIR}/${APP_NAME}"
chmod +x "${MACOS_DIR}/${APP_NAME}"

# 3. Info.plist 생성 (아이콘 및 표시 이름 포함)
cat <<EOF > "${CONTENTS_DIR}/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>com.sapiens.kakaotalk</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>사피엔스 (카카오톡)</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSRequiresAquaSystemAppearance</key>
    <false/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key>
        <true/>
    </dict>
</dict>
</plist>
EOF

# 4. /Applications 디렉토리에 정식 설치
echo "🚀 Installing KakaoSapiens to /Applications..."
rm -rf "/Applications/${APP_BUNDLE}"
cp -R "${APP_BUNDLE}" "/Applications/${APP_BUNDLE}"
touch "/Applications/${APP_BUNDLE}"

echo "✅ KakaoSapiens.app 정식 설치가 완료되었습니다!"

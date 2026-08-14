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
#    package_for_sharing.sh 가 x86_64 빌드도 남기므로, 이 맥의 아키텍처를 명시해 고릅니다.
#    이걸 안 하면 find 결과 순서에 따라 인텔 전용 바이너리가 설치돼 Rosetta로 돌아갑니다.
NATIVE_ARCH=$(uname -m)
BIN_PATH=".build/${NATIVE_ARCH}-apple-macosx/release/${APP_NAME}"
if [ ! -f "$BIN_PATH" ]; then
    BIN_PATH=$(find .build -name "${APP_NAME}" -type f -not -path "*.dSYM*" | grep -E "release" | head -n 1)
fi

if [ -z "$BIN_PATH" ]; then
    echo "❌ Binary not found!"
    exit 1
fi

echo "📦 Using binary from: $BIN_PATH ($(lipo -archs "$BIN_PATH" 2>/dev/null))"
cp -f "$BIN_PATH" "${MACOS_DIR}/${APP_NAME}"
chmod +x "${MACOS_DIR}/${APP_NAME}"

# 3. 리소스 번들 복사 (KaTeX·markdown-it·말풍선 셸)
#    이게 빠지면 수식이 전혀 렌더링되지 않으므로 없으면 즉시 중단합니다.
BUNDLE_PATH=".build/${NATIVE_ARCH}-apple-macosx/release/${APP_NAME}_${APP_NAME}.bundle"
if [ ! -d "$BUNDLE_PATH" ]; then
    BUNDLE_PATH=$(find .build -maxdepth 3 -name "${APP_NAME}_${APP_NAME}.bundle" -type d | grep -E "release" | head -n 1)
fi

if [ -z "$BUNDLE_PATH" ]; then
    echo "❌ Resource bundle not found! (수식 렌더링에 필요합니다)"
    exit 1
fi

echo "📚 Bundling resources from: $BUNDLE_PATH"
rm -rf "${RESOURCES_DIR}/$(basename "$BUNDLE_PATH")"
cp -R "$BUNDLE_PATH" "${RESOURCES_DIR}/"

# 4. Info.plist 생성
#    NSAppTransportSecurity는 두지 않습니다. 모든 자원을 앱 안에 넣어
#    외부 네트워크로 나가는 웹 요청 자체가 없어졌습니다.
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
</dict>
</plist>
EOF

# 5. 코드 서명
#    ad-hoc 서명은 빌드할 때마다 서명이 바뀌어, 그때마다 macOS가 키체인 접근을 다시 묻습니다.
#    안정적인 인증서로 서명하면 이 창이 사라집니다.
#    - 환경 변수로 지정:  CODESIGN_IDENTITY="Apple Development: 이름 (TEAMID)" ./build_app.sh
#    - 인증서 만들기:     키체인 접근 > 인증서 지원 > 인증서 생성
#                        이름 아무거나 / 유형 "코드 서명" / 자체 서명 루트
if [ -z "${CODESIGN_IDENTITY}" ]; then
    CODESIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
        | grep -oE '"[^"]+"' | head -n 1 | tr -d '"')
fi

if [ -n "${CODESIGN_IDENTITY}" ]; then
    echo "🔏 Signing with: ${CODESIGN_IDENTITY}"
    codesign --force --sign "${CODESIGN_IDENTITY}" --timestamp=none \
        --options runtime "${APP_BUNDLE}" 2>/dev/null \
        || codesign --force --deep --sign "${CODESIGN_IDENTITY}" "${APP_BUNDLE}"
else
    echo "🔏 서명 인증서가 없어 ad-hoc으로 서명합니다."
    echo "   ⚠️  재설치할 때마다 키체인 접근 허용 창이 다시 뜹니다."
    echo "   → 없애려면: 키체인 접근 > 인증서 지원 > 인증서 생성 (유형: 코드 서명)"
    echo "     그 뒤 CODESIGN_IDENTITY=\"만든이름\" ./build_app.sh"
    codesign --force --deep --sign - "${APP_BUNDLE}" 2>/dev/null || true
fi

# 6. /Applications 디렉토리에 정식 설치
echo "🚀 Installing KakaoSapiens to /Applications..."
rm -rf "/Applications/${APP_BUNDLE}"
cp -R "${APP_BUNDLE}" "/Applications/${APP_BUNDLE}"
touch "/Applications/${APP_BUNDLE}"

echo "✅ KakaoSapiens.app 정식 설치가 완료되었습니다!"

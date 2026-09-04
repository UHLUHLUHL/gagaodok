#!/bin/bash
# 다른 맥에 전달할 배포본을 만듭니다.
#
# build_app.sh 는 내 맥에 바로 설치하는 용도라 arm64만 빌드합니다.
# 이 스크립트는 인텔 맥에서도 돌아가도록 두 아키텍처를 합치고, 압축본과 설치 안내를 함께 냅니다.
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
cd "$DIR"

APP_NAME="KakaoSapiens"
APP_BUNDLE="dist/${APP_NAME}.app"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

rm -rf dist
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

echo "🔨 arm64 빌드..."
swift build -c release --triple arm64-apple-macosx14.0
echo "🔨 x86_64 빌드 (인텔 맥 지원)..."
swift build -c release --triple x86_64-apple-macosx14.0

ARM_BIN=$(find .build/arm64-apple-macosx/release -maxdepth 1 -name "${APP_NAME}" -type f | head -n 1)
X86_BIN=$(find .build/x86_64-apple-macosx/release -maxdepth 1 -name "${APP_NAME}" -type f | head -n 1)

if [ -z "$ARM_BIN" ] || [ -z "$X86_BIN" ]; then
    echo "❌ 두 아키텍처 바이너리를 모두 찾지 못했습니다."
    exit 1
fi

echo "🔗 유니버설 바이너리 결합..."
lipo -create "$ARM_BIN" "$X86_BIN" -output "${MACOS_DIR}/${APP_NAME}"
chmod +x "${MACOS_DIR}/${APP_NAME}"
echo "   → $(lipo -archs "${MACOS_DIR}/${APP_NAME}")"

# 아이콘
if [ ! -f "AppIcon.icns" ]; then
    swift generate_icon.swift
    iconutil -c icns AppIcon.iconset -o AppIcon.icns
fi
cp -f "AppIcon.icns" "${RESOURCES_DIR}/AppIcon.icns"

# 리소스 번들 (KaTeX·markdown-it·말풍선 셸). 없으면 수식이 아예 안 그려집니다.
BUNDLE_PATH=$(find .build/arm64-apple-macosx/release -maxdepth 1 -name "${APP_NAME}_${APP_NAME}.bundle" -type d | head -n 1)
if [ -z "$BUNDLE_PATH" ]; then
    echo "❌ 리소스 번들을 찾지 못했습니다."
    exit 1
fi
cp -R "$BUNDLE_PATH" "${RESOURCES_DIR}/"

cat <<EOF > "${CONTENTS_DIR}/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key><string>com.sapiens.kakaotalk</string>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>사피엔스 (카카오톡)</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSRequiresAquaSystemAppearance</key><false/>
    <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict>
</plist>
EOF

# 서명. 인증서가 있으면 쓰고, 없으면 ad-hoc으로 둡니다.
# 어느 쪽이든 공증(notarization)은 안 되므로 받는 쪽에서 격리 속성을 풀어야 합니다.
if [ -z "${CODESIGN_IDENTITY}" ]; then
    CODESIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep -oE '"[^"]+"' | head -n 1 | tr -d '"')
fi
if [ -n "${CODESIGN_IDENTITY}" ]; then
    echo "🔏 서명: ${CODESIGN_IDENTITY}"
    codesign --force --deep --sign "${CODESIGN_IDENTITY}" "${APP_BUNDLE}"
else
    echo "🔏 ad-hoc 서명"
    codesign --force --deep --sign - "${APP_BUNDLE}" 2>/dev/null || true
fi

cp -f "docs/installation/설치방법.txt" "dist/설치방법.txt" 2>/dev/null || true

cd dist
zip -qry "${APP_NAME}.zip" "${APP_NAME}.app" "설치방법.txt" 2>/dev/null || zip -qry "${APP_NAME}.zip" "${APP_NAME}.app"
cd ..

echo
echo "✅ 완성: $DIR/dist/${APP_NAME}.zip ($(du -h dist/${APP_NAME}.zip | cut -f1))"
echo "   이 zip과 dist/설치방법.txt 를 친구에게 보내세요."

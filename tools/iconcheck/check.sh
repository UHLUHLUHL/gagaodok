#!/bin/bash
# 아이콘을 화면 없이 그려 원본 캡처와 행 단위로 대조합니다.
#
# 앱 창을 띄우지 않는 이유가 둘 있습니다. 창이 다른 데스크톱에 있으면
# screencapture가 새까만 그림만 돌려주고, 창 안에서는 아이콘 하나만 딱 잘라
# 재기가 번거롭습니다. ImageRenderer로 뷰만 따로 그리면 둘 다 없는 문제가 됩니다.
set -e
cd "$(dirname "$0")"

# PIL이 있는 파이썬을 찾습니다. 맥에 파이썬이 여럿 깔려 있는 경우가 많습니다.
PY=""
for p in python3 /Library/Frameworks/Python.framework/Versions/*/bin/python3 \
         /opt/homebrew/bin/python3 /usr/bin/python3; do
    if command -v "$p" >/dev/null 2>&1 && "$p" -c "import PIL" 2>/dev/null; then
        PY="$p"; break
    fi
done
if [ -z "$PY" ]; then
    echo "Pillow가 있는 python3을 못 찾았습니다. 'pip3 install pillow' 후 다시 실행하세요."
    exit 1
fi

cp ../../Sources/KakaoSapiens/Views/KakaoIcons.swift .
swiftc -O KakaoIcons.swift main.swift -o iconshot
./iconshot

echo
echo "── 잉크 상자 (pt) ─────────────────────"
"$PY" ink.py magnifier compose addfriend rail_person rail_chat

echo
echo "── 돋보기: 원본 대 우리 ───────────────"
"$PY" cmp.py reference/header_chats.png 2 magnifier dark 26,58,28,60

echo
echo "── 새 대화: 원본 대 우리 ──────────────"
"$PY" cmp.py reference/header_chats.png 2 compose dark 106,144,28,59

echo
echo "── 친구 추가: 원본 대 우리 ────────────"
# 이 캡처만 다크 모드라 잉크가 흽니다.
"$PY" cmp.py reference/header_addfriend.png 2 addfriend light

echo
echo "── 레일 친구: 원본 대 우리 ────────────"
"$PY" cmp.py reference/rail.png 2 rail_person dark 0,123,55,110

echo
echo "── 레일 채팅: 원본 대 우리 ────────────"
"$PY" cmp.py reference/rail.png 2 rail_chat dark 0,123,170,225

echo
echo "차이가 ±0.5pt 이내면 맞은 것입니다. 2배 화면의 1화소입니다."

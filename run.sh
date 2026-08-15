#!/bin/bash
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
cd "$DIR"

# 번들 이름은 build_app.sh의 DISPLAY_NAME과 같아야 합니다.
APP="가가오독.app"

if [ ! -d "$APP" ]; then
    ./build_app.sh
fi

open "$APP"

#!/bin/bash
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
cd "$DIR"

if [ ! -d "KakaoSapiens.app" ]; then
    ./build_app.sh
fi

open KakaoSapiens.app

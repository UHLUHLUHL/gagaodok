#!/bin/bash
# Gemini 3.8 Flash가 generationConfig.seed를 받는지, 그리고 같은 요청이
# 정말 같은 답을 내는지 확인합니다.
#
# 쓰는 법:  GEMINI_API_KEY=... bash docs/seed-probe.sh
#
# 읽는 법
#   A1 == A2  → 씨앗 없이도 같은 답. 사용자가 본 "재요청해도 비슷하다"가 사실입니다.
#   B1 != B2  → seed가 먹힙니다. 재요청마다 다른 씨앗을 주면 답이 갈립니다.
#   ERROR     → seed를 거부합니다. 그러면 쓸 수 있는 손잡이가 없습니다.
set -u
KEY="${GEMINI_API_KEY:?GEMINI_API_KEY 환경변수에 키를 넣고 실행하세요}"
URL="https://generativelanguage.googleapis.com/v1beta/models/gemini-3.8-flash:generateContent"
PROMPT="좋아하는 과일 다섯 개를 쉼표로 나열해줘. 설명은 붙이지 마."

call() { # $1: seed (빈 문자열이면 seed 없이)
  local seed_field=""
  [ -n "$1" ] && seed_field="\"seed\":$1,"
  curl -s "$URL" -H "x-goog-api-key: $KEY" -H "Content-Type: application/json" \
    -d "{\"contents\":[{\"role\":\"user\",\"parts\":[{\"text\":\"$PROMPT\"}]}],
         \"generationConfig\":{${seed_field}\"maxOutputTokens\":2048,
         \"thinkingConfig\":{\"thinkingLevel\":\"low\"}}}" \
  | python3 -c "
import sys,json
d=json.load(sys.stdin)
if 'error' in d:
    print('ERROR', d['error'].get('code'), d['error'].get('message','')[:160])
else:
    c=d.get('candidates',[{}])[0]
    parts=c.get('content',{}).get('parts',[])
    print((''.join(p.get('text','') for p in parts).strip() or '(빈 응답 / finish=%s)'%c.get('finishReason')))
"
}

echo "── A. seed 없이 두 번 (같은 답이 나오는지) ──"
echo "A1: $(call '')"
echo "A2: $(call '')"
echo
echo "── B. seed를 다르게 두 번 (갈라지는지 / 거부하는지) ──"
echo "B1(seed=11): $(call 11)"
echo "B2(seed=99): $(call 99)"

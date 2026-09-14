#!/bin/bash
# 같은 요청을 반복하면 답이 갈리는가, 그리고 seed가 그것을 바꾸는가.
#
# 쓰는 법:  GEMINI_API_KEY=... bash docs/seed-probe.sh
#
# **1판은 잘못 만든 시험이었다.** "과일 다섯 개를 나열하라"처럼 답이 뻔한 질문을
# 두 번 물어 같은 답이 나온 것을 "씨앗 없이는 결정적이다"의 증거로 삼았다.
# 경우의 수가 적은 질문은 씨앗이 무엇이든 같은 답이 나온다. 게다가 공식 문서는
# **seed를 생략하면 요청마다 무작위 씨앗을 만든다**고 적고 있어, 1판의 결론과
# 어긋난다. 그래서 열린 질문으로, 여러 번 반복해서 다시 잰다.
#
# 읽는 법
#   A가 5개 다 다르다  → 씨앗을 안 줘도 이미 갈린다. 앱의 seed 지정은 무의미하다.
#   A가 전부 같다      → 씨앗을 안 주면 고정이다. 앱의 seed 지정이 효과가 있다.
#   A는 같고 B는 다르다 → seed가 실제로 답을 정한다. 가장 명확한 결과다.
#   ERROR              → seed를 거부한다.
set -u
KEY="${GEMINI_API_KEY:?GEMINI_API_KEY 환경변수에 키를 넣고 실행하세요}"
MODEL="${GEMINI_MODEL:-gemini-3.8-flash}"
URL="https://generativelanguage.googleapis.com/v1beta/models/${MODEL}:generateContent"

# 경우의 수가 많아야 한다. 답이 하나로 정해지는 질문은 아무것도 가려내지 못한다.
PROMPT="처음 보는 행성을 하나 상상해서 이름과 특징을 딱 한 문장으로 말해줘. 매번 다른 것을 지어내."

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
    print('ERROR', d['error'].get('code'), d['error'].get('message','')[:140])
else:
    c=d.get('candidates',[{}])[0]
    parts=c.get('content',{}).get('parts',[])
    t=''.join(p.get('text','') for p in parts).strip().replace('\n',' ')
    print(t or '(빈 응답 / finish=%s)'%c.get('finishReason'))
"
}

echo "모델: $MODEL"
echo
echo "── A. seed 없이 5회 (기본값이 무작위인가) ──"
A=""
for i in 1 2 3 4 5; do
  r="$(call '')"; echo "A$i: $r"; A="$A
$r"
done
echo "   서로 다른 답: $(printf '%s' "$A" | sed '/^$/d' | sort -u | wc -l | tr -d ' ') / 5"

echo
echo "── B. seed를 다르게 5회 ──"
B=""
for s in 11 22 33 44 55; do
  r="$(call $s)"; echo "B(seed=$s): $r"; B="$B
$r"
done
echo "   서로 다른 답: $(printf '%s' "$B" | sed '/^$/d' | sort -u | wc -l | tr -d ' ') / 5"

echo
echo "── C. 같은 seed 2회 (씨앗이 답을 정하는가) ──"
echo "C1(seed=77): $(call 77)"
echo "C2(seed=77): $(call 77)"

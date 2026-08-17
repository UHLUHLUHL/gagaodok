#!/usr/bin/env python3
"""Gemini 요금 시뮬레이터. TOKEN_COST.md의 표를 만든 코드입니다.

AIServicePrefixCache.kt와 ConversationCompactor.kt의 상수·규칙을 그대로 옮겼습니다.
앱과 어긋나면 앱이 맞습니다 — 여기를 고치십시오.

  python3 tools/costsim.py fit      관측값에 맞는 대화 조건 역산
  python3 tools/costsim.py compare  개선안별 절감 효과
  python3 tools/costsim.py sens     묶음 길이·TTL 민감도
"""
import sys

# AIModel.kt 도입 요금 ($/100만 토큰). 2027-01-01부터 두 배가 되지만 비율은 안 바뀝니다.
IN, CACHED, OUT, STORE = 0.75, 0.075, 3.75, 0.50
KRW = 1420
MIN_PER_H = 60.0

# 사용량 화면에서 읽은 값 (마린 방, 2026-08-17)
OBSERVED = dict(total_in=2_572_393, created=507_733, cost=1.0942)
OBSERVED_OUT = 38_598


def run(N, d=105, burst=9, gap_h=3.0, step_min=1.5, system=3000,
        threshold=150, window=20, period=50, ttl_min=15, seg=1476,
        min_tail=2000, tail_div=5, out_per_turn=169,
        eager=False, level2=0, img_every=0, img_tok=516, img_keep=10**9):
    """N턴을 돌려 요금과 최종 문맥 크기를 냅니다.

    기본값은 ConversationCompactor / AIServicePrefixCache의 현재 상수입니다.
    eager=True   세션 첫 요청 뒤에도 캐시를 만듭니다 (개선안 ①)
    level2=k     요약 조각이 k개를 넘으면 원문에서 다시 굵게 요약 (개선안 ②)
    img_keep=n   n턴 지난 사진은 문맥에서 뺍니다 (개선안 ③)
    """
    trigger = window + period
    covered = segs = 0
    cache_n = 0            # 살아있는 캐시의 토큰 수 (0이면 없음)
    cache_expires = -1e9
    cache_born = 0.0
    regular = cached_in = created = 0
    storage_th = 0.0       # 토큰·시간. 실제 보관 시간으로 매깁니다.
    resummary_cost = 0.0
    now = 0.0
    ctx = system

    def release(t_now):
        """캐시를 반납합니다. 옛 캐시는 새것을 만들 때 지우므로 실제 보관분만 냅니다."""
        nonlocal storage_th
        if cache_n:
            storage_th += cache_n * min(t_now - cache_born, ttl_min / MIN_PER_H)

    for turn in range(1, N + 1):
        new_session = (turn % burst == 1 and turn > 1)
        now += gap_h if new_session else step_min / MIN_PER_H

        # --- 압축 ---
        if turn >= threshold and turn - covered >= trigger:
            covered += period
            segs += 1
            # 접두사가 통째로 바뀌므로 캐시는 지문 검사에서 탈락합니다.
            release(now)
            cache_n = 0
            cache_expires = -1e9
            if level2 and segs > level2:
                merged = segs - level2 // 2
                segs = segs - merged + 1
                # 원문에서 다시 요약: 입력은 그 구간 원문, 출력은 조각 하나.
                resummary_cost += (merged * period * d * IN + seg * OUT) / 1e6

        # --- 이번 요청의 문맥 ---
        live_images = 0
        if img_every:
            live_images = sum(1 for k in range(covered + 1, turn + 1)
                              if k % img_every == 0 and turn - k < img_keep)
        ctx = system + segs * seg + (turn - covered) * d + live_images * img_tok

        # --- 캐시 적중 여부 ---
        alive = now < cache_expires
        if not alive and cache_n:
            release(now)
            cache_n = 0
        if alive:
            cached_in += cache_n
            regular += max(0, ctx - cache_n)
        else:
            regular += ctx

        # --- 캐시 갱신 규칙 (refreshPrefixCache) ---
        if not alive:
            # burst 게이트: 대화가 이어지는 중일 때만 첫 캐시를 만듭니다.
            gate = True if eager else (turn % burst != 1)
            if ctx >= 1200 and gate:            # MINIMUM_CACHE_TOKENS
                cache_n, cache_born = ctx, now
                cache_expires = now + ttl_min / MIN_PER_H
                created += ctx
        elif ctx - cache_n >= max(min_tail, cache_n // tail_div):
            release(now)
            cache_n, cache_born = ctx, now
            cache_expires = now + ttl_min / MIN_PER_H
            created += ctx

    release(now)
    out = N * out_per_turn
    cost = (regular * IN + cached_in * CACHED + created * IN
            + out * OUT + storage_th * STORE) / 1e6 + resummary_cost
    return dict(cost=cost, regular=regular, cached_in=cached_in, created=created,
                total_in=regular + cached_in, out=out, storage_th=storage_th, ctx=ctx)


def fit():
    """관측된 네 숫자에 맞는 (턴 수, 턴당 토큰, 묶음 길이)를 찾습니다."""
    best = None
    for N in range(130, 240, 2):
        for d in range(80, 300, 5):
            for burst in range(3, 20):
                r = run(N, d=d, burst=burst, out_per_turn=OBSERVED_OUT / N)
                err = sum(abs(r[k] - OBSERVED[k]) / OBSERVED[k] for k in OBSERVED)
                if best is None or err < best[0]:
                    best = (err, N, d, burst, r)
    err, N, d, burst, r = best
    print(f"■ 재현 조건: {N}턴 / 턴당 누적 {d}토큰 / 한 묶음 {burst}턴 (총오차 {err*100:.1f}%)")
    for label, got, want in [("총 입력", r['total_in'], OBSERVED['total_in']),
                             ("캐시 생성", r['created'], OBSERVED['created']),
                             ("요금", r['cost'], OBSERVED['cost'])]:
        fmt = (lambda v: f"${v:.4f}") if label == "요금" else (lambda v: f"{v:>10,}")
        print(f"   {label:<8} {fmt(got)}  (관측 {fmt(want)})  오차 {abs(got-want)/want*100:>5.1f}%")
    print(f"   캐시 적중 {r['cached_in']/r['total_in']*100:.0f}%   현재 문맥 {r['ctx']:,}토큰")
    print("\n   주의: 캐시 생성량이 관측보다 적게 나옵니다. 실제 세션이 더 짧다는 뜻이고,")
    print("   그 방향에서는 개선안 ①의 효과가 표의 값보다 커집니다. TOKEN_COST.md 참고.")


CASES = [("현재 그대로",            {}),
         ("① 첫 캐시 즉시 생성",     {"eager": True}),
         ("② TTL 15분→60분",       {"ttl_min": 60}),
         ("③ 압축 문턱 150→60턴",   {"threshold": 60}),
         ("①+② 함께",              {"eager": True, "ttl_min": 60}),
         ("① + 2차 압축(8조각)",     {"eager": True, "level2": 8})]


def compare(gap_h=3.0):
    turns = (300, 500, 1000, 2000)
    print(f"\n### 세션 간격 {gap_h}시간 가정 — 누적 요금 (괄호는 현재 대비)")
    head = f"{'':<24}" + "".join(f"{str(t)+'턴':>14}" for t in turns) + f"{'2000턴 문맥':>13}"
    print(head + "\n" + "-" * len(head))
    base = {}
    for name, kw in CASES:
        row = f"{name:<24}"
        for t in turns:
            c = run(t, gap_h=gap_h, **kw)['cost']
            base.setdefault(t, c) if not kw else None
            row += f"{'$%.2f' % c:>8}{'%.0f%%' % (c / base[t] * 100):>6}"
        print(row + f"{run(2000, gap_h=gap_h, **kw)['ctx']:>12,}")


def sens():
    print("■ '첫 캐시 즉시 생성'은 묶음 길이에 얼마나 민감한가 (1,000턴, 간격 3시간)")
    print(f"{'한 묶음 턴수':>12}{'현재':>10}{'즉시 생성':>11}{'차이':>8}")
    for b in (2, 3, 4, 6, 9, 15, 30):
        a = run(1000, burst=b)['cost']
        e = run(1000, burst=b, eager=True)['cost']
        print(f"{b:>12}{'$%.2f' % a:>10}{'$%.2f' % e:>11}{'%+.0f%%' % ((e/a-1)*100):>8}")

    print("\n■ TTL 연장의 손익분기 (1,000턴, 묶음 9턴, ① 적용 상태. 100% = TTL 15분)")
    ttls = (30, 60, 120)
    print(f"{'세션 간격':>10}" + "".join(f"{'TTL '+str(t)+'분':>11}" for t in ttls))
    for g in (0.25, 0.5, 1, 2, 3, 6, 12):
        base = run(1000, gap_h=g, ttl_min=15, eager=True)['cost']
        row = f"{str(g)+'h':>10}"
        for t in ttls:
            row += f"{'%.0f%%' % (run(1000, gap_h=g, ttl_min=t, eager=True)['cost']/base*100):>11}"
        print(row)
    print("\n   세션 간격이 1시간을 넘으면 TTL 연장은 손해입니다. 앱이 이 간격을 기록하지")
    print("   않으므로, 재기 전에는 상수를 건드리지 않습니다.")


if __name__ == "__main__":
    what = sys.argv[1] if len(sys.argv) > 1 else "fit"
    if what == "fit":
        fit()
    elif what == "compare":
        for g in (0.5, 3.0):
            compare(g)
    elif what == "sens":
        sens()
    else:
        print(__doc__)

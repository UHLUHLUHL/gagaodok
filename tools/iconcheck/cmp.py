"""원본과 우리 아이콘의 행별 잉크 폭을 나란히 찍습니다.

원본은 2배 해상도 캡처, 우리 것은 8배 렌더라 둘 다 pt로 환산해 0.5pt 격자에 맞춥니다.
"""
import sys
from PIL import Image


def rows(path, scale, dark_ink=True, thresh=160, box=None):
    im = Image.open(path).convert("RGB")
    px = im.load()
    W, H = im.size
    x0b, x1b, y0b, y1b = box if box else (0, W - 1, 0, H - 1)

    def on(x, y):
        r, g, b = px[x, y]
        # 색이 있는 화소는 잉크로 세지 않습니다. 레일 캡처에는 안 읽은 개수를
        # 알리는 빨간 배지가 말풍선 오른쪽 위를 덮고 있어, 그냥 밝기로만 재면
        # 배지가 아이콘의 일부로 잡혀 폭이 엉뚱하게 넓어집니다.
        if max(r, g, b) - min(r, g, b) > 40:
            return False
        v = 0.299 * r + 0.587 * g + 0.114 * b
        return v < thresh if dark_ink else v > thresh

    pts = [(x, y) for y in range(y0b, y1b + 1) for x in range(x0b, x1b + 1) if on(x, y)]
    x0 = min(p[0] for p in pts); y0 = min(p[1] for p in pts)
    x1 = max(p[0] for p in pts); y1 = max(p[1] for p in pts)
    out = {}
    for y in range(y0, y1 + 1):
        xs = [x for x in range(x0b, x1b + 1) if on(x, y)]
        if not xs:
            continue
        out[round((y - y0) / scale * 2) / 2] = (
            round((min(xs) - x0) / scale * 2) / 2,
            round((max(xs) - x0 + 1) / scale * 2) / 2,
        )
    return out, (x1 - x0 + 1) / scale, (y1 - y0 + 1) / scale


orig_path, orig_scale, ours_name = sys.argv[1], float(sys.argv[2]), sys.argv[3]
dark_ink = sys.argv[4] != "light"
box = tuple(int(v) for v in sys.argv[5].split(",")) if len(sys.argv) > 5 else None

o, ow, oh = rows(orig_path, orig_scale, dark_ink, box=box)
u, uw, uh = rows(f"out_{ours_name}.png", 8)

print(f"원본 {ow:.1f} x {oh:.1f}   우리 {uw:.1f} x {uh:.1f}")
print(f"{'y':>5}  {'원본 좌..우':>14}   {'우리 좌..우':>14}   차")
for y in sorted(set(o) | set(u)):
    a = o.get(y); b = u.get(y)
    fa = f"{a[0]:5.1f}..{a[1]:5.1f}" if a else "      —      "
    fb = f"{b[0]:5.1f}..{b[1]:5.1f}" if b else "      —      "
    d = ""
    if a and b:
        d = f"{b[0]-a[0]:+5.1f} {b[1]-a[1]:+5.1f}"
    print(f"{y:5.1f}  {fa}   {fb}   {d}")

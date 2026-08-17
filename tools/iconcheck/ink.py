"""렌더한 아이콘의 잉크 상자를 pt로 잽니다. scale=8, 여백 4pt."""
import sys
from PIL import Image

SCALE = 8

def ink_box(path, thresh=200):
    im = Image.open(path).convert("L")
    w, h = im.size
    px = im.load()
    minx, miny, maxx, maxy = w, h, -1, -1
    for y in range(h):
        for x in range(w):
            if px[x, y] < thresh:
                if x < minx: minx = x
                if x > maxx: maxx = x
                if y < miny: miny = y
                if y > maxy: maxy = y
    if maxx < 0:
        return None
    return (minx, miny, maxx, maxy)

for name in sys.argv[1:]:
    b = ink_box(f"out_{name}.png")
    if b is None:
        print(f"{name}: 잉크 없음")
        continue
    minx, miny, maxx, maxy = b
    wpt = (maxx - minx + 1) / SCALE
    hpt = (maxy - miny + 1) / SCALE
    print(f"{name}: {wpt:.2f} x {hpt:.2f} pt")

"""화면 표시 크기 비교 목업.

MacBook Air 13"(기본 해상도 1470x956pt, Retina 2x) 화면 하단을 2배 픽셀로 그려서
Dock 옆에 놓였을 때 펫 크기가 어떻게 보이는지 비교한다.

실행:  python3 art/size_mock.py   →  art/out/size_mock.png
"""
from PIL import Image, ImageDraw
import os
from animals import ANIMALS, OUT_DIR, font, hx

PX = 2                      # Retina: 1pt = 2px
W_PT, H_PT = 1100, 290      # 화면 하단 일부만 잘라서 표시
SIZES = [(32, "32pt"), (64, "64pt"), (96, "96pt"), (128, "128pt")]
FOOT_GAP = 2                # 스프라이트 발 아래 빈 줄 (논리 픽셀)


def main():
    W, H = W_PT * PX, H_PT * PX
    im = Image.new("RGBA", (W, H))
    d = ImageDraw.Draw(im)
    top, bot = (86, 124, 190), (178, 150, 205)
    for y in range(H):
        t = y / (H - 1)
        d.line([(0, y), (W, y)], fill=tuple(int(a + (b - a) * t) for a, b in zip(top, bot)) + (255,))

    # Dock (기본 크기 근사: 막대 높이 68pt, 아이콘 50pt)
    dock_w, dock_h, margin = 640, 68, 6
    x0 = (W_PT - dock_w) // 2
    y0 = H_PT - margin - dock_h
    layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ld = ImageDraw.Draw(layer)
    ld.rounded_rectangle([x0 * PX, y0 * PX, (x0 + dock_w) * PX, (y0 + dock_h) * PX],
                         radius=20 * PX, fill=(245, 245, 250, 110), outline=(255, 255, 255, 90), width=2)
    colors = ["#4f9cf7", "#f7c948", "#58c98b", "#f2706b", "#9b7bf0", "#f59e42",
              "#3fc1c9", "#e86aa6", "#6b7a90", "#7bc86c", "#5271ff"]
    n, ic = len(colors), 50
    gap = (dock_w - n * ic) / (n + 1)
    for i, c in enumerate(colors):
        ix = x0 + gap + i * (ic + gap)
        iy = y0 + (dock_h - ic) / 2
        ld.rounded_rectangle([ix * PX, iy * PX, (ix + ic) * PX, (iy + ic) * PX],
                             radius=11 * PX, fill=hx(c))
    im.alpha_composite(layer)

    cat = ANIMALS[0][2]()
    others = [fn() for _, _, fn in ANIMALS]
    f = font(13 * PX)
    ground = y0                      # Dock 윗면에 서 있는 모습
    xs = [x0 + 40, x0 + 130, x0 + 260, x0 + 430]
    for (size, label), x in zip(SIZES, xs):
        scale = size * PX // 32
        sp = cat.image(scale)
        py = ground * PX - sp.height + FOOT_GAP * scale
        im.alpha_composite(sp, (x * PX, py))
        d.text(((x + size / 2) * PX, py - 4 * PX), label, font=f, fill=(255, 255, 255, 255),
               anchor="mb", stroke_width=2, stroke_fill=(40, 40, 60, 255))

    # 화면 바닥(Dock 양옆)에 서 있는 모습: 96pt
    scale = 96 * PX // 32
    for sp_src, x in ((others[2], 40), (others[4], W_PT - 150)):
        sp = sp_src.image(scale)
        im.alpha_composite(sp, (x * PX, H - sp.height + FOOT_GAP * scale))

    out = os.path.join(OUT_DIR, "size_mock.png")
    im.save(out, dpi=(144, 144))
    print("saved", out, im.size)


if __name__ == "__main__":
    main()

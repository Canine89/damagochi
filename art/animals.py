"""다마고치 동물 8종 도트 아트 + 애니메이션 프레임 (Pusheen 풍: 굵은 외곽선 + 단색 채움).

32x32 논리 격자에 그린다. 앱에서는 최근접 보간으로 2배(64pt)/3배(96pt) 확대해서 쓴다.

실행:  python3 art/animals.py
출력:  Resources/sprites/<이름>.png   스프라이트 시트 (32x32 프레임을 가로로 나열, FRAMES 순서)
       art/out/<이름>_64.png          서 있는 포즈 64x64
       art/out/lineup.png             8종 비교 미리보기
       art/out/frames.png             전체 프레임 미리보기
"""
from PIL import Image, ImageDraw, ImageFont
import os

G = 32
HERE = os.path.dirname(os.path.abspath(__file__))
OUT_DIR = os.path.join(HERE, "out")
SPRITE_DIR = os.path.join(HERE, "..", "Resources", "sprites")


def hx(h):
    h = h.lstrip("#")
    return (int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16), 255)


LINE = hx("#241c1f")
PINK = hx("#ff9fb2")
WHITE = hx("#ffffff")


# ---------- 포즈 ----------
class Pose:
    """한 프레임의 자세.

    squash  몸 윗면이 내려오는 양(px). 음수면 위로 늘어남
    lift    몸 전체가 떠오르는 양(px). 음수면 주저앉음
    legs    다리 4개 각각의 (좌우 이동, 길이). 길이 0이면 안 보임
    eyes    open | blink | happy
    tail    꼬리 추가 y 이동 (몸과 어긋나게 해서 흔들림 표현)
    """

    def __init__(self, squash=0, lift=0, legs=None, eyes="open", tail=0):
        self.squash, self.lift, self.eyes, self.tail = squash, lift, eyes, tail
        self.legs = legs or [(0, 2)] * 4

    @property
    def o(self):            # 머리·몸 윗부분의 y 이동
        return self.squash - self.lift

    @property
    def b(self):            # 몸 아랫부분의 y 이동
        return -self.lift


STAND = [(0, 2)] * 4
SPREAD = [(-1, 2), (0, 2), (0, 2), (1, 2)]       # 앞뒤로 쭉 뻗음
TUCK = [(2, 1), (1, 1), (-1, 1), (-2, 1)]        # 배 밑으로 모음
SHORT = [(0, 1)] * 4
# 걷기: 다리를 번갈아 내딛는다 (몸은 거의 흔들리지 않음)
WALK_A = [(-1, 2), (1, 2), (-1, 2), (1, 2)]      # 앞다리·뒷다리 각각 벌림
WALK_B = [(0, 1), (0, 2), (0, 1), (0, 2)]        # 한쪽 다리 들기
WALK_C = [(1, 2), (-1, 2), (1, 2), (-1, 2)]      # 모음
WALK_D = [(0, 2), (0, 1), (0, 2), (0, 1)]        # 반대쪽 다리 들기

# 프레임 순서 = 앱(Sources/Damagochi/Sprites.swift)의 인덱스와 일치해야 한다
FRAMES = [
    ("idle0", Pose()),
    ("idle1", Pose(squash=1)),
    ("blink", Pose(squash=1, eyes="blink")),
    ("run0", Pose(legs=SPREAD, tail=1)),
    ("run1", Pose(lift=1, legs=STAND)),
    ("run2", Pose(lift=1, legs=TUCK, tail=-1)),
    ("run3", Pose(squash=1, legs=STAND)),
    ("crouch", Pose(squash=1, lift=-1, legs=SHORT, tail=1)),
    ("rise", Pose(squash=-1, legs=TUCK, tail=1)),
    ("fall", Pose(legs=SPREAD, tail=-1)),
    ("happy", Pose(lift=1, eyes="happy", tail=-1)),
    ("sleep", Pose(squash=1, lift=-1, legs=SHORT, eyes="blink", tail=1)),
    ("walk0", Pose(legs=WALK_A)),
    ("walk1", Pose(legs=WALK_B, tail=1)),
    ("walk2", Pose(legs=WALK_C)),
    ("walk3", Pose(legs=WALK_D, tail=1)),
]


# ---------- 도형 헬퍼 ----------
def rrect(x0, y0, x1, y1, tl=(), tr=(), bl=(), br=()):
    """모서리를 행별 inset으로 깎은 둥근 사각형. tl/tr은 위에서부터, bl/br은 아래에서부터."""
    pts = set()
    for j, y in enumerate(range(y0, y1 + 1)):
        k = y1 - y
        l = tl[j] if j < len(tl) else (bl[k] if k < len(bl) else 0)
        r = tr[j] if j < len(tr) else (br[k] if k < len(br) else 0)
        for x in range(x0 + l, x1 - r + 1):
            pts.add((x, y))
    return pts


def rect(x0, y0, x1, y1):
    return {(x, y) for x in range(x0, x1 + 1) for y in range(y0, y1 + 1)}


def bmp(ox, oy, rows):
    """ASCII 비트맵 → {문자: 좌표집합}"""
    out = {}
    for j, row in enumerate(rows):
        for i, ch in enumerate(row):
            if ch not in ". ":
                out.setdefault(ch, set()).add((ox + i, oy + j))
    return out


def oval(cx, cy, rx, ry):
    return {(x, y) for x in range(G) for y in range(-4, G + 4)
            if ((x + 0.5 - cx) / rx) ** 2 + ((y + 0.5 - cy) / ry) ** 2 <= 1.0}


class Sprite:
    def __init__(self):
        self.px = {}

    def group(self, *layers, line=LINE):
        """여러 채움 레이어를 한 덩어리로 보고 바깥에만 외곽선을 두른다."""
        union = set()
        for pts, _ in layers:
            union |= pts
        for (x, y) in union:
            for n in ((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)):
                if n not in union:
                    self.px[n] = line
        for pts, c in layers:
            for p in pts:
                self.px[p] = c

    def fill(self, pts, color, clip=None):
        for p in pts:
            if clip is None or p in clip:
                self.px[p] = color

    def image(self, scale=1):
        im = Image.new("RGBA", (G, G), (0, 0, 0, 0))
        for (x, y), c in self.px.items():
            if 0 <= x < G and 0 <= y < G:
                im.putpixel((x, y), c)
        if scale != 1:
            im = im.resize((G * scale, G * scale), Image.NEAREST)
        return im


LOAF = dict(tl=[4, 2, 1, 1], tr=[4, 2, 1, 1], bl=[2, 1], br=[2, 1])
ROUND = dict(tl=[5, 3, 2, 1, 1], tr=[5, 3, 2, 1, 1], bl=[3, 1], br=[3, 1])


def legs4(p, xs=(6, 10, 17, 21), top=27):
    pts = set()
    for x, (dx, ln) in zip(xs, p.legs):
        if ln > 0:
            pts |= rect(x + dx, top + p.b, x + dx + 1, top + p.b + ln - 1)
    return pts


def eyes(s, x1, x2, y, p):
    for x in (x1, x2):
        if p.eyes == "blink":
            s.fill(rect(x - 1, y + 1, x + 1, y + 1), LINE)
        elif p.eyes == "happy":
            s.fill({(x - 1, y + 1), (x, y), (x + 1, y + 1)}, LINE)
        else:
            s.fill(rect(x, y, x, y + 1), LINE)


def mouth(s, x, y, nose=LINE):
    """ㅅ 모양 입: 코 1px + 양옆 아래 1px"""
    s.fill({(x, y)}, nose)
    s.fill({(x - 1, y + 1), (x + 1, y + 1)}, LINE)


# ---------- 동물들 ----------
def cat(p):
    s = Sprite()
    o, b, t = p.o, p.b, p.o + p.tail
    F, D = hx("#aaa59f"), hx("#7c756f")
    tail = bmp(24, 9 + t, ["..tt.", "..tt.", "..tt.", "..tt.", ".ttt.", "ttt..", "tt...", "tt..."])["t"]
    s.group((tail, F))
    s.fill(rect(24, 10 + t, 30, 10 + t) | rect(24, 12 + t, 30, 12 + t), D, clip=tail)
    body = rrect(4, 14 + o, 24, 26 + b, **LOAF)
    ear1 = bmp(6, 11 + o, [".a.", "aaa", "aaa", "aaa", "aaa"])["a"]
    ear2 = bmp(12, 11 + o, [".a.", "aaa", "aaa"])["a"]
    s.group((body | ear1 | ear2 | legs4(p), F))
    s.fill(rect(10, 14 + o, 10, 15 + o), D, clip=body)
    for x, y0, y1 in ((17, 14, 16), (19, 14, 16), (21, 15, 17)):
        s.fill(rect(x, y0 + o, x, y1 + o), D, clip=body)
    eyes(s, 8, 14, 19 + o, p)
    mouth(s, 11, 20 + o)
    s.fill({(x, y + o) for x, y in ((1, 19), (2, 19), (1, 21), (2, 21), (17, 19), (18, 19), (17, 21), (18, 21))}, LINE)
    return s


def dog(p):
    s = Sprite()
    o, b, t = p.o, p.b, p.o + p.tail
    F, B = hx("#fbf1de"), hx("#b9794a")
    tail = bmp(24, 11 + t, [".tt", ".tt", "tt.", "tt.", "tt.", "tt."])["t"]
    s.group((tail, B))
    body = rrect(4, 14 + o, 24, 26 + b, **LOAF)
    s.group((body | legs4(p), F))
    s.fill(oval(22.5, 15.5 + o, 2.8, 2.6), B, clip=body)
    ear1 = bmp(4, 15 + o, [".ee", "eee", "eee", "eee", "eee", ".e."])["e"]
    ear2 = bmp(14, 14 + o, ["ee.", "eee", "eee", "eee", "eee", ".e."])["e"]
    s.group((ear1, B))
    s.group((ear2, B))
    eyes(s, 9, 13, 18 + o, p)
    s.fill({(11, 20 + o), (10, 21 + o), (12, 21 + o)}, LINE)
    s.fill({(11, 22 + o)}, hx("#ff7d93"))
    return s


def rabbit(p):
    s = Sprite()
    o, b, t = p.o, p.b, p.o + p.tail
    F = hx("#fdfaf5")
    tail = bmp(23, 19 + t, ["ttt.", "tttt", "tttt", "ttt."])["t"]
    s.group((tail, F))
    body = rrect(5, 15 + o, 23, 26 + b, **LOAF)
    ear1 = bmp(7, 4 + o, [".a."] + ["aaa"] * 12)["a"]
    ear2 = bmp(11, 5 + o, [".a."] + ["aaa"] * 9)["a"]
    s.group((body | ear1 | ear2 | legs4(p, (7, 11, 16, 20)), F))
    s.fill(rect(8, 6 + o, 8, 12 + o) | rect(12, 7 + o, 12, 12 + o), PINK)
    eyes(s, 8, 14, 19 + o, p)
    mouth(s, 11, 20 + o, nose=hx("#ff7d93"))
    s.fill({(6, 22 + o), (7, 22 + o), (15, 22 + o), (16, 22 + o)}, PINK)
    return s


def hamster(p):
    s = Sprite()
    o, b = p.o, p.b
    F, W, FOOT = hx("#f3b468"), hx("#fff8ec"), hx("#f7a8a0")
    body = rrect(5, 14 + o, 24, 27 + b, **ROUND)
    ear1 = bmp(8, 12 + o, [".aa", "aaa", "aaa", "aaa"])["a"]
    ear2 = bmp(15, 11 + o, [".aa.", "aaaa", "aaaa"])["a"]
    feet = set()
    for x, (dx, ln) in zip((8, 12, 17, 21), p.legs):
        if ln >= 2:
            feet |= rect(x + dx, 28 + b, x + dx + 1, 28 + b)
    s.group((body | ear1 | ear2, F), (feet, FOOT))
    belly = oval(11, 23.5 + o, 7.5, 4.6) | {q for q in body if q[1] >= 24 + o}
    s.fill(belly, W, clip=body)
    s.fill({(9, 13 + o), (16, 12 + o), (17, 12 + o)}, PINK)
    eyes(s, 8, 14, 19 + o, p)
    mouth(s, 11, 20 + o, nose=hx("#ff7d93"))
    s.fill({(6, 22 + o), (7, 22 + o), (15, 22 + o), (16, 22 + o)}, PINK)
    return s


def fox(p):
    s = Sprite()
    o, b, t = p.o, p.b, p.o + p.tail
    F, W, D = hx("#f08b3e"), hx("#fff6ea"), hx("#4a332c")
    tb = bmp(22, 7 + t, [
        "....www.",
        "...wwwww",
        "...wwwww",
        "..tttttt",
        "..tttttt",
        "..tttttt",
        ".tttttt.",
        ".ttttt..",
        "ttttt...",
        "tttt....",
        "ttt.....",
        "ttt.....",
    ])
    s.group((tb["t"], F), (tb["w"], W))
    body = rrect(4, 14 + o, 24, 26 + b, **LOAF)
    ear1 = bmp(6, 10 + o, [".a.", "aaa", "aaa", "aaa", "aaa", "aaa"])["a"]
    ear2 = bmp(12, 10 + o, [".a.", "aaa", "aaa", "aaa"])["a"]
    s.group((body | ear1 | ear2, F), (legs4(p), D))
    s.fill(rect(6, 10 + o, 8, 11 + o) | rect(12, 10 + o, 14, 11 + o), D, clip=ear1 | ear2)
    s.fill(oval(11, 23.5 + o, 6.5, 3.8), W, clip=body)
    eyes(s, 8, 14, 18 + o, p)
    mouth(s, 11, 20 + o)
    return s


def panda(p):
    s = Sprite()
    o, b = p.o, p.b
    F, K = hx("#fdfbf7"), hx("#2b2326")
    body = rrect(4, 13 + o, 24, 26 + b, **ROUND)
    ear1 = bmp(5, 11 + o, ["aaa", "aaa", "aaa", "aaa"])["a"]
    ear2 = bmp(15, 10 + o, ["aaa", "aaa", "aaa"])["a"]
    s.group((body, F), (ear1 | ear2, K), (legs4(p, (7, 11, 17, 21)), K))
    s.fill(body & (ear1 | ear2), F)
    for ox in (7, 13):
        s.fill(bmp(ox, 18 + o, [".kk", "kkk", "kk."])["k"], K)
        if p.eyes == "open":
            s.fill({(ox + 1, 19 + o)}, WHITE)
        elif p.eyes == "happy":
            s.fill({(ox, 20 + o), (ox + 1, 19 + o), (ox + 2, 20 + o)}, WHITE)
    s.fill({(11, 21 + o), (10, 22 + o), (12, 22 + o)}, LINE)
    return s


def pig(p):
    s = Sprite()
    o, b, t = p.o, p.b, p.o + p.tail
    F, D, H = hx("#f9b5c4"), hx("#ee8ba3"), hx("#a85c70")
    tail = {(x, y + t) for x, y in ((25, 21), (26, 20), (27, 19), (27, 18), (26, 17))}
    s.group((tail, F))
    body = rrect(4, 13 + o, 24, 26 + b, **LOAF)
    ear1 = bmp(6, 11 + o, ["a..", "aa.", "aaa", "aaa", "aaa"])["a"]
    ear2 = bmp(12, 11 + o, ["a..", "aa.", "aaa"])["a"]
    legs = legs4(p)
    s.group((body | legs, F), (ear1 | ear2, D))
    s.fill(body & (ear1 | ear2), F)
    if legs:
        foot_y = max(y for _, y in legs)
        s.fill({q for q in legs if q[1] == foot_y}, H)
    s.fill(bmp(8, 19 + o, [".sss.", "sssss", ".sss."])["s"], D)
    s.fill({(9, 20 + o), (11, 20 + o)}, H)
    eyes(s, 7, 13, 17 + o, p)
    s.fill({(5, 21 + o), (6, 21 + o), (14, 21 + o), (15, 21 + o)}, PINK)
    return s


def chick(p):
    s = Sprite()
    o, b = p.o, p.b
    F, D, O = hx("#ffdc5e"), hx("#f4bb38"), hx("#f28a2e")
    body = rrect(6, 12 + o, 24, 26 + b, tl=[5, 3, 2, 1, 1], tr=[5, 3, 2, 1, 1], bl=[4, 2, 1], br=[4, 2, 1])
    tuft = {(x, y + o) for x, y in ((14, 10), (14, 11), (16, 9), (16, 10), (16, 11))}
    tailf = {(x, y + o) for x, y in ((25, 17), (25, 18), (25, 19), (26, 17))}
    legs = set()
    for x, (dx, ln) in ((12, p.legs[0]), (18, p.legs[3])):
        if ln >= 2:
            legs |= {(x + dx, 27 + b), (x + dx, 28 + b), (x + dx - 1, 28 + b)}
        elif ln == 1:
            legs |= {(x + dx, 27 + b), (x + dx - 1, 27 + b)}
    s.group((body | tuft | tailf, F), (legs, O))
    wing = bmp(18, 19 + o + (-1 if p.lift > 0 else 0), [".ddd.", "ddddd", ".dddd", "..dd."])["d"]
    s.fill(wing, D, clip=body)
    eyes(s, 9, 14, 18 + o, p)
    s.fill({(10, 20 + o), (11, 20 + o), (12, 20 + o), (11, 21 + o)}, O)
    s.fill({(7, 21 + o), (8, 21 + o), (15, 21 + o), (16, 21 + o)}, PINK)
    return s


def fence():
    """울타리 한 토막 (16x16): 뾰족한 말뚝 3개 + 가로대 2줄. 바닥에 딱 붙는다."""
    s = Sprite()
    WOOD, RAIL = hx("#e6b877"), hx("#c98f52")
    pickets = set()
    for x in (1, 6, 11):
        pickets |= rect(x, 3, x + 2, 14) | {(x + 1, 2)}
    rails = rect(1, 6, 13, 7) | rect(1, 11, 13, 12)
    s.group((rails, RAIL), (pickets, WOOD))
    return s


ANIMALS = [
    ("cat", "고양이", cat),
    ("dog", "강아지", dog),
    ("rabbit", "토끼", rabbit),
    ("hamster", "햄스터", hamster),
    ("fox", "여우", fox),
    ("panda", "판다", panda),
    ("pig", "돼지", pig),
    ("chick", "병아리", chick),
]


def font(size):
    for path in ("/System/Library/Fonts/AppleSDGothicNeo.ttc",
                 "/System/Library/Fonts/Supplemental/AppleGothic.ttf"):
        if os.path.exists(path):
            return ImageFont.truetype(path, size)
    return ImageFont.load_default()


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    os.makedirs(SPRITE_DIR, exist_ok=True)

    # 스프라이트 시트
    for key, _, fn in ANIMALS:
        sheet = Image.new("RGBA", (G * len(FRAMES), G), (0, 0, 0, 0))
        for i, (_, pose) in enumerate(FRAMES):
            sheet.paste(fn(pose).image(), (i * G, 0))
        sheet.save(os.path.join(SPRITE_DIR, f"{key}.png"))
        fn(Pose()).image(2).save(os.path.join(OUT_DIR, f"{key}_64.png"))

    fence().image().crop((0, 0, 16, 16)).save(os.path.join(SPRITE_DIR, "fence.png"))

    # 8종 비교
    S, CELL, LAB = 8, 256, 40
    cols, rows = 4, 2
    im = Image.new("RGBA", (cols * CELL, rows * (CELL + LAB)), hx("#e6edf2"))
    d = ImageDraw.Draw(im)
    f = font(24)
    for i, (key, label, fn) in enumerate(ANIMALS):
        cx, cy = (i % cols) * CELL, (i // cols) * (CELL + LAB)
        if (i % cols + i // cols) % 2:
            d.rectangle([cx, cy, cx + CELL - 1, cy + CELL + LAB - 1], fill=hx("#dde6ec"))
        im.alpha_composite(fn(Pose()).image(S), (cx, cy))
        d.text((cx + CELL // 2, cy + CELL + 4), f"{i + 1}. {label}", font=f, fill=LINE, anchor="ma")
    im.save(os.path.join(OUT_DIR, "lineup.png"))

    # 전체 프레임 미리보기 (행 = 동물, 열 = 프레임)
    S2, HEAD = 3, 22
    fw = G * S2
    fr = Image.new("RGBA", (fw * len(FRAMES), HEAD + fw * len(ANIMALS)), hx("#e6edf2"))
    d = ImageDraw.Draw(fr)
    f2 = font(14)
    for i, (name, _) in enumerate(FRAMES):
        d.text((i * fw + fw // 2, 3), name, font=f2, fill=LINE, anchor="ma")
    for r, (key, _, fn) in enumerate(ANIMALS):
        gy = HEAD + r * fw + 30 * S2
        d.line([(0, gy), (fr.width, gy)], fill=hx("#c5d0d8"))
        for i, (_, pose) in enumerate(FRAMES):
            fr.alpha_composite(fn(pose).image(S2), (i * fw, HEAD + r * fw))
    fr.save(os.path.join(OUT_DIR, "frames.png"))
    # 앱 아이콘 (1024px): 둥근 사각 배경 위에 고양이
    icon = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
    ImageDraw.Draw(icon).rounded_rectangle([64, 64, 960, 960], radius=200, fill=hx("#ffe9c9"))
    icon.alpha_composite(cat(Pose()).image(26), (96 + 13, 96 - 78))
    icon.save(os.path.join(SPRITE_DIR, "..", "icon_1024.png"))

    print("saved", len(ANIMALS), "sheets ×", len(FRAMES), "frames →", os.path.normpath(SPRITE_DIR))


if __name__ == "__main__":
    main()

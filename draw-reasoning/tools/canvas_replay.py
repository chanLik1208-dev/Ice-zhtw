"""依 session.json 的動作重建畫布。

繪圖規則與 recorder/index.html 一致：
  - 每個動作先在第一點畫一個圓點（直徑 = 該點線寬），再把相鄰兩點連成圓頭線段
  - 線段線寬 = width * 畫布寬 * 兩端壓力係數的平均
  - 壓力係數：pen 為 0.15 + 0.85 * pressure，其餘（滑鼠、觸控）固定為 1
  - erase 用背景色畫
  - 有 smooth（防手抖）時畫 smooth["points"]，否則畫 points
  - opacity < 1：整筆先不透明地畫在空白圖層，再以 opacity 疊上去
  - fill：從點擊位置做 4 連通填色，RGB 每個色版和起點顏色相差 <= tolerance 的都算同一區，
    再往外擴 FILL_EXPAND px（8 連通），以 opacity 混色

effective_after() 只用標準函式庫；render() 需要 Pillow（pip install Pillow）。
Pillow 沒有反鋸齒，筆畫用超取樣近似，線條邊緣會和瀏覽器有細微差異；
漆桶在原解析度上計算，和瀏覽器一樣。
"""

from __future__ import annotations

import math

DRAWING_TYPES = ("stroke", "erase", "fill")
FILL_EXPAND = 1


def effective_after(actions: list[dict]) -> dict[int, tuple[int, ...]]:
    """回傳 {動作 id: 該動作之後畫布上仍有效的 stroke/erase/fill id（依順序）}，0 代表空白畫布。"""
    result: dict[int, tuple[int, ...]] = {0: ()}
    active: list[int] = []
    for a in actions:
        if a["type"] in DRAWING_TYPES:
            active.append(a["id"])
        elif a["type"] == "undo" and a.get("target_id") in active:
            active.remove(a["target_id"])
        result[a["id"]] = tuple(active)
    return result


def pressure_factor(pressure: float, pointer: str | None) -> float:
    if pointer != "pen":
        return 1.0
    return 0.15 + 0.85 * min(max(pressure, 0.0), 1.0)


def points_of(action: dict) -> list:
    smooth = action.get("smooth")
    return smooth["points"] if smooth else action["points"]


def opacity_of(action: dict) -> float:
    op = action.get("opacity")
    return 1.0 if op is None else float(op)


def _hex_to_rgb(color: str) -> tuple[int, int, int]:
    c = color.lstrip("#")
    if len(c) == 3:
        c = "".join(ch * 2 for ch in c)
    return int(c[0:2], 16), int(c[2:4], 16), int(c[4:6], 16)


def _draw_geometry(draw, action: dict, width: int, height: int, fill) -> None:
    points = points_of(action)
    if not points:
        return
    base = action["width"] * width
    pointer = action.get("pointer")

    def dot(x: float, y: float, diameter: float) -> None:
        r = diameter / 2
        draw.ellipse((x - r, y - r, x + r, y + r), fill=fill)

    x0, y0, p0 = points[0][0] * width, points[0][1] * height, points[0][2]
    dot(x0, y0, base * pressure_factor(p0, pointer))
    for p in points[1:]:
        x1, y1 = p[0] * width, p[1] * height
        lw = base * (pressure_factor(p0, pointer) + pressure_factor(p[2], pointer)) / 2
        draw.line((x0, y0, x1, y1), fill=fill, width=max(1, round(lw)))
        # 圓頭線段：兩端各補一個直徑等於線寬的圓
        dot(x0, y0, lw)
        dot(x1, y1, lw)
        x0, y0, p0 = x1, y1, p[2]


def flood_fill(img, action: dict) -> None:
    """在原解析度的 RGB 圖上就地填色。"""
    from PIL import Image, ImageFilter

    w, h = img.size
    px, py = action["points"][0][0], action["points"][0][1]
    sx, sy = math.floor(px * w), math.floor(py * h)
    if not (0 <= sx < w and 0 <= sy < h):
        return
    data = img.tobytes()
    i0 = (sy * w + sx) * 3
    r0, g0, b0 = data[i0], data[i0 + 1], data[i0 + 2]
    tol = action["tolerance"]

    def match(p: int) -> bool:
        i = p * 3
        return (abs(data[i] - r0) <= tol and abs(data[i + 1] - g0) <= tol
                and abs(data[i + 2] - b0) <= tol)

    mask = bytearray(w * h)
    start = sy * w + sx
    mask[start] = 255
    stack = [start]
    last_row = w * (h - 1)
    while stack:
        p = stack.pop()
        x = p % w
        for q, ok in ((p - 1, x > 0), (p + 1, x < w - 1), (p - w, p >= w), (p + w, p < last_row)):
            if ok and not mask[q] and match(q):
                mask[q] = 255
                stack.append(q)

    m = Image.frombytes("L", (w, h), bytes(mask))
    for _ in range(FILL_EXPAND):
        m = m.filter(ImageFilter.MaxFilter(3))
    alpha = opacity_of(action)
    if alpha < 1:
        m = m.point(lambda v: round(v * alpha))
    color = Image.new("RGB", (w, h), _hex_to_rgb(action["color"]))
    img.paste(Image.composite(color, img, m))


def render(session: dict, action_ids, base_image=None, supersample: int = 2):
    """在 base_image（None 代表空白畫布）上依序畫出 action_ids，回傳 PIL.Image（RGB）。"""
    from PIL import Image, ImageDraw

    canvas = session["canvas"]
    w, h, bg = canvas["width"], canvas["height"], canvas.get("background", "#ffffff")
    ss = max(1, int(supersample))
    W, H = w * ss, h * ss
    if base_image is None:
        img = Image.new("RGB", (W, H), _hex_to_rgb(bg))
    else:
        # 最近鄰放大：沒有被畫到的地方縮回去後與原圖完全相同
        img = base_image.convert("RGB").resize((W, H), Image.NEAREST)
    by_id = {a["id"]: a for a in session["actions"]}
    for action_id in action_ids:
        action = by_id[action_id]
        if action["type"] == "fill":
            # 漆桶要在原解析度判斷顏色，和瀏覽器一致
            small = img.reduce(ss) if ss > 1 else img
            flood_fill(small, action)
            img = small.resize((W, H), Image.NEAREST) if ss > 1 else small
            continue
        rgb = _hex_to_rgb(bg if action["type"] == "erase" else action["color"])
        alpha = opacity_of(action)
        if alpha >= 1:
            _draw_geometry(ImageDraw.Draw(img), action, W, H, rgb)
        else:
            mask = Image.new("L", (W, H), 0)
            _draw_geometry(ImageDraw.Draw(mask), action, W, H, 255)
            mask = mask.point(lambda v: round(v * alpha))
            img = Image.composite(Image.new("RGB", (W, H), rgb), img, mask)
    return img.reduce(ss) if ss > 1 else img

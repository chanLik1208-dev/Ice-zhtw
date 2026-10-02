"""依 session.json 的動作重建畫布。

繪圖規則與 recorder/index.html 一致：
  - 每個動作先在第一點畫一個圓點（直徑 = 該點線寬），再把相鄰兩點連成圓頭線段
  - 線段線寬 = width * 畫布寬 * 兩端壓力係數的平均
  - 壓力係數：pen 為 0.15 + 0.85 * pressure，其餘（滑鼠、觸控）固定為 1
  - erase 用背景色畫

effective_after() 只用標準函式庫；render() 需要 Pillow（pip install Pillow）。
Pillow 沒有反鋸齒，這裡用超取樣近似，線條邊緣會和瀏覽器有細微差異。
"""

from __future__ import annotations

DRAWING_TYPES = ("stroke", "erase")


def effective_after(actions: list[dict]) -> dict[int, tuple[int, ...]]:
    """回傳 {動作 id: 該動作之後畫布上仍有效的 stroke/erase id（依順序）}，0 代表空白畫布。"""
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


def _hex_to_rgb(color: str) -> tuple[int, int, int]:
    c = color.lstrip("#")
    if len(c) == 3:
        c = "".join(ch * 2 for ch in c)
    return int(c[0:2], 16), int(c[2:4], 16), int(c[4:6], 16)


def _draw_action(draw, action: dict, width: int, height: int, background: str) -> None:
    points = action["points"]
    if not points:
        return
    fill = _hex_to_rgb(background if action["type"] == "erase" else action["color"])
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


def render(session: dict, action_ids, base_image=None, supersample: int = 2):
    """在 base_image（None 代表空白畫布）上依序畫出 action_ids，回傳 PIL.Image（RGB）。"""
    from PIL import Image, ImageDraw

    canvas = session["canvas"]
    w, h, bg = canvas["width"], canvas["height"], canvas.get("background", "#ffffff")
    ss = max(1, int(supersample))
    if base_image is None:
        img = Image.new("RGB", (w * ss, h * ss), _hex_to_rgb(bg))
    else:
        # 最近鄰放大：沒有被畫到的地方縮回去後與原圖完全相同
        img = base_image.convert("RGB").resize((w * ss, h * ss), Image.NEAREST)
    draw = ImageDraw.Draw(img)
    by_id = {a["id"]: a for a in session["actions"]}
    for action_id in action_ids:
        _draw_action(draw, by_id[action_id], w * ss, h * ss, bg)
    return img.reduce(ss) if ss > 1 else img

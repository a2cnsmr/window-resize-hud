#!/usr/bin/env python3
"""WindowResizeHUD のアプリアイコンを描画するスクリプト。

デザイン: 青い角丸スクエアの上に、HUDの矩形 (破線) で囲まれたウインドウと、
右下のリサイズ矢印 (両方向) を置く。
4倍解像度で描いてから縮小し、AppIcon.iconset の各サイズを書き出す。
"""
import math
import os
from PIL import Image, ImageDraw

S = 4  # supersampling
SIZE = 1024 * S
OUT_DIR = os.path.dirname(os.path.abspath(__file__))
WHITE = (255, 255, 255, 255)


def sc(v):
    return v * S


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def make_gradient(size):
    top = (10, 132, 255)     # #0A84FF
    bottom = (0, 82, 204)    # #0052CC
    small = Image.new("RGB", (256, 256))
    px = small.load()
    for y in range(256):
        for x in range(256):
            t = (x + y) / 510.0
            px[x, y] = lerp(top, bottom, t)
    return small.resize((size, size), Image.LANCZOS).convert("RGBA")


def dashed_rect(draw, box, fill, width, dash, gap):
    x0, y0, x1, y1 = box
    # 上辺・下辺
    for y in (y0, y1):
        x = x0
        while x < x1:
            draw.line([x, y, min(x + dash, x1), y], fill=fill, width=width)
            x += dash + gap
    # 左辺・右辺 (角で横辺と重ならないよう、少し内側から始める)
    for x in (x0, x1):
        y = y0 + dash + gap
        while y + dash <= y1 - gap:
            draw.line([x, y, x, y + dash], fill=fill, width=width)
            y += dash + gap


def arrow_head(draw, tip, direction, length, half_width, fill):
    dx, dy = direction
    nx, ny = -dy, dx
    bx, by = tip[0] - dx * length, tip[1] - dy * length
    p1 = (bx + nx * half_width, by + ny * half_width)
    p2 = (bx - nx * half_width, by - ny * half_width)
    draw.polygon([tip, p1, p2], fill=fill)


def main():
    img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))

    # 本体 (角丸スクエア) にグラデーションをマスク貼り
    body_box = [sc(100), sc(100), sc(924), sc(924)]
    mask = Image.new("L", (SIZE, SIZE), 0)
    md = ImageDraw.Draw(mask)
    md.rounded_rectangle(body_box, radius=sc(190), fill=255)
    img.paste(make_gradient(SIZE), (0, 0), mask)

    d = ImageDraw.Draw(img)

    # HUDの矩形 (破線)
    dashed_rect(
        d,
        [sc(238), sc(262), sc(786), sc(762)],
        fill=(255, 255, 255, 235),
        width=sc(22),
        dash=sc(46),
        gap=sc(30),
    )

    # ウインドウ本体
    d.rounded_rectangle(
        [sc(322), sc(352), sc(702), sc(672)],
        radius=sc(26),
        fill=(255, 255, 255, 245),
    )
    # 信号ボタン
    for cx, color in ((368, (255, 95, 87)), (412, (254, 188, 46)), (456, (40, 200, 64))):
        r = sc(16)
        cy = sc(400)
        d.ellipse([sc(cx) - r, cy - r, sc(cx) + r, cy + r], fill=color + (255,))

    # 右下のリサイズ矢印 (両方向・斜め)
    tip_se = (sc(848), sc(824))
    tip_nw = (sc(724), sc(700))
    d.line([tip_nw, tip_se], fill=WHITE, width=sc(36))
    diag = math.sqrt(0.5)
    arrow_head(d, tip_se, (diag, diag), sc(60), sc(42), WHITE)
    arrow_head(d, tip_nw, (-diag, -diag), sc(60), sc(42), WHITE)

    master = img.resize((1024, 1024), Image.LANCZOS)
    master.save(os.path.join(OUT_DIR, "AppIcon-1024.png"))

    iconset = os.path.join(OUT_DIR, "AppIcon.iconset")
    os.makedirs(iconset, exist_ok=True)
    specs = [
        ("icon_16x16.png", 16),
        ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32),
        ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128),
        ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256),
        ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512),
        ("icon_512x512@2x.png", 1024),
    ]
    for name, px in specs:
        master.resize((px, px), Image.LANCZOS).save(os.path.join(iconset, name))
    print("wrote", os.path.join(OUT_DIR, "AppIcon-1024.png"))
    print("wrote", iconset, f"({len(specs)} files)")


if __name__ == "__main__":
    main()

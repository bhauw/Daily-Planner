#!/usr/bin/env python3
"""Generate the Daily Planner app icon master art.

Design language matches the running app: a dark ground, calm, with a
schedule / dayline motif — a time gutter and a few category-coloured event
blocks laid out like a day's schedule. No emoji, no stock clipart; the whole
mark is drawn procedurally from the product's design tokens.

Output: AppIcon-1024.png (master, RGBA). The .icns is produced from this by
build-app.sh via sips + iconutil.
"""
from __future__ import annotations

from PIL import Image, ImageDraw

S = 1024                     # master canvas
MARGIN = 100                 # transparent margin so the squircle reads in the Dock
BOX = S - 2 * MARGIN         # squircle side (824), Apple-grid content size

# Design tokens (sampled from the running app — do not invent)
GROUND_TOP = (35, 34, 33)    # --chrome  #232221
GROUND_BOT = (24, 24, 24)    #           slightly darker toward the base
RAIL = (65, 51, 38)          # --rail    #413326
BORDER = (51, 51, 49)        # --border  #333331
GUTTER_TEXT = (110, 110, 115)  # --text-3 #6E6E73
LINE = (42, 42, 41)          # --border-soft #2A2A29

SCHOOL = (10, 132, 255)      # --school  #0A84FF
DEADLINE = (179, 158, 235)   # --deadline #B39EEB (lavender)
EXTRA = (48, 209, 88)        # --extracurricular #30D158
CAREER = (255, 214, 10)      # --career  #FFD60A


def rounded_mask(size: int, radius: int) -> Image.Image:
    m = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(m)
    d.rounded_rectangle([0, 0, size - 1, size - 1], radius=radius, fill=255)
    return m


def vertical_gradient(size: int, top, bot) -> Image.Image:
    g = Image.new("RGB", (1, size))
    for y in range(size):
        t = y / (size - 1)
        g.putpixel((0, y), tuple(round(top[i] + (bot[i] - top[i]) * t) for i in range(3)))
    return g.resize((size, size))


def main() -> None:
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))

    # Squircle ground with a calm top->bottom gradient.
    radius = round(BOX * 0.2237)             # Apple continuous-corner ratio
    ground = vertical_gradient(BOX, GROUND_TOP, GROUND_BOT).convert("RGBA")
    ground.putalpha(rounded_mask(BOX, radius))
    img.alpha_composite(ground, (MARGIN, MARGIN))

    d = ImageDraw.Draw(img)

    # Inner content frame inside the squircle.
    inset = MARGIN + 96
    left = inset
    right = S - inset
    top = inset
    bottom = S - inset

    # Time gutter: a warm rail down the left, evoking the dayline's time column.
    gutter_w = 150
    gx = left
    d.rounded_rectangle([gx, top, gx + gutter_w, bottom], radius=28, fill=RAIL)

    # Hour ticks in the gutter (SF-Mono-style short marks, numerics only motif).
    rows = 5
    row_h = (bottom - top) / rows
    for i in range(1, rows):
        y = round(top + i * row_h)
        d.line([gx + 34, y, gx + gutter_w - 34, y], fill=GUTTER_TEXT, width=8)

    # Schedule lane: ruled horizontal lines like a day grid.
    lane_l = gx + gutter_w + 60
    for i in range(1, rows):
        y = round(top + i * row_h)
        d.line([lane_l, y, right, y], fill=LINE, width=6)

    # Category-coloured event blocks laid out down the day.
    def block(row: int, span: float, indent: int, colour) -> None:
        y0 = round(top + row * row_h + row_h * 0.16)
        y1 = round(top + (row + span) * row_h - row_h * 0.16)
        x0 = lane_l + indent
        x1 = right
        d.rounded_rectangle([x0, y0, x1, y1], radius=22, fill=colour)
        # A brighter left edge — the accent bar the app uses on event cards.
        d.rounded_rectangle([x0, y0, x0 + 20, y1], radius=10, fill=colour)

    block(0, 1.0, 0, SCHOOL)      # morning: school (blue)
    block(1, 0.5, 40, CAREER)     # a short career block (yellow)
    block(2, 1.0, 0, EXTRA)       # extracurricular (green)
    block(3, 1.0, 30, DEADLINE)   # a deadline (lavender)

    # Hairline border to sit the mark inside the squircle cleanly.
    bimg = Image.new("RGBA", (BOX, BOX), (0, 0, 0, 0))
    ImageDraw.Draw(bimg).rounded_rectangle(
        [2, 2, BOX - 3, BOX - 3], radius=radius - 2, outline=BORDER, width=4
    )
    img.alpha_composite(bimg, (MARGIN, MARGIN))

    out = __import__("pathlib").Path(__file__).with_name("AppIcon-1024.png")
    img.save(out)
    print(f"wrote {out} ({img.size[0]}x{img.size[1]})")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Generate AppIcon.appiconset entries: book + headphones glyph.

Output: PNG icons sized for every iOS / macOS / iPadOS slot, plus a
Contents.json that Xcode reads. Re-run any time you want a fresh
look — there are no external image dependencies; the icon is drawn
from scratch with PIL.
"""

from __future__ import annotations

import json
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[1]
TARGET = ROOT / "EpubToMp3" / "Assets.xcassets" / "AppIcon.appiconset"

# (size_pt, scale, idiom)
IOS_SLOTS = [
    (20, 2, "iphone"),
    (20, 3, "iphone"),
    (29, 2, "iphone"),
    (29, 3, "iphone"),
    (40, 2, "iphone"),
    (40, 3, "iphone"),
    (60, 2, "iphone"),
    (60, 3, "iphone"),
    (20, 1, "ipad"),
    (20, 2, "ipad"),
    (29, 1, "ipad"),
    (29, 2, "ipad"),
    (40, 1, "ipad"),
    (40, 2, "ipad"),
    (76, 2, "ipad"),
    (83.5, 2, "ipad"),
    (1024, 1, "ios-marketing"),
]
MAC_SLOTS = [
    (16, 1, "mac"),
    (16, 2, "mac"),
    (32, 1, "mac"),
    (32, 2, "mac"),
    (128, 1, "mac"),
    (128, 2, "mac"),
    (256, 1, "mac"),
    (256, 2, "mac"),
    (512, 1, "mac"),
    (512, 2, "mac"),
]


def draw_master(size: int = 1024) -> Image.Image:
    """Render the master 1024x1024 icon. Composition:
    - Rounded square background (gradient, indigo→teal).
    - Open book in the lower-left third (paper colour, two pages).
    - Headphones arc + ear cups overlapping the book."""
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    # Background gradient — vertical, indigo top → teal bottom.
    bg_top = (60, 80, 200)
    bg_bot = (40, 170, 180)
    grad = Image.new("RGB", (1, size), 0)
    for y in range(size):
        t = y / size
        r = int(bg_top[0] * (1 - t) + bg_bot[0] * t)
        g = int(bg_top[1] * (1 - t) + bg_bot[1] * t)
        b = int(bg_top[2] * (1 - t) + bg_bot[2] * t)
        grad.putpixel((0, y), (r, g, b))
    grad = grad.resize((size, size))
    img.paste(grad, (0, 0))

    # Soft glow under the book.
    glow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    gd.ellipse((size * 0.10, size * 0.55, size * 0.95, size * 0.95), fill=(255, 255, 255, 60))
    glow = glow.filter(ImageFilter.GaussianBlur(60))
    img = Image.alpha_composite(img, glow)
    d = ImageDraw.Draw(img)

    # Book — two open pages forming a wide V.
    paper = (250, 246, 232)
    paper_dark = (218, 210, 188)
    spine_x = size / 2
    book_top = size * 0.50
    book_bot = size * 0.84
    book_left = size * 0.16
    book_right = size * 0.84

    # Left page (back).
    d.polygon(
        [(book_left, book_bot - 10), (spine_x - 8, book_top + 30), (spine_x - 8, book_bot)],
        fill=paper_dark,
    )
    # Right page (back).
    d.polygon(
        [(spine_x + 8, book_top + 30), (book_right, book_bot - 10), (spine_x + 8, book_bot)],
        fill=paper_dark,
    )
    # Left page (front sheet).
    d.polygon(
        [
            (book_left + 24, book_bot - 22),
            (spine_x - 14, book_top + 56),
            (spine_x - 14, book_bot - 12),
        ],
        fill=paper,
    )
    # Right page (front sheet).
    d.polygon(
        [
            (spine_x + 14, book_top + 56),
            (book_right - 24, book_bot - 22),
            (spine_x + 14, book_bot - 12),
        ],
        fill=paper,
    )

    # Page lines.
    line_color = (140, 130, 100)
    for i in range(4):
        y = book_top + 110 + i * 38
        d.line([(book_left + 70, y + i * 10), (spine_x - 30, y - 5)], fill=line_color, width=4)
        d.line([(spine_x + 30, y - 5), (book_right - 70, y + i * 10)], fill=line_color, width=4)

    # Headphones — arc band + two ear cups, sitting above the book.
    band_color = (245, 245, 245)
    cup_color = (35, 35, 38)
    cup_inner = (90, 90, 95)

    band_box = (size * 0.18, size * 0.10, size * 0.82, size * 0.66)
    d.arc(band_box, start=190, end=350, fill=band_color, width=22)

    # Left cup.
    cup_lx, cup_ly = size * 0.20, size * 0.40
    cup_size = size * 0.16
    d.ellipse((cup_lx, cup_ly, cup_lx + cup_size, cup_ly + cup_size), fill=cup_color)
    d.ellipse(
        (cup_lx + 14, cup_ly + 14, cup_lx + cup_size - 14, cup_ly + cup_size - 14),
        fill=cup_inner,
    )
    # Right cup.
    cup_rx = size * 0.80 - cup_size
    cup_ry = cup_ly
    d.ellipse((cup_rx, cup_ry, cup_rx + cup_size, cup_ry + cup_size), fill=cup_color)
    d.ellipse(
        (cup_rx + 14, cup_ry + 14, cup_rx + cup_size - 14, cup_ry + cup_size - 14),
        fill=cup_inner,
    )

    # Apply rounded-square mask (Apple's icon shape).
    mask = Image.new("L", (size, size), 0)
    md = ImageDraw.Draw(mask)
    radius = int(size * 0.225)  # matches the iOS continuous rounded rect.
    md.rounded_rectangle((0, 0, size, size), radius=radius, fill=255)
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    out.paste(img, (0, 0), mask)
    return out


def main() -> None:
    TARGET.mkdir(parents=True, exist_ok=True)
    master = draw_master(1024)

    contents = {"images": [], "info": {"version": 1, "author": "xcode"}}

    def emit(slots: list, role: str) -> None:
        for size_pt, scale, idiom in slots:
            px = int(size_pt * scale)
            filename = f"icon-{idiom}-{size_pt}@{scale}x.png"
            master.resize((px, px), Image.LANCZOS).save(TARGET / filename)
            entry = {
                "size": f"{size_pt}x{size_pt}",
                "idiom": idiom,
                "filename": filename,
                "scale": f"{scale}x",
            }
            contents["images"].append(entry)

    emit(IOS_SLOTS, "ios")
    emit(MAC_SLOTS, "mac")

    (TARGET / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n")
    print(f"Wrote {len(contents['images'])} icons to {TARGET}")


if __name__ == "__main__":
    main()

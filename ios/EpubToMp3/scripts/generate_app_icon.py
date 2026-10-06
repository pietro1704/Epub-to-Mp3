#!/usr/bin/env python3
"""Generate the EpubToMp3 app icon — a closed book with headphones
draped over it (audiobook). Renders a supersampled master, then writes
every size the AppIcon asset catalog needs.

Run: python3 ios/EpubToMp3/scripts/generate_app_icon.py
"""

from __future__ import annotations

import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

# Supersample factor — draw big, downsample for crisp anti-aliasing.
SS = 4
BASE = 1024
M = BASE * SS

ICONSET = Path(__file__).resolve().parent.parent / "EpubToMp3/Assets.xcassets/AppIcon.appiconset"

# Pixel size of every file the catalog references.
SIZES = {
    "icon-iphone-20@2x.png": 40,
    "icon-iphone-20@3x.png": 60,
    "icon-iphone-29@2x.png": 58,
    "icon-iphone-29@3x.png": 87,
    "icon-iphone-40@2x.png": 80,
    "icon-iphone-40@3x.png": 120,
    "icon-iphone-60@2x.png": 120,
    "icon-iphone-60@3x.png": 180,
    "icon-ipad-20@1x.png": 20,
    "icon-ipad-20@2x.png": 40,
    "icon-ipad-29@1x.png": 29,
    "icon-ipad-29@2x.png": 58,
    "icon-ipad-40@1x.png": 40,
    "icon-ipad-40@2x.png": 80,
    "icon-ipad-76@2x.png": 152,
    "icon-ipad-83.5@2x.png": 167,
    "icon-ios-marketing-1024@1x.png": 1024,
    "icon-mac-16@1x.png": 16,
    "icon-mac-16@2x.png": 32,
    "icon-mac-32@1x.png": 32,
    "icon-mac-32@2x.png": 64,
    "icon-mac-128@1x.png": 128,
    "icon-mac-128@2x.png": 256,
    "icon-mac-256@1x.png": 256,
    "icon-mac-256@2x.png": 512,
    "icon-mac-512@1x.png": 512,
    "icon-mac-512@2x.png": 1024,
}


def lerp(a: tuple[int, int, int], b: tuple[int, int, int], t: float):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))


def vertical_gradient(size: int, top, bottom) -> Image.Image:
    grad = Image.new("RGB", (1, size))
    px = grad.load()
    for y in range(size):
        px[0, y] = lerp(top, bottom, y / (size - 1))
    return grad.resize((size, size))


def rounded_mask(size: int, radius: int) -> Image.Image:
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, size - 1, size - 1], radius=radius, fill=255)
    return mask


def draw_icon() -> Image.Image:
    img = Image.new("RGBA", (M, M), (0, 0, 0, 0))

    # --- Background: rounded-rect, periwinkle -> deep indigo -------
    bg = vertical_gradient(M, (114, 103, 240), (58, 44, 150)).convert("RGBA")
    bg.putalpha(rounded_mask(M, int(0.2237 * M)))
    img.alpha_composite(bg)

    draw = ImageDraw.Draw(img)

    # Book geometry --------------------------------------------------
    bw, bh = int(0.44 * M), int(0.50 * M)
    cx, cy = M // 2, int(0.565 * M)
    bl, bt = cx - bw // 2, cy - bh // 2
    br, bb = bl + bw, bt + bh

    # --- Drop shadow under the book --------------------------------
    shadow = Image.new("RGBA", (M, M), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        [bl + int(0.02 * M), bt + int(0.05 * M), br + int(0.03 * M), bb + int(0.055 * M)],
        radius=int(0.05 * M),
        fill=(20, 12, 50, 150),
    )
    shadow = shadow.filter(ImageFilter.GaussianBlur(int(0.022 * M)))
    img.alpha_composite(shadow)

    # --- Page block (cream) — peeks on the right + bottom ----------
    poff = int(0.020 * M)
    draw.rounded_rectangle(
        [bl + poff, bt + poff, br + poff, bb + poff],
        radius=int(0.028 * M),
        fill=(245, 236, 218, 255),
    )
    # Page-edge striations on the right sliver.
    for i in range(1, 6):
        x = br + int(0.004 * M) * i
        draw.line(
            [(x, bt + poff + int(0.05 * M)), (x, bb + poff - int(0.05 * M))],
            fill=(214, 201, 176, 200),
            width=max(1, SS),
        )

    # --- Book cover: coral rounded-rect ----------------------------
    cover = Image.new("RGBA", (M, M), (0, 0, 0, 0))
    cgrad = vertical_gradient(M, (240, 126, 96), (214, 70, 52)).convert("RGBA")
    cmask = Image.new("L", (M, M), 0)
    ImageDraw.Draw(cmask).rounded_rectangle([bl, bt, br, bb], radius=int(0.045 * M), fill=255)
    cover.paste(cgrad, (0, 0), cmask)
    img.alpha_composite(cover)

    # Spine — darker strip down the left edge of the cover.
    spine_w = int(0.085 * bw)
    spine = Image.new("RGBA", (M, M), (0, 0, 0, 0))
    sd = ImageDraw.Draw(spine)
    sd.rounded_rectangle(
        [bl, bt, bl + spine_w * 2, bb], radius=int(0.045 * M), fill=(176, 52, 38, 255)
    )
    sm = Image.new("L", (M, M), 0)
    ImageDraw.Draw(sm).rectangle([bl, bt, bl + spine_w, bb], fill=255)
    img.paste(spine, (0, 0), Image.composite(spine.split()[3], Image.new("L", (M, M), 0), sm))
    # Spine embossed lines.
    for fy in (0.14, 0.86):
        y = bt + int(fy * bh)
        draw.line(
            [(bl + int(0.012 * M), y), (bl + spine_w - int(0.012 * M), y)],
            fill=(150, 40, 28, 255),
            width=max(1, 2 * SS),
        )

    # Cover title lines (lower half, clear of the headphone band).
    tlx0 = bl + spine_w + int(0.06 * bw)
    tlx1 = br - int(0.10 * bw)
    for i, fy in enumerate((0.66, 0.74)):
        y = bt + int(fy * bh)
        x1 = tlx1 if i == 0 else tlx0 + int(0.55 * (tlx1 - tlx0))
        draw.rounded_rectangle(
            [tlx0, y, x1, y + int(0.022 * bh)],
            radius=int(0.011 * bh),
            fill=(255, 233, 214, 235),
        )

    # --- Headphones draped over the book ---------------------------
    dark = (33, 27, 56, 255)
    cup_w, cup_h = int(0.150 * M), int(0.250 * M)
    cup_cy = bt + int(0.30 * bh)
    lcx = bl - int(0.018 * M)  # left cup centre x (overlaps book)
    rcx = br + int(0.018 * M)  # right cup centre x

    # Headband — thick arc passing above the book's top edge.
    band_w = int(0.052 * M)
    band_top = bt - int(0.085 * M)
    band = Image.new("RGBA", (M, M), (0, 0, 0, 0))
    bd = ImageDraw.Draw(band)
    bd.arc(
        [lcx, band_top, rcx, cup_cy + int(0.02 * M)], start=180, end=360, fill=dark, width=band_w
    )
    # Soft highlight along the band's upper edge.
    bd.arc(
        [lcx, band_top + int(0.012 * M), rcx, cup_cy],
        start=200,
        end=340,
        fill=(92, 84, 132, 220),
        width=max(1, band_w // 5),
    )
    img.alpha_composite(band)

    # Ear cups — dark capsules with a lighter ear-pad.
    for ccx in (lcx, rcx):
        x0, x1 = ccx - cup_w // 2, ccx + cup_w // 2
        y0, y1 = cup_cy - cup_h // 2, cup_cy + cup_h // 2
        draw.rounded_rectangle([x0, y0, x1, y1], radius=cup_w // 2, fill=dark)
        pad = int(0.026 * M)
        draw.rounded_rectangle(
            [x0 + pad, y0 + pad, x1 - pad, y1 - pad],
            radius=(cup_w - 2 * pad) // 2,
            fill=(108, 100, 150, 255),
        )
        # Tiny specular dot on the pad.
        draw.ellipse(
            [
                ccx - int(0.018 * M),
                cup_cy - int(0.052 * M),
                ccx + int(0.012 * M),
                cup_cy - int(0.022 * M),
            ],
            fill=(150, 143, 188, 230),
        )

    return img.resize((BASE, BASE), Image.LANCZOS)


def main() -> int:
    if not ICONSET.is_dir():
        print(f"error: iconset not found at {ICONSET}", file=sys.stderr)
        return 1
    master = draw_icon()
    # macOS applies its own rounded presentation; keep the artwork inside the
    # platform safe area so it does not look larger than neighbouring apps.
    mac_master = Image.new("RGBA", (BASE, BASE), (0, 0, 0, 0))
    mac_art = master.resize((int(BASE * 0.80), int(BASE * 0.80)), Image.LANCZOS)
    mac_master.alpha_composite(mac_art, (int(BASE * 0.10), int(BASE * 0.10)))
    preview = Path("/tmp/app_icon_preview.png")
    master.save(preview)
    print(f"master preview -> {preview}")
    for name, px in SIZES.items():
        source = mac_master if name.startswith("icon-mac-") else master
        source.resize((px, px), Image.LANCZOS).save(ICONSET / name)
    print(f"wrote {len(SIZES)} icon files to {ICONSET}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

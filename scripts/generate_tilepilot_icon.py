#!/usr/bin/env python3
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter


SIZE = 1024


def vertical_gradient(size, top, bottom):
    w, h = size
    img = Image.new("RGBA", size)
    px = img.load()
    for y in range(h):
        t = y / max(h - 1, 1)
        r = int(top[0] + (bottom[0] - top[0]) * t)
        g = int(top[1] + (bottom[1] - top[1]) * t)
        b = int(top[2] + (bottom[2] - top[2]) * t)
        a = int(top[3] + (bottom[3] - top[3]) * t)
        for x in range(w):
            px[x, y] = (r, g, b, a)
    return img


def radial_glow(size, center, radius, color):
    w, h = size
    glow = Image.new("RGBA", size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(glow)
    cx, cy = center
    for i in range(radius, 0, -10):
        alpha = int(color[3] * (i / radius) ** 2)
        draw.ellipse((cx - i, cy - i, cx + i, cy + i), fill=(color[0], color[1], color[2], alpha))
    return glow.filter(ImageFilter.GaussianBlur(18))


def main():
    root = Path(__file__).resolve().parents[1]
    out_dir = root / "assets" / "icon"
    out_dir.mkdir(parents=True, exist_ok=True)
    out_path = out_dir / "tilepilot-icon-1024.png"

    img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))

    # Background shell
    bg = vertical_gradient((SIZE, SIZE), (20, 27, 38, 255), (10, 14, 22, 255))
    img.alpha_composite(bg)

    # Soft blue glows
    img.alpha_composite(radial_glow((SIZE, SIZE), (220, 210), 260, (82, 196, 255, 70)))
    img.alpha_composite(radial_glow((SIZE, SIZE), (820, 820), 300, (120, 140, 255, 55)))

    draw = ImageDraw.Draw(img)

    # Rounded square mask / panel
    panel_margin = 52
    panel_rect = (panel_margin, panel_margin, SIZE - panel_margin, SIZE - panel_margin)
    panel = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    pdraw = ImageDraw.Draw(panel)
    pdraw.rounded_rectangle(panel_rect, radius=210, fill=(18, 23, 33, 235))
    # subtle inner border
    pdraw.rounded_rectangle(panel_rect, radius=210, outline=(255, 255, 255, 26), width=4)
    img.alpha_composite(panel)

    # Tile grid (4 windows)
    outer = 170
    gap = 44
    tile_w = (SIZE - 2 * outer - gap) // 2
    tile_h = tile_w
    tile_radius = 72
    tiles = [
        (outer, outer),
        (outer + tile_w + gap, outer),
        (outer, outer + tile_h + gap),
        (outer + tile_w + gap, outer + tile_h + gap),
    ]

    # Shadows
    shadow_layer = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    sdraw = ImageDraw.Draw(shadow_layer)
    for x, y in tiles:
        sdraw.rounded_rectangle(
            (x + 12, y + 16, x + tile_w + 12, y + tile_h + 16),
            radius=tile_radius,
            fill=(0, 0, 0, 90),
        )
    shadow_layer = shadow_layer.filter(ImageFilter.GaussianBlur(18))
    img.alpha_composite(shadow_layer)

    # White tiles
    tile_layer = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    tdraw = ImageDraw.Draw(tile_layer)
    whites = [(248, 250, 255, 255), (241, 246, 255, 255), (250, 251, 255, 255), (243, 248, 255, 255)]
    for (x, y), fill in zip(tiles, whites):
        tdraw.rounded_rectangle((x, y, x + tile_w, y + tile_h), radius=tile_radius, fill=fill)
        tdraw.rounded_rectangle((x, y, x + tile_w, y + tile_h), radius=tile_radius, outline=(255, 255, 255, 80), width=2)
    img.alpha_composite(tile_layer)

    # Tiny accent in one tile to avoid generic look
    accent = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    adraw = ImageDraw.Draw(accent)
    x, y = tiles[1]
    adraw.rounded_rectangle((x + 68, y + 68, x + tile_w - 68, y + tile_h - 68), radius=40, fill=(76, 179, 255, 70))
    adraw.rounded_rectangle((x + 68, y + 68, x + tile_w - 68, y + tile_h - 68), radius=40, outline=(76, 179, 255, 120), width=4)
    img.alpha_composite(accent)

    # Final rounded app icon mask
    mask = Image.new("L", (SIZE, SIZE), 0)
    mdraw = ImageDraw.Draw(mask)
    mdraw.rounded_rectangle((32, 32, SIZE - 32, SIZE - 32), radius=230, fill=255)
    final = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    final.paste(img, (0, 0), mask)

    final.save(out_path)
    print(out_path)


if __name__ == "__main__":
    main()

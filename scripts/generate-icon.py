#!/usr/bin/env python3
"""Genera App/Assets.xcassets/AppIcon.appiconset/AppIcon.png (1024×1024) con Pillow."""
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

SIZE = 1024
SCALE = 4  # supermuestreo para suavizar bordes
S = SIZE * SCALE


def lerp(a, b, t):
    return tuple(round(x + (y - x) * t) for x, y in zip(a, b))


def main() -> None:
    top, bottom = (37, 52, 72), (17, 24, 36)
    background = Image.new("RGB", (S, S))
    draw = ImageDraw.Draw(background)
    for y in range(S):
        draw.line([(0, y), (S, y)], fill=lerp(top, bottom, y / S))

    # Sombra de la hoja
    shadow = Image.new("L", (S, S), 0)
    page_box = (S * 0.22, S * 0.15, S * 0.78, S * 0.85)
    ImageDraw.Draw(shadow).rounded_rectangle(
        (page_box[0] + S * 0.012, page_box[1] + S * 0.025, page_box[2] + S * 0.012, page_box[3] + S * 0.025),
        radius=S * 0.045, fill=150)
    shadow = shadow.filter(ImageFilter.GaussianBlur(S * 0.02))
    background.paste((5, 8, 14), mask=shadow)

    # Hoja con la esquina doblada
    paper = (251, 247, 238)
    fold = S * 0.12
    draw = ImageDraw.Draw(background)
    draw.rounded_rectangle(page_box, radius=S * 0.045, fill=paper)
    x1, y0 = page_box[2], page_box[1]
    draw.polygon([(x1 - fold, y0), (x1 + 2, y0), (x1 + 2, y0 + fold)], fill=lerp(top, bottom, 0.15))
    draw.polygon([(x1 - fold, y0), (x1 - fold, y0 + fold), (x1, y0 + fold)], fill=(222, 214, 196))

    # Líneas de texto y un resaltado
    left = page_box[0] + S * 0.07
    right = page_box[2] - S * 0.07
    line_h = S * 0.028
    ink = (58, 64, 74)
    rows = [(0.30, 0.62), (0.37, 1.0), (0.44, 0.92), (0.51, 1.0), (0.58, 0.97), (0.65, 0.88), (0.72, 0.6)]
    highlight_row = 3
    for index, (y, width) in enumerate(rows):
        y_px = S * y
        x_end = left + (right - left) * width
        if index == 0:
            x_end = min(x_end, page_box[2] - fold - S * 0.03)
        if index == highlight_row:
            draw.rounded_rectangle((left - S * 0.018, y_px - S * 0.024, x_end + S * 0.018, y_px + line_h + S * 0.024),
                                   radius=S * 0.012, fill=(255, 214, 74))
        draw.rounded_rectangle((left, y_px, x_end, y_px + line_h), radius=line_h / 2, fill=ink)

    icon = background.resize((SIZE, SIZE), Image.LANCZOS)
    out = Path(__file__).resolve().parent.parent / "App/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
    icon.save(out, optimize=True)
    print(f"Icono guardado en {out}")


if __name__ == "__main__":
    main()

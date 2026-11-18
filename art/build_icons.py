# /// script
# requires-python = ">=3.10"
# dependencies = ["cairosvg>=2.7", "pillow>=10.1"]
# ///
# SPDX-License-Identifier: GPL-3.0-or-later
"""Render art/icons/*.svg to the add-on's TGA textures.

The game wants power-of-two textures; uncompressed 32-bit TGA with alpha loads on Classic-era
clients. Each icon is rendered at 4x and downsampled, which keeps small glyphs crisp.

    uv run art/build_icons.py                      # writes addon/Plotline/Media/*.tga
    uv run art/build_icons.py --preview sheet.png  # also writes a preview sheet
"""
import argparse
import io
from pathlib import Path

import cairosvg
from PIL import Image, ImageDraw, ImageFont

HERE = Path(__file__).resolve().parent
SRC = HERE / "icons"
OUT = HERE.parent / "addon" / "Plotline" / "Media"

# name -> texture size in pixels (power of two)
ICONS = {
    "Plotline": 64, "Badge": 64,
    "TierFiller": 32, "TierChain": 32, "TierStory": 32, "TierLore": 32,
    "StepDone": 32, "StepCurrent": 32, "StepSide": 32, "StepBranch": 32,
    "TextCaptured": 32, "MapPin": 32,
}
OVERSAMPLE = 4


def render(name: str, size: int) -> Image.Image:
    png = cairosvg.svg2png(url=str(SRC / f"{name}.svg"),
                           output_width=size * OVERSAMPLE, output_height=size * OVERSAMPLE)
    big = Image.open(io.BytesIO(png)).convert("RGBA")
    return big.resize((size, size), Image.LANCZOS)


def preview(images: dict[str, Image.Image], path: Path) -> None:
    """Each icon at 4x, at in-game size (16 px for glyphs, 32 px for 64s), on dark and parchment."""
    cell, pad = 200, 16
    rows = [("#0d0d10", "#e8e8e8"), ("#e9d6a6", "#2a1a08")]
    w = pad + len(images) * cell
    sheet = Image.new("RGB", (w, len(rows) * 170 + pad), "#000")
    draw = ImageDraw.Draw(sheet)
    font = ImageFont.load_default(size=15)
    for r, (bg, fg) in enumerate(rows):
        y0 = pad // 2 + r * 170
        draw.rectangle([0, y0 - pad // 2, w, y0 + 170 - pad // 2], fill=bg)
        for i, (name, img) in enumerate(images.items()):
            x0 = pad + i * cell
            big = img.resize((128, 128), Image.LANCZOS) if img.width == 32 else img.resize((128, 128), Image.LANCZOS)
            sheet.paste(big, (x0, y0), big)
            small = 32 if img.width == 64 else 16
            s = img.resize((small, small), Image.LANCZOS)
            sheet.paste(s, (x0 + 140, y0 + 56), s)
            draw.text((x0, y0 + 134), name, fill=fg, font=font)
    sheet.save(path)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--preview", type=Path, help="also write a PNG preview sheet here")
    args = ap.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    images = {}
    for name, size in ICONS.items():
        img = render(name, size)
        img.save(OUT / f"{name}.tga", compression=None)
        images[name] = img
        print(f"{name}.tga  {size}x{size}")
    if args.preview:
        preview(images, args.preview)
        print(f"preview: {args.preview}")


if __name__ == "__main__":
    main()

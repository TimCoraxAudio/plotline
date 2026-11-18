# /// script
# requires-python = ">=3.10"
# dependencies = ["playwright>=1.45", "pillow>=10.1"]
# ///
# SPDX-License-Identifier: GPL-3.0-or-later
"""Render icon SVGs to the add-on's TGA textures, or compare design directions.

The SVGs use filters (bevel lighting, grain), so they're rendered in Chromium via Playwright.
If Playwright's own browser isn't installed, run `uv run --with playwright playwright install
chromium`, or point CHROMIUM_PATH at a Chromium/Chrome binary.

The game wants power-of-two textures; uncompressed 32-bit TGA with alpha loads on Classic-era
clients. Each icon is rendered at 4x and downsampled, which keeps small glyphs crisp.

    uv run art/build_icons.py                          # art/icons -> addon/Plotline/Media/*.tga
    uv run art/build_icons.py --preview sheet.png      # also a preview sheet of that set
    uv run art/build_icons.py --compare compare.png    # every set side by side, writes no TGAs

Sets: art/icons (shipped), art/directions/<name> (candidates). To adopt a candidate icon,
copy its SVG into art/icons and rebuild.
"""
import argparse
import base64
import io
import os
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont
from playwright.sync_api import sync_playwright

HERE = Path(__file__).resolve().parent
SHIPPED = HERE / "icons"
DIRECTIONS = HERE / "directions"
OUT = HERE.parent / "addon" / "Plotline" / "Media"

# name -> texture size in pixels (power of two)
ICONS = {
    "Plotline": 64, "Badge": 64,
    "TierFiller": 32, "TierChain": 32, "TierStory": 32, "TierLore": 32,
    "StepDone": 32, "StepCurrent": 32, "StepSide": 32, "StepBranch": 32,
    "TextCaptured": 32, "MapPin": 32,
}
OVERSAMPLE = 4


class Renderer:
    def __enter__(self):
        self.pw = sync_playwright().start()
        exe = os.environ.get("CHROMIUM_PATH")
        self.browser = self.pw.chromium.launch(**({"executable_path": exe} if exe else {}))
        self.page = self.browser.new_page()
        return self

    def __exit__(self, *exc):
        self.browser.close()
        self.pw.stop()

    def render(self, svg_path: Path, size: int) -> Image.Image:
        px = size * OVERSAMPLE
        data = base64.b64encode(svg_path.read_bytes()).decode()
        self.page.set_viewport_size({"width": px, "height": px})
        self.page.set_content(
            f'<html><body style="margin:0;background:transparent">'
            f'<img src="data:image/svg+xml;base64,{data}" width="{px}" height="{px}" style="display:block">'
            f'</body></html>')
        self.page.wait_for_load_state("load")
        png = self.page.screenshot(omit_background=True, clip={"x": 0, "y": 0, "width": px, "height": px})
        big = Image.open(io.BytesIO(png)).convert("RGBA")
        return big.resize((size, size), Image.LANCZOS)


def render_set(r: Renderer, folder: Path) -> dict[str, Image.Image]:
    return {n: r.render(folder / f"{n}.svg", s) for n, s in ICONS.items() if (folder / f"{n}.svg").exists()}


def sheet(sets: dict[str, dict[str, Image.Image]], path: Path) -> None:
    """One band per set: icons large on dark, then at in-game size on dark and on parchment."""
    cell, big, pad, label_w = 150, 112, 14, 130
    band = big + 2 * pad + 22
    w = label_w + len(ICONS) * cell
    font = ImageFont.load_default(size=14)
    title = ImageFont.load_default(size=18)
    img = Image.new("RGB", (w, 30 + len(sets) * band), "#0b0b0e")
    d = ImageDraw.Draw(img)
    for i, name in enumerate(ICONS):
        d.text((label_w + i * cell, 8), name, fill="#c8c8c8", font=font)
    for b, (set_name, icons) in enumerate(sets.items()):
        y0 = 30 + b * band
        d.rectangle([0, y0, w, y0 + band - 4], fill="#16161b" if b % 2 else "#101014")
        d.text((pad, y0 + band // 2 - 10), set_name, fill="#ffd100", font=title)
        for i, n in enumerate(ICONS):
            if n not in icons:
                continue
            x0 = label_w + i * cell
            ic = icons[n]
            L = ic.resize((big, big), Image.LANCZOS)
            img.paste(L, (x0, y0 + pad), L)
            small = 32 if ic.width == 64 else 16
            s = ic.resize((small, small), Image.LANCZOS)
            sx = x0 + big + 4
            d.rectangle([sx - 3, y0 + pad, sx + small + 3, y0 + pad + small + 6], fill="#0d0d10")
            img.paste(s, (sx, y0 + pad + 3), s)
            py = y0 + pad + small + 12
            d.rectangle([sx - 3, py, sx + small + 3, py + small + 6], fill="#e9d6a6")
            img.paste(s, (sx, py + 3), s)
    img.save(path)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--preview", type=Path, help="also write a preview sheet of the shipped set")
    ap.add_argument("--compare", type=Path, help="write a sheet comparing all sets; writes no TGAs")
    args = ap.parse_args()
    with Renderer() as r:
        if args.compare:
            sets = {"shipped": render_set(r, SHIPPED)}
            for d in sorted(p for p in DIRECTIONS.iterdir() if p.is_dir()):
                sets[d.name] = render_set(r, d)
            sheet(sets, args.compare)
            print(f"compare: {args.compare}")
            return
        OUT.mkdir(parents=True, exist_ok=True)
        images = render_set(r, SHIPPED)
        for name, img in images.items():
            img.save(OUT / f"{name}.tga", compression=None)
            print(f"{name}.tga  {img.width}x{img.height}")
        if args.preview:
            sheet({"shipped": images}, args.preview)
            print(f"preview: {args.preview}")


if __name__ == "__main__":
    main()

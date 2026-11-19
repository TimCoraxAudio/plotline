# /// script
# requires-python = ">=3.10"
# dependencies = ["pillow>=10.1", "pyyaml"]
# ///
"""Draw a wowless frame snapshot (frame0.yaml) as a PNG, text included.

wowless's own renderer (tools/sdlrender.lua) draws textures only. Our patch (sim/wowless.patch) makes it
save every texture it decodes and every font the text uses into a cache folder; this script composites
textures and text in the game's order: frame strata, frame level, then draw layer within a frame.

Approximate by design: no masks, no rotation (texture coordinates are treated as a rectangle), tiling and
inline icons are simplified, and text layout is Pillow's, not the game's. Good for judging layout.

  uv run sim/render.py out/dialog/frame0.yaml --cache out/dialog/cache -o out/dialog/dialog.png
  options: --crop name-or-x,y,w,h  --scale 2  --debug (outline every region, label Plotline's)
"""
import argparse
import os
import glob
import re
import sys
import xml.etree.ElementTree as ET

import yaml
from PIL import Image, ImageChops, ImageDraw, ImageFont

STRATA = {"WORLD": 1, "BACKGROUND": 2, "LOW": 3, "MEDIUM": 4, "HIGH": 5, "DIALOG": 6,
          "FULLSCREEN": 7, "FULLSCREEN_DIALOG": 8, "TOOLTIP": 9}
LAYERS = {"BACKGROUND": 1, "BORDER": 2, "ARTWORK": 3, "OVERLAY": 4, "HIGHLIGHT": 5}


def key(path):
    """Same file name the patched sdlrender.lua uses for a texture or font."""
    return re.sub(r"[^A-Za-z0-9]", "_", str(path))


def texture_key(path):
    if isinstance(path, (int, float)) or str(path).isdigit():
        return key(int(path)) + ".png"
    p = str(path).lower().replace("\\", "/")
    if not p.endswith(".blp"):
        p += ".blp"
    return key(p) + ".png"


class FontDB:
    """Blizzard's font objects (<Font> and <FontFamily> in the client's XML), so text that names only a
    font object (GameFontNormal...) gets its file, size, colour, shadow and outline."""

    def __init__(self, root):
        self.raw = {}
        if not root:
            return
        for f in glob.glob(os.path.join(root, "**", "*.xml"), recursive=True):
            try:
                tree = ET.parse(f)
            except ET.ParseError:
                continue
            for el in tree.iter():
                tag = el.tag.split("}")[-1]
                name = el.get("name")
                if not name or tag not in ("Font", "FontFamily"):
                    continue
                if tag == "FontFamily":  # take the roman member's font
                    for m in el.iter():
                        if m.tag.split("}")[-1] == "Member" and m.get("alphabet") == "roman":
                            inner = next((x for x in m if x.tag.split("}")[-1] == "Font"), None)
                            if inner is not None:
                                self.raw[name] = self.props(inner)
                else:
                    self.raw[name] = self.props(el)

    @staticmethod
    def props(el):
        p = {k: el.get(k) for k in ("font", "height", "outline", "justifyH", "justifyV", "inherits") if el.get(k)}
        for kid in el:
            t = kid.tag.split("}")[-1]
            if t == "Color":
                p["color"] = {"red": float(kid.get("r", 1)), "green": float(kid.get("g", 1)),
                              "blue": float(kid.get("b", 1)), "alpha": float(kid.get("a", 1))}
            elif t == "FontHeight":
                v = next((x.get("val") for x in kid.iter() if x.get("val")), None)
                if v:
                    p["height"] = v
            elif t == "Shadow":
                off = next((x for x in kid.iter() if x.tag.split("}")[-1] == "Offset"), None)
                col = next((x for x in kid.iter() if x.tag.split("}")[-1] == "Color"), None)
                p["shadow"] = {"x": float(off.get("x", 1)) if off is not None else 1,
                               "y": float(off.get("y", -1)) if off is not None else -1,
                               "red": float(col.get("r", 0)) if col is not None else 0,
                               "green": float(col.get("g", 0)) if col is not None else 0,
                               "blue": float(col.get("b", 0)) if col is not None else 0,
                               "alpha": float(col.get("a", 1)) if col is not None else 1}
        return p

    def resolve(self, name, depth=0):
        p = dict(self.raw.get(name) or {})
        if p.get("inherits") and depth < 10:
            base = self.resolve(p["inherits"], depth + 1)
            base.update({k: v for k, v in p.items() if k != "inherits"})
            p = base
        return p

    def fill(self, font):
        """font: the exported font table. Missing fields come from its font objects, nearest first."""
        merged = {}
        for name in reversed(font.get("objects") or []):
            merged.update(self.resolve(name))
        out = dict(font)
        if not out.get("path") and merged.get("font"):
            out["path"] = merged["font"]
        if not out.get("height") and merged.get("height"):
            out["height"] = float(merged["height"])
        if not out.get("flags") and merged.get("outline"):
            out["flags"] = "OUTLINE" if merged["outline"] != "NONE" else ""
        if not out.get("color") and merged.get("color"):
            out["color"] = merged["color"]
        if not (out.get("shadow") or {}).get("alpha") and merged.get("shadow"):
            out["shadow"] = merged["shadow"]
        for k in ("justifyH", "justifyV"):
            if not out.get(k) and merged.get(k):
                out[k] = merged[k]
        return out


class Renderer:
    def __init__(self, data, cache, scale, debug, fontdb=None):
        self.data, self.cache, self.s, self.debug = data, cache, scale, debug
        self.fontdb = fontdb or FontDB(None)
        self.W, self.H = data["screenWidth"], data["screenHeight"]
        self.img = Image.new("RGBA", (round(self.W * scale), round(self.H * scale)), (24, 24, 28, 255))
        self.textures, self.fonts, self.missing = {}, {}, set()
        self.boxes = []  # (name, box) for --debug and --crop

    # -- geometry: wowless rects are UI units from the bottom-left
    def box(self, rect):
        try:
            l, r, t, b = (float(rect[k]) for k in ("left", "right", "top", "bottom"))
        except (KeyError, TypeError, ValueError):
            return None
        if any(v != v or abs(v) > 1e6 for v in (l, r, t, b)):  # nan or inf
            return None
        s = self.s
        return (round(l * s), round((self.H - t) * s), round(r * s), round((self.H - b) * s))

    # -- textures
    def texture(self, path):
        k = texture_key(path)
        if k not in self.textures:
            f = os.path.join(self.cache, k)
            self.textures[k] = Image.open(f).convert("RGBA") if os.path.exists(f) else None
            if self.textures[k] is None:
                self.missing.add(str(path))
        return self.textures[k]

    def draw_texture(self, tex, box):
        x0, y0, x1, y1 = box
        w, h = x1 - x0, y1 - y0
        if w <= 0 or h <= 0 or w > 8000 or h > 8000:
            return
        alpha = tex.get("alpha", 1) or 0
        if alpha <= 0 or tex.get("drawLayer") == "HIGHLIGHT":
            return
        color = tex.get("color")
        if color:  # SetColorTexture
            layer = Image.new("RGBA", (w, h), tuple(round(255 * (color.get(c) or 0)) for c in ("red", "green", "blue"))
                              + (round(255 * (color.get("alpha", 1) or 0) * alpha),))
        else:
            path = tex.get("path")
            if not path or path == "FileData ID 0":
                return
            src = self.texture(path)
            if src is None:
                return
            c = tex.get("coords") or {}
            u0, v0 = c.get("tlx", 0), c.get("tly", 0)
            u1, v1 = c.get("brx", 1), c.get("bry", 1)
            flip_x, flip_y = u0 > u1, v0 > v1
            u0, u1 = sorted((u0, u1))
            v0, v1 = sorted((v0, v1))
            sw, sh = src.size
            if u1 > 1.001 or v1 > 1.001 or u0 < -0.001 or v0 < -0.001:  # tiled: repeat the image
                nx, ny = max(1, int(-(-u1 // 1)) - int(u0 // 1)), max(1, int(-(-v1 // 1)) - int(v0 // 1))
                if nx * sw > 8192 or ny * sh > 8192:
                    return
                tiled = Image.new("RGBA", (nx * sw, ny * sh))
                for i in range(nx):
                    for j in range(ny):
                        tiled.paste(src, (i * sw, j * sh))
                src, ox, oy = tiled, int(u0 // 1), int(v0 // 1)
                u0, u1, v0, v1 = u0 - ox, u1 - ox, v0 - oy, v1 - oy
            cx0, cy0 = round(u0 * sw), round(v0 * sh)
            cx1, cy1 = max(cx0 + 1, round(u1 * sw)), max(cy0 + 1, round(v1 * sh))
            layer = src.crop((cx0, cy0, cx1, cy1)).resize((w, h), Image.BILINEAR)
            if flip_x:
                layer = layer.transpose(Image.FLIP_LEFT_RIGHT)
            if flip_y:
                layer = layer.transpose(Image.FLIP_TOP_BOTTOM)
            vc = tex.get("vertexColor")
            if vc:
                tint = Image.new("RGBA", layer.size, tuple(round(255 * (vc.get(k) if vc.get(k) is not None else 1))
                                                           for k in ("red", "green", "blue")) + (255,))
                layer = ImageChops.multiply(layer, tint)
            if alpha < 1:
                a = layer.getchannel("A").point(lambda p: round(p * alpha))
                layer.putalpha(a)
        if tex.get("blendMode") == "ADD":
            base = self.img.crop((x0, y0, x1, y1))
            rgb = layer.convert("RGB")
            a = layer.getchannel("A")
            added = ImageChops.add(base.convert("RGB"), ImageChops.multiply(rgb, Image.merge("RGB", (a, a, a))))
            self.img.paste(added.convert("RGBA"), (x0, y0))
        else:
            self.img.alpha_composite(layer, (x0, y0)) if x0 >= 0 and y0 >= 0 else self._composite_clipped(layer, x0, y0)

    def _composite_clipped(self, layer, x0, y0):
        cx, cy = max(0, -x0), max(0, -y0)
        if cx >= layer.width or cy >= layer.height:
            return
        self.img.alpha_composite(layer.crop((cx, cy, layer.width, layer.height)), (max(0, x0), max(0, y0)))

    # -- text
    def font(self, font):
        path = (font.get("path") or "").lower().replace("\\", "/")
        size = max(6, round((font.get("height") or 12) * self.s))
        k = (path, size)
        if k not in self.fonts:
            f = os.path.join(self.cache, key(path or "fonts/frizqt__.ttf") + ".font")
            try:
                self.fonts[k] = ImageFont.truetype(f, size) if os.path.exists(f) else None
            except OSError:
                self.fonts[k] = None
            if self.fonts[k] is None:
                self.missing.add(path or "(no font)")
                self.fonts[k] = ImageFont.load_default(size)
        return self.fonts[k]

    @staticmethod
    def runs(text, base):
        """Split WoW markup into (text, rgba) runs. |c colours, |r resets; links keep their text;
        inline textures/atlases become a box marker; |n is a newline."""
        text = text.replace("|n", "\n").replace("||", "\x00")
        text = re.sub(r"\|H.*?\|h(.*?)\|h", r"\1", text)
        text = re.sub(r"\|T.*?\|t|\|A.*?\|a", "■", text)
        out, color = [], base
        for part in re.split(r"(\|c[0-9a-fA-F]{8}|\|r)", text):
            if part.startswith("|c") and len(part) == 10:
                h = part[2:]
                color = (int(h[2:4], 16), int(h[4:6], 16), int(h[6:8], 16), int(h[0:2], 16))
            elif part == "|r":
                color = base
            elif part:
                out.append((part.replace("\x00", "|"), color))
        return out

    def layout(self, runs, font, width):
        """Greedy word wrap. Returns lines, each a list of (text, color)."""
        lines, line, lw = [], [], 0
        space = font.getlength(" ")
        for text, color in runs:
            for i, para in enumerate(text.split("\n")):
                if i:
                    lines.append(line)
                    line, lw = [], 0
                for word in re.split(r"(\s+)", para):
                    if not word:
                        continue
                    ww = font.getlength(word)
                    if width and lw + ww > width and line and not word.isspace():
                        lines.append(line)
                        line, lw = [], 0
                    if word.isspace() and not line:
                        continue
                    line.append((word if not word.isspace() else " ", color))
                    lw += ww if not word.isspace() else space
        lines.append(line)
        return lines

    def draw_text(self, string, font, box):
        if isinstance(string, bool):  # YAML 1.1 reads a label like "No" or "On" as a boolean
            string = "Yes" if string else "No"
        elif string is not None and not isinstance(string, str):
            string = str(string)
        if not string:
            return
        font = self.fontdb.fill(font or {})
        c = font.get("color") or {}
        base = tuple(round(255 * (c.get(k) if c.get(k) is not None else 1)) for k in ("red", "green", "blue", "alpha"))
        f = self.font(font)
        x0, y0, x1, y1 = box
        width = x1 - x0 if font.get("wrap", True) and x1 - x0 > 4 else 0
        lines = self.layout(self.runs(string, base), f, width)
        asc, desc = f.getmetrics()
        lh = asc + desc + round((font.get("spacing") or 0) * self.s)
        total = lh * len(lines)
        jv = font.get("justifyV") or "MIDDLE"
        if y1 - y0 <= 1:
            y = y0 - (total // 2 if jv == "MIDDLE" else 0)
        elif jv == "TOP":
            y = y0
        elif jv == "BOTTOM":
            y = y1 - total
        else:
            y = y0 + (y1 - y0 - total) // 2
        jh = font.get("justifyH") or "CENTER"
        d = ImageDraw.Draw(self.img)
        sh = font.get("shadow") or {}
        flags = (font.get("flags") or "").upper()
        stroke = max(1, round(self.s)) if "OUTLINE" in flags else 0
        for line in lines:
            lw = sum(f.getlength(t) for t, _ in line)
            if x1 - x0 <= 1:
                x = x0 - lw / 2 if jh == "CENTER" else x0 - lw if jh == "RIGHT" else x0
            else:
                x = x0 if jh == "LEFT" else x1 - lw if jh == "RIGHT" else x0 + (x1 - x0 - lw) / 2
            for t, col in line:
                if (sh.get("x") or sh.get("y")) and (sh.get("alpha") or 0) > 0:
                    sc = tuple(round(255 * (sh.get(k) or 0)) for k in ("red", "green", "blue")) + (round(255 * sh["alpha"]),)
                    d.text((x + sh["x"] * self.s, y - sh["y"] * self.s), t, font=f, fill=sc)
                d.text((x, y), t, font=f, fill=col, stroke_width=stroke, stroke_fill=(0, 0, 0, 255))
                x += f.getlength(t)
            y += lh

    # -- tooltips: recorded by PlotlineSim (wowless can't lay them out), drawn here as a tooltip box
    def draw_tooltips(self, log):
        tips = {}
        for m in re.finditer(r"PlotlineSim: tip (\d+) anchor=(\S+) point=(\S+) relpoint=(\S+) x=(\S+) y=(\S+) "
                             r"rel=(\S+),(\S+),(\S+),(\S+) name=(\S+)", log):
            n = int(m.group(1))
            num = lambda v: float(v) if re.fullmatch(r"-?[\d.]+(e-?\d+)?", v) else None
            tips[n] = {"anchor": m.group(2), "point": m.group(3), "relpoint": m.group(4),
                       "x": num(m.group(5)) or 0, "y": num(m.group(6)) or 0,
                       "rel": tuple(num(m.group(i)) for i in range(7, 11)), "lines": {}}
        for m in re.finditer(r"PlotlineSim: tipline (\d+) (\d+) (\S+) (\S+) (\S+) (\S+)\|(.*)", log):
            t = tips.get(int(m.group(1)))
            if t is not None:
                c = tuple(float(v) if v != "nil" else None for v in m.group(3, 4, 5))
                t["lines"][int(m.group(2))] = {"color": c, "wrap": m.group(6) == "wrap", "text": m.group(7)}
        for t in tips.values():
            self.draw_tooltip(t)
        return len(tips)

    def draw_tooltip(self, t):
        s = self.s
        rows = [t["lines"][i] for i in sorted(t["lines"])]
        if not rows:
            return
        fonts = [self.fontdb.fill({"objects": ["GameTooltipHeaderText" if i == 0 else "GameTooltipText"]})
                 for i in range(len(rows))]
        pfonts = [self.font(f) for f in fonts]
        pad, gap = round(10 * s), round(2 * s)
        nowrap = [pf.getlength(re.sub(r"\|c\w{8}|\|r|\|T.*?\|t|\|A.*?\|a", "  ", r["text"].replace("\t", "    ")))
                  for r, pf in zip(rows, pfonts) if not r["wrap"]]
        inner = max(nowrap + [round(150 * s)]) if nowrap else round(250 * s)
        inner = min(inner, round(420 * s))
        laid = []
        for i, (r, f, pf) in enumerate(zip(rows, fonts, pfonts)):
            c = r["color"]
            default = (1, 1, 1) if i == 0 else (1, 0.82, 0)
            rgb = tuple(round(255 * (v if v is not None else d)) for v, d in zip(c, default)) + (255,)
            left, _, right = r["text"].partition("\t")
            lines = self.layout(self.runs(left, rgb), pf, inner if r["wrap"] else 0)
            asc, desc = pf.getmetrics()
            laid.append((lines, right, rgb, pf, asc + desc))
        h = sum(len(l) * lh for l, _, _, _, lh in laid) + gap * (len(laid) - 1) + 2 * pad
        w = inner + 2 * pad
        # where it hangs, in pixels from the top-left
        rl, rb, rw, rh = t["rel"]
        if rl is None:
            x0, y0 = round(self.W * s / 2 - w / 2), round(self.H * s / 2 - h / 2)
        else:
            L, R = rl * s, (rl + rw) * s
            T, B = (self.H - (rb + rh)) * s, (self.H - rb) * s
            def at(p):
                p = p or "CENTER"
                x = L if "LEFT" in p else R if "RIGHT" in p else (L + R) / 2
                y = T if "TOP" in p else B if "BOTTOM" in p else (T + B) / 2
                return x, y
            if t["anchor"] == "POINT":
                ax, ay = at(t["relpoint"])
                p = t["point"]
            else:
                rel_for = {"ANCHOR_RIGHT": ("TOPRIGHT", "BOTTOMLEFT"), "ANCHOR_LEFT": ("TOPLEFT", "BOTTOMRIGHT"),
                           "ANCHOR_TOP": ("TOP", "BOTTOM"), "ANCHOR_BOTTOM": ("BOTTOM", "TOP"),
                           "ANCHOR_TOPLEFT": ("TOPLEFT", "BOTTOMLEFT"), "ANCHOR_TOPRIGHT": ("TOPRIGHT", "BOTTOMRIGHT"),
                           "ANCHOR_BOTTOMLEFT": ("BOTTOMLEFT", "TOPRIGHT"),
                           "ANCHOR_BOTTOMRIGHT": ("BOTTOMRIGHT", "TOPLEFT")}.get(t["anchor"], ("CENTER", "CENTER"))
                ax, ay = at(rel_for[0])
                p = rel_for[1]
            ax, ay = ax + t["x"] * s, ay - t["y"] * s
            x0 = ax if "LEFT" in p else ax - w if "RIGHT" in p else ax - w / 2
            y0 = ay if "TOP" in p else ay - h if "BOTTOM" in p else ay - h / 2
            x0, y0 = round(x0), round(y0)
        d = ImageDraw.Draw(self.img)
        d.rounded_rectangle((x0, y0, x0 + w, y0 + h), radius=round(4 * s), fill=(8, 8, 12, 235),
                            outline=(120, 120, 130, 255), width=max(1, round(s)))
        y = y0 + pad
        for lines, right, rgb, pf, lh in laid:
            for line in lines:
                x = x0 + pad
                for text, col in line:
                    d.text((x + s, y + s), text, font=pf, fill=(0, 0, 0, 255))
                    d.text((x, y), text, font=pf, fill=col)
                    x += pf.getlength(text)
                y += lh
            if right:
                d.text((x0 + w - pad - pf.getlength(right), y - lh), right, font=pf, fill=rgb)
            y += gap
        self.boxes.append(("tooltip", (x0, y0, x0 + w, y0 + h)))

    # -- everything
    def render(self):
        frames = sorted(self.data["frames"], key=lambda f: (STRATA.get(f.get("strata"), 0), f.get("strataLevel") or 0))
        for fr in frames:
            def order(r):
                c = r["content"]
                t = c.get("texture") or c.get("font") or {}
                return (LAYERS.get(t.get("drawLayer"), 3), t.get("drawSubLayer") or 0)
            for r in sorted(fr["regions"], key=order):
                b = self.box(r.get("rect"))
                if not b:
                    continue
                c = r["content"]
                name = r.get("name") or fr.get("name") or ""
                self.boxes.append((name, b))
                if c.get("texture"):
                    self.draw_texture(c["texture"], b)
                elif c.get("string") is not None:
                    self.draw_text(c["string"], c.get("font") or {}, b)
        if self.debug:
            d = ImageDraw.Draw(self.img)
            for name, (x0, y0, x1, y1) in self.boxes:
                if "Plotline" in name:
                    d.rectangle((x0, y0, max(x0, x1 - 1), max(y0, y1 - 1)), outline=(255, 0, 255, 255))
        return self.img

    def crop(self, spec):
        if re.fullmatch(r"\d+,\d+,\d+,\d+", spec):
            x, y, w, h = (int(v) for v in spec.split(","))
            return self.img.crop((x, y, x + w, y + h))
        hits = [b for n, b in self.boxes if spec in n]
        if not hits:
            print(f"crop: nothing named like {spec!r}", file=sys.stderr)
            return self.img
        pad = round(24 * self.s)
        x0 = max(0, min(b[0] for b in hits) - pad)
        y0 = max(0, min(b[1] for b in hits) - pad)
        x1 = min(self.img.width, max(b[2] for b in hits) + pad)
        y1 = min(self.img.height, max(b[3] for b in hits) + pad)
        return self.img.crop((x0, y0, x1, y1))


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("yaml")
    p.add_argument("--cache", required=True, help="textures and fonts saved by the patched sdlrender")
    p.add_argument("-o", "--output", required=True)
    p.add_argument("--scale", type=float, default=1.0)
    p.add_argument("--crop", action="append", default=[],
                   help="also write <output>-<n>.png cropped to frames whose name contains this, or x,y,w,h")
    p.add_argument("--debug", action="store_true")
    p.add_argument("--log", action="append", default=[],
                   help="wowless log(s) with PlotlineSim tooltip notes, drawn on top")
    p.add_argument("--fonts-xml", help="folder with the client's UI XML (wowless build/extracts/<product>)")
    a = p.parse_args()
    with open(a.yaml, encoding="utf-8") as f:
        data = yaml.load(f, Loader=getattr(yaml, "CSafeLoader", yaml.SafeLoader))
    fdb = FontDB(a.fonts_xml)
    print(f"{len(fdb.raw)} font objects from the client's XML")
    r = Renderer(data, a.cache, a.scale, a.debug, fdb)
    img = r.render()
    log = "".join(open(f, encoding="utf-8", errors="replace").read() for f in a.log if os.path.exists(f))
    if log:
        print(f"{r.draw_tooltips(log)} tooltip(s) from the log")
    img.convert("RGB").save(a.output)
    print(f"Wrote {a.output} ({img.width}x{img.height}, {len(r.boxes)} regions)")
    base, ext = os.path.splitext(a.output)
    for i, spec in enumerate(a.crop, 1):
        out = f"{base}-{re.sub(r'[^A-Za-z0-9]+', '_', spec)}{ext}"
        r.crop(spec).convert("RGB").save(out)
        print(f"Wrote {out}")
    if r.missing:
        print(f"Missing from cache ({len(r.missing)}): " + ", ".join(sorted(r.missing)[:20]))


if __name__ == "__main__":
    main()

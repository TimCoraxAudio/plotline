# /// script
# requires-python = ">=3.10"
# dependencies = ["pyyaml"]
# ///
"""Text report of a wowless scene: Plotline's frames (where, how big, what they say), the Blizzard frames
they sit on, and Lua errors from our code. For reading a run without opening the PNGs.

  uv run sim/report.py sim/out/dialog
"""
import glob
import os
import re
import sys

import yaml

WATCH = ("Plotline", "QuestFrame", "GameTooltip", "QuestInfoTitleHeader")


def main():
    d = sys.argv[1]
    scene = os.path.basename(os.path.normpath(d))
    print(f"=== {scene}")
    log = ""
    for name in ("log.txt", "stdout.txt"):
        p = os.path.join(d, name)
        if os.path.exists(p):
            log += open(p, encoding="utf-8", errors="replace").read()
    errors = re.findall(r"error: (.*)", log)
    notes = [e for e in errors if e.startswith("PlotlineSim: ")]
    ours = [e for e in errors if e not in notes and re.search(r"Plotline", e)]
    print(f"Lua errors: {len(errors) - len(notes)} total, {len(ours)} mentioning Plotline")
    for e in dict.fromkeys(ours):
        print("  ERR", e[:400])
    for e in notes:
        print("  ", e[:400])
    # Source context for errors in the client's own UI code that our scenes hit.
    src = sys.argv[2] if len(sys.argv) > 2 else None
    if src:
        for path, line in dict.fromkeys(re.findall(r"\.\.\.(AddOns\\[^:]+\.lua):(\d+): ", "\n".join(notes))):
            rel = path.replace("\\", "/")
            hits = glob.glob(os.path.join(src, "**", rel), recursive=True)
            if not hits:
                print(f"  (source {rel} not found)")
                continue
            lines = open(hits[0], encoding="utf-8", errors="replace").read().splitlines()
            n = int(line)
            print(f"  source {rel}:{n}")
            for i in range(max(1, n - 12), min(len(lines), n + 3) + 1):
                print(f"   {'>' if i == n else ' '}{i:5} {lines[i - 1][:160]}")
    p = os.path.join(d, "render_py.txt")
    if os.path.exists(p):
        for line in open(p, encoding="utf-8", errors="replace").read().splitlines()[-12:]:
            print("  render.py:", line[:300])
    p = os.path.join(d, "frame0.yaml")
    if not os.path.exists(p):
        print("no frame0.yaml")
        return
    data = yaml.load(open(p, encoding="utf-8"), Loader=getattr(yaml, "CSafeLoader", yaml.SafeLoader))
    H = data["screenHeight"]
    print(f"screen {data['screenWidth']}x{H} (UI units; y from the top below)")
    watch = WATCH + tuple(re.findall(r"PlotlineSim: watch (\S+)", log))
    for fr in data["frames"]:
        fname = fr.get("name") or ""
        if re.search(r"NineSlice|FriendshipStatusBar", fname):
            continue
        regs = [r for r in fr["regions"] if any(w in (r.get("name") or fname) for w in watch)]
        if not regs:
            continue
        print(f"- {fname} [{fr.get('strata')} {fr.get('strataLevel')}]")
        for r in regs[:40]:
            rc = r.get("rect") or {}
            try:
                pos = f"x {rc['left']:.0f}-{rc['right']:.0f} y {H - rc['top']:.0f}-{H - rc['bottom']:.0f}"
            except (KeyError, TypeError):
                pos = "no rect"
            c = r["content"]
            what = ""
            if c.get("string") is not None:
                f = c.get("font") or {}
                what = f"text {str(c['string'])[:90]!r} ({f.get('height')}px {f.get('justifyH')})"
            elif c.get("texture"):
                t = c["texture"]
                what = f"texture {t.get('path') or ('color' if t.get('color') else '?')}"
            print(f"    {(r.get('name') or '')[-60:]:60} {pos:28} {what}")


if __name__ == "__main__":
    main()

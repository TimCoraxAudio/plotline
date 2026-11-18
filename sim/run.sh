#!/bin/bash
# Render Plotline scenes with wowless (a headless WoW client). Used by .github/workflows/screens.yml.
# Usage: sim/run.sh <wowless checkout, built> <out dir> [--real-text] scene...
# Needs addon/Plotline/Data/Chains.lua (uv run pipeline/build_addon_data.py).
set -uo pipefail
WOWLESS=$(realpath "$1"); OUT=$(realpath -m "$2"); shift 2
REAL=""
if [ "${1:-}" = "--real-text" ]; then REAL="--real-text"; shift; fi
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
mkdir -p "$OUT"

# A copy of Plotline with one extra file that exposes its namespace to PlotlineSim.
cp -r "$ROOT/addon/Plotline" "$WORK/Plotline"
printf 'local _, ns = ...\nPlotlineDevNS = ns\n' > "$WORK/Plotline/DevNS.lua"
printf '\nDevNS.lua\n' >> "$WORK/Plotline/Plotline.toc"
cp -r "$ROOT/sim/PlotlineSim" "$WORK/PlotlineSim"

status=0
for scene in "$@"; do
  echo "::group::scene $scene"
  mkdir -p "$OUT/$scene/cache"
  uv run "$ROOT/sim/make_scene.py" "$scene" $REAL --out "$WORK/PlotlineSim/Generated.lua"
  (cd "$WOWLESS" && timeout 600 build/wowless_wowf run -p wowf --frame0 \
      -a build/products/wowf/WowlessData -a "$WORK/Plotline" -a "$WORK/PlotlineSim" \
      -o "$OUT/$scene/log.txt") > "$OUT/$scene/stdout.txt" 2>&1
  echo "wowless exit $?"
  if [ -f "$OUT/$scene/frame0.yaml" ]; then
    (cd "$WOWLESS/build" && timeout 600 ./render "$OUT/$scene/frame0.yaml" -o "$OUT/$scene/textures.png" --dump "$OUT/$scene/cache") \
      > "$OUT/$scene/render.txt" 2>&1 || echo "texture render failed"
    echo "textures wowless couldn't decode: $(grep -c womp "$OUT/$scene/render.txt")"
    uv run "$ROOT/sim/render.py" "$OUT/$scene/frame0.yaml" --cache "$OUT/$scene/cache" -o "$OUT/$scene/$scene.png" \
      --fonts-xml "$WOWLESS/build/extracts/wowf" > "$OUT/$scene/render_py.txt" 2>&1 \
      || { echo "render.py failed"; status=1; }
  else
    echo "no frame0.yaml for $scene"; status=1
  fi
  uv run "$ROOT/sim/report.py" "$OUT/$scene" | tee "$OUT/$scene/report.txt"
  echo "::endgroup::"
done
echo "=== all reports"
cat "$OUT"/*/report.txt
rm -rf "$WORK"
exit $status

# Screenshots without the game

`sim/` runs Plotline inside [wowless](https://github.com/wowless/wowless), a headless WoW client that
evaluates Blizzard's real UI code. wowless has a WoW Forever product (`wowf`, interface 16001), so our
frames are laid out against the same FrameXML the game uses. The output is a PNG per scene.

It runs in GitHub Actions (`.github/workflows/screens.yml`), on every push that touches `addon/` or
`sim/`, or by hand ("Run workflow", where you pick scenes and placeholder or real text). Download the
`screens` artifact from the run. wowless needs Blizzard's download servers to fetch the client's UI
code and textures, so it can't run in a sandbox that blocks them.

## What's in a run

For each scene, `sim/out/<scene>/`:
- `<scene>.png`: the render, textures and text (`sim/render.py`).
- `textures.png`: wowless's own render, textures only. Useful to tell a renderer bug from a layout bug.
- `frame0.yaml`: every visible region with its rectangle, texture and text. The ground truth.
- `stdout.txt`, `log.txt`: wowless output, including `PlotlineSim:` lines and Lua errors.
- `report.txt`: the same scene as text: Plotline's frames (position, size, text), harness notes, Lua
  errors from our code, and source context for errors in Blizzard's UI code. The job log prints every
  report at the end, so a run can be read without downloading anything.

## Pieces

| File | What |
|---|---|
| `PlotlineSim/` | Dev-only add-on: fakes the player (Alliance Human Warrior, level 14), completed quests, the quest log and the quest dialog, then opens one scene. Scenes are in `Sim.lua`. |
| `make_scene.py` | Writes `PlotlineSim/Generated.lua` (git-ignored): the scene, and titles/text. Placeholders by default; `--real-text` takes Blizzard's from EG Link. |
| `run.sh` | Runs wowless and the renderers for each scene. Adds a `DevNS.lua` to a copy of Plotline so the sim can reach its namespace; the real add-on is untouched. |
| `render.py` | Composites textures and text in the game's draw order. `--crop <frame name>`, `--scale 2`, `--debug`. |
| `report.py` | Writes `report.txt` (see above). |
| `wowless.patch` | Our changes to wowless (pinned in the workflow): export text's font objects; resolve `SetPoint(point, x, y)` against the parent, as the game does; run ten frames of timers before the snapshot; save decoded textures and fonts for `render.py`. |

## Limits

- Approximate: no masks, rotation, animation or models; text is laid out by Pillow, not the game.
  Trust it for layout (positions, sizes, overlap, what's shown), not for final polish.
- wowless doesn't measure text, so anything sized to its text is off: tooltips most of all. Their
  content is recorded by PlotlineSim (`SetOwner`/`AddLine`) and `render.py` draws the box itself, so
  the steps tooltip and quest card show real content in an approximate box.
- wowless doesn't track `SetFont`; fonts come from each text's font object, looked up in Blizzard's
  font XML. Text given a font only by `SetFont` falls back to Friz Quadrata at 12.
- Some textures don't decode in wowless (its log says `womp`); they're simply missing from the PNG.
- wowless is pre-alpha. A Lua error in its log may be wowless's, not ours.
- Fake state only covers what the scenes need. Add to `Sim.lua` when a scene needs more.
- Never commit `sim/out/` or `Generated.lua` (Blizzard art and, with `--real-text`, text). See
  `docs/LICENSING.md`.

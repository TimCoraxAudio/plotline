# Plotline

A lore-aware quest companion for **WoW Forever**. It tells meaningful quests apart from filler
and keeps track of the story you've played.

> Status: early. The offline data pipeline is partly done, and the add-on is a skeleton.

## What it'll do

- Show whether a quest is part of a chain, which chain, and where you are in it ("3 of 7").
- Put every quest in a tier: **Filler**, **Chain**, **Story** or **Lore**.
- Give each chain a short teaser that never spoils it. It sets up a question and never
  reveals an outcome.
- Keep a **Journal** of your chains, a timeline, the quest text you saw and your own notes,
  with an optional "Previously…" recap.
- Look as if it shipped with the game.

## Repository layout

```
addon/Plotline/   the WoW add-on (copy into Interface/AddOns/)
pipeline/         offline Python tools that build the add-on's data
docs/             design notes and licensing
```

## Pipeline

Needs [uv](https://docs.astral.sh/uv/). Each script declares its own dependencies, so there's
nothing to install first.

```bash
git submodule update --init --depth 1
uv run pipeline/merge_chains.py      # merge + split -> pipeline/out/chains.json, report.md
uv run pipeline/chain_viewer.py      # browse chains and check links in your browser
uv run pipeline/analyze_chains.py    # breakdown of the largest merged groups
uv run pipeline/build_addon_data.py  # chain data for the add-on -> addon/Plotline/Data/Chains.lua
uv run pipeline/build_places.py      # area backgrounds -> addon/Plotline/Data/Places.lua (committed)
```

The add-on needs `Data/Chains.lua` to show anything. It's generated locally and not committed
yet (see `docs/LICENSING.md`), so run `build_addon_data.py` before loading the add-on.
For development, `--dev-text` also writes quest text for the quest card (`Data/DevQuestText.lua`).
It's Blizzard's text, for your own machine only: never commit or ship it.

The chain viewer runs a small local web server (127.0.0.1 only) and opens it in your browser.
Search by chain or quest name or ID, or filter by zone. Each chain shows as numbered steps,
with a card per quest: level, faction, classes, zone, its text, and every link in or out, with
the sources behind it and whether the splitter kept it.

The source data comes in as shallow git submodules under `pipeline/sources/`. This repository
only records which commit of each one it uses; their contents aren't published here. Output
goes to `pipeline/out/`, which is git-ignored because it holds game text and derived data.
To pull newer source data: `git submodule update --remote --depth 1`.

## Requirements

None. Plotline ships its own chain data, built offline.

## Licensing

Code: GPL-3.0-or-later ([`LICENSE`](LICENSE)). Game text and art belong to Blizzard and are
never included. The area backgrounds in `addon/Plotline/Data/Places.lua` are
[CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/) (see Credits). See [`docs/LICENSING.md`](docs/LICENSING.md) for the full rules and the
status of each source.

## Credits

- Quest data from [Efficient Games](https://efficient.games), licensed under
  [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). Plotline reorganises it into quest chains.
- Chain structure cross-checked against [QuestieDB](https://github.com/Questie/QuestieDB) by the Questie team.
- Pipeline reference data: [Spoken](https://github.com/rusty-key/spoken-wow) by Rusty Key.
- Area backgrounds: text from [Warcraft Wiki](https://warcraft.wiki.gg) contributors, licensed under
  [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/), as adapted by Spoken. Each entry
  names its wiki page; Plotline only re-keys it.

Plotline is a fan work. It isn't affiliated with or endorsed by Blizzard Entertainment.

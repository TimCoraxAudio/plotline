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

```bash
pip install -r pipeline/requirements.txt
mkdir -p pipeline/sources
git clone --depth 1 https://github.com/Questie/QuestieDB.git pipeline/sources/QuestieDB
git clone --depth 1 https://github.com/rusty-key/spoken-wow.git pipeline/sources/spoken-wow
python3 pipeline/merge_chains.py --questiedb pipeline/sources/QuestieDB \
    --spoken pipeline/sources/spoken-wow --out pipeline/out
```

`pipeline/sources/` and `pipeline/out/` are git-ignored. They hold third-party data and
game text that this repository mustn't publish.

## Requirements (planned)

- [QuestieDB](https://github.com/Questie/QuestieDB), installed separately, for chain structure.

## Licensing

Code: GPL-3.0-or-later ([`LICENSE`](LICENSE)). Game text and art belong to Blizzard and are
never included. See [`docs/LICENSING.md`](docs/LICENSING.md) for the full rules and the
status of each source.

## Credits

- Chain structure: [QuestieDB](https://github.com/Questie/QuestieDB) by the Questie team.
- Pipeline reference data: [Spoken](https://github.com/rusty-key/spoken-wow) by Rusty Key.

Plotline is a fan work. It isn't affiliated with or endorsed by Blizzard Entertainment.

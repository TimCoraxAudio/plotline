# How Plotline's data is layered

Plotline's data comes in layers. Each layer has one owner, one licence position and one place it
lives, and a lookup reads them in a fixed order. When you add data, decide its layer first using
"Where new data goes" below. The licence rules behind this are in [`LICENSING.md`](LICENSING.md).

## The layers

| # | Layer | Where | What it holds | Whose / licence | In git? | Shipped? |
|---|---|---|---|---|---|---|
| 0 | **Sources** | `pipeline/sources/*` (shallow submodules) | QuestieDB, Spoken, EG Link output | Theirs | Pointer only | Never |
| 1 | **Pipeline output** | `pipeline/out/` | `chains.json`, `report.md`, `breakdown.md` | Derived; holds titles | No (ignored) | Never |
| 2 | **Core data** | `addon/Plotline/Data/Chains.lua` | Chains as quest IDs (steps, side quests, turn-ins, branches); per quest: faction/race/class rules, retired (`gone`), dungeon/raid, giver/ender IDs, level, min level, area ID, rewards (money, item IDs, faction IDs) | EG Link facts (CC BY 4.0) reorganised by us; cross-checked against QuestieDB | No, until the QuestieDB checklist in `LICENSING.md` is done | Yes, in `Plotline` |
| 3 | **Overlay** (planned) | e.g. `addon/Plotline/Data/Meaning.lua` | Our tiers, teasers, tags, per-quest overrides | Ours, GPL-3.0 | Yes (hand-edited) | Yes, in `Plotline` |
| 4 | **Quest text pack** | `addon/Plotline_QuestText/QuestText.lua` | Per quest: title `t`, description `d`, objectives `o`, progress `p`, completion `c`, female forms `pF`/`cF` | **© Blizzard.** EG Link's compilation is CC BY 4.0; Spoken fills gaps | **Never.** Only its `.toc` and `NOTICE.md` are committed | Yes, as the separate add-on `Plotline_QuestText` |
| 5 | **The game, at runtime** | API calls | Quest titles, NPC and object names, map and area names, item links, faction names | Blizzard's; the client already has them | n/a | Never shipped by us |
| 6 | **The player's saved data** | `PlotlineCharDB` (SavedVariables) | Captured text (`text[q] = {d, o, p, c}`), timeline (`log`), Compendium (`known`), notes, seen chains | The player's own machine | n/a | Never leaves their machine |

Layers 2 to 4 are generated or hand-edited offline. 5 and 6 exist only in the player's game.

## Lookup order in the add-on

- **Quest text** (`Record.lua` `R.Text`), field by field: captured in game (6), then the pack (4),
  then nothing. The source is reported as `"captured"` if any field was captured, else
  `"Plotline Quest Text"`, and the UI notes "not captured in game" in that case.
- **Titles** (`Chains.lua` `C.Title`): the game (5). Until the game answers (it never does for
  retired quests), the pack's `t`, but only if the pack is already loaded. Titles never load it.
- **Facts** (level, area, rewards, givers, rules): core data (2) only. Names for their IDs come
  from the game (5) or the Compendium (6).
- **Spoiler rules apply on top of every layer:** completion text only for quests the character has
  done, and chains they haven't started stay hidden. The pack holds text for every quest, so this
  is now enforced in the UI only.

## The quest text pack (layer 4)

- **Add-on:** `Plotline_QuestText`, `## LoadOnDemand: 1`, `## Dependencies: Plotline`.
  `Text.lua` loads it with `C_AddOns.LoadAddOn` the first time a text is asked for
  (`ns.text.Get`), and only on `enUS`/`enGB` clients. Without it, Plotline shows only captured text.
  `/plotline` reports whether it's loaded.
- **Data:** a global table `PlotlineQuestText = { built, locale, quests = {[id] = {...}} }`. It
  has to be global because a data add-on can't reach Plotline's private namespace.
- **Built by** `uv run pipeline/build_quest_text.py`, for every quest the merge knows (5,997 of
  6,082 have text on 2026-11-19; 3.8 MB). It reads the submodules directly and doesn't need the
  splitter.
- **Source order per field** (first wins; the script's docstring is the reference):
  title: EG quests, then merge name. Description: EG quests `description`, then EG texts `accept`,
  then Spoken. Objectives: EG quests, then EG texts. Progress: EG texts only. Completion: EG quests
  `completionText`, then EG texts `complete`, then Spoken.
- **Placeholders:** EG's quest records and templated texts keep the game's `$N $C $R $g…; $B`.
  EG's untemplated texts (all progress and completion text) are as players saw them. Names, class
  and race have been put back as `$N/$C/$R`, but gendered words are already chosen. Where female
  readers saw other words, the female form ships as `pF`/`cF`, and `Text.lua` picks it by `UnitSex`.
  EG Link drops any text naming a player, so the pack holds no player names.

## Where new data goes

1. **Blizzard's words** (prose, names, titles)? Ask the game at runtime (5) if it can answer.
   Otherwise it goes in a pack like layer 4: a separate add-on, generated, never committed.
   It never goes in core data or the overlay.
2. **IDs, numbers, links, masks** (facts about the game)? Core data (2), from EG Link where possible.
3. **Our own writing or judgement** (tiers, teasers, tags)? Overlay (3), hand-edited and committed.
   It must paraphrase and never quote quest text (see `LICENSING.md`, "Teasers").
4. **Anything about one player** (what they saw, did, wrote)? SavedVariables (6).

## Building a release

Build both generated files from the same submodule commits, then package the two add-on folders:

```bash
git submodule update --init --depth 1
uv run pipeline/build_addon_data.py   # -> addon/Plotline/Data/Chains.lua
uv run pipeline/build_quest_text.py   # -> addon/Plotline_QuestText/QuestText.lua
```

A release zip holds `Plotline/` and `Plotline_QuestText/` (with `NOTICE.md`). There's no
packaging script yet. If a removal request comes in, drop `Plotline_QuestText` from the next
release and Plotline keeps working.

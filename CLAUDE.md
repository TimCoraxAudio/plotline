# Plotline: lore-aware quest add-on for WoW Forever

Project notes, carried over from a claude.ai chat. Read this first, then continue from "Next steps".

**This repo is public.** Before committing data, text or art, follow `docs/LICENSING.md`.
Never commit Blizzard text or `pipeline/out/`. Third-party sources are submodules (pointers only).

## Layout
- `addon/Plotline/`: the add-on (TOC, Lua).
- `pipeline/`: offline Python tools, written as uv scripts (inline PEP 723 dependencies; no
  requirements file). Sources are shallow git submodules in `pipeline/sources/`. Output goes to
  `pipeline/out/`, which is git-ignored.
- `docs/`: design notes and `LICENSING.md`.

## Goal
A minimal, native-looking WoW Forever add-on that separates meaningful quests from filler
("kill 10 boars"). It must also remember what the player has done and let them review it
at any time.

- Show whether a quest is in a chain, which chain, and position ("3 of 7").
- Tier every quest: **Filler / Chain / Story / Lore**.
- Short **spoiler-free teaser** per chain (max 140 chars; setup or question, never an outcome).
- Journal: chains, timeline, captured quest text, notes.
- "Previously..." recap, toggleable (login recap and on-demand in Journal; both, with a toggle).
- Surfaces: hints in quest dialog/quest log AND a Journal panel, equal priority.
- Look: Blizzard fonts/art, should look like it shipped with the game.

## Decisions made
- **Chain data is built offline and shipped with the add-on.** No runtime dependency on QuestieDB.
  (Decided 2026-11-18: curated tiers/teasers are keyed to exact chain membership, which a live
  QuestieDB could change; the merge + split can't run in-game; one less install for players.)
- Shipped data = quest-ID lists per chain plus our overlay (tier, teaser, tags). No Blizzard quest
  text and no copied DB rows. Prefer chain links from cleanly licensed sources (EG Link, CC BY 4.0);
  see `docs/LICENSING.md`.
- **Spoken** (rusty-key/spoken-wow) is used **offline only**, as pipeline input. Never a runtime dependency.
- Lore tier is hand-reviewed; LLM drafts, human approves. Curate at chain level, not quest level.
- Teasers are spoiler-free only. Chains the player hasn't started stay hidden until they've seen the first quest.
- Libraries: LibStub, CallbackHandler, optional LibDBIcon. AceDB/AceEvent optional. Plain SavedVariables is fine.
- Forever client: `## Interface: 16001`, **verified in-game** 2026-11-18 (plain `Plotline.toc`
  loads; no `_Forever` TOC suffix needed). **Modern-style UI and `C_*` APIs** (probed 2026-11-18,
  see `docs/DESIGN.md`): no old Classic quest log; the quest log is `QuestMapFrame`.

## Data schema (planned)
Generated (never hand-edited), lazy-loaded per zone group:
```lua
chains["defias-brotherhood"] = { zone = "Westfall", forever = false, quests = {65, 64, 155, 166} }
```
Overlay (hand-edited, survives regeneration):
```lua
meaning["defias-brotherhood"] = { tier = "lore", name = "The Defias Brotherhood",
  blurb = "Stonemasons wronged by Stormwind take matters into their own hands.", tags = {"stormwind"} }
quests[1234] = { tier = "story" }  -- per-quest override
```
Tier rubric: Filler = kill/collect, no named characters, no consequence. Chain = multi-step but
mechanical. Story = named characters, a plot beat, choice or reveal. Lore = changes or reveals world canon.

LLM output per chain (JSON): slug, tier, blurb, tags, confidence, spoiler_check (a second pass
asking only "does this teaser reveal an outcome?"; failures regenerate before review).

## Offline pipeline status
1. Extract + merge chain structure: **DONE** (`merge_chains.py`; EG Link added as a fourth source).
2. Split oversized chains: **DONE** (`split_chains.py`, applied by `merge_chains.py`). Review the
   results in the viewer (`uv run pipeline/chain_viewer.py`).
3. Gather text per chain: TODO. Use EG Link `quests.enUS.json` first (union across builds),
   Spoken's QuestText.lua as fallback. Private pipeline input only.
4. LLM draft (tier, teaser, tags, confidence) + spoiler check: TODO.
5. Human review queue (Lore proposals + low confidence first): TODO.
6. Emit Lua data files: **started** (`build_addon_data.py` -> `addon/Plotline/Data/Chains.lua`, quest IDs
   only, git-ignored until the licensing checklist is done). Validation (IDs exist, no cycles): TODO.

### Reproduce
```bash
git submodule update --init --depth 1   # sources are shallow submodules in pipeline/sources/
uv run pipeline/merge_chains.py         # defaults point at the submodules and pipeline/out/
# optional: --min-trace-conf 0..3 drops weak player-trace edges
```
Outputs: `chains.json` (chains + standalone IDs, no quest text) and `report.md`.

## Source findings (verified in the cloned repos)
**QuestieDB** (github.com/Questie/QuestieDB, master; Forever data in `data/Forever/`)
- 4,244 base Forever quests in `foreverQuestDB.lua` (a Lua string; parse with lupa; key indexes
  are in the file header: preQuestGroup=12, preQuestSingle=13, exclusiveTo=16, zoneOrSort=17,
  nextQuestInChain=22).
- 1,397 new Forever quests in `src/corrections/Forever/generated/foreverBaseQuest.lua`
  (11 more are `<NYI>` placeholders, excluded). They have names/levels/objectives but NO chain links.
- Chain links for new quests come from `src/corrections/Forever/traces/foreverQuestRelationTraces.lua`
  (inferred from ~911k player sessions; many entries are commented out because they are already in
  the base DB, but they are still accepted relations; the script reads both). Confidence labels:
  very high / high / medium / low.
- **Licensing is NOT clean GPL-3.** QuestieDB's `LICENSE.md` says to treat content as "all rights
  reserved" when in doubt. The team allows GPLv3 copying but can't speak for every historic
  contributor. The Questie name and logo are excluded. See `docs/LICENSING.md` and resolve its
  release checklist before shipping anything derived from QuestieDB.

**Spoken** (github.com/rusty-key/spoken-wow; code MIT)
- `addons/Spoken_Quests/Data/QuestText.lua`: accept + complete text, 4,803 quests, median ~100 words.
- `addons/Spoken_Quests/Data/Compendium.lua`: 4,828 quests with title, zones, `prev` (single int),
  race/class masks, `sort` (int, or a word like "winterveil"), `dungeon`, `notext`.
- 4,785 of its text IDs match QuestieDB. Only 567 of the 1,397 new Forever quests have text (~41%).
- Also holds zone/area lore (Spoken_Places, from Warcraft Wiki, CC BY-SA 4.0) and dungeon boss
  stories (Spoken_Bosses): useful as context for the lore tagger. Share-alike applies; use as
  context, don't reproduce.
- **Licensing:** THIRD_PARTY.md says the MIT grant does NOT cover the game text (Blizzard's).
  Keep Spoken's text as private pipeline input; never commit it to this project's repo.
- Spoken also credits Efficient Games' EG Link output; see below.

**EG Link output** (github.com/JIVESCORP/eg-link-output-wowf, CC BY 4.0, examined 2026-11-18)
- One folder per client build: `data/wowf/<build>/<dataset>.json`. A build holds only what was
  recorded on it, so take the union across builds. Live builds with quest data: 1.60.1.70532 to .70938.
- `quests.enUS.json`: server's own quest records. 5,427 quests across builds; 1,391 of the 1,397 new
  Forever quests. Description text for 1,310 new Forever quests (Spoken has 567). All six 0%-text
  chains above are fully covered. Also `nextQuestId`, `raceMask`, `zoneAreaId`/`categoryId`, objectives.
- `nextQuestId`: 1,770 links. 1,585 agree with our merged chains, 12 join two different chains,
  173 touch quests that are standalone in our merge. Worth adding as a fourth edge source.
- `quest_prerequisites.json`: undocumented in DATASETS.md. `before` lists what a few characters
  (single digits) had completed first: looks like observed history, not true prerequisites. Don't
  use for edges without more data.
- ~525 quests EG describes are unknown to our merge; check what they are.
- `npcs.json` (checked 2026-11-18): `npcs[id]` / `objects[id]` with `offers` (quests it starts),
  `takes` (quests it ends), `positions` (uiMap + 0-1 map coords and world yards), `side`,
  `interactions`. Union of 13 builds: a starter for 1,286 quests, an ender for 1,205. Covers only
  ~25% of chain quests so far (937 of 3,688 served; 263 of 950 Forever-era) because it only holds
  NPCs players actually talked to. Agrees with QuestieDB's startedBy on 671 of 674 shared quests
  (EG `n123` = QuestieDB `c123`). Would let the splitter judge NPC handoff on 288 of 1,058
  Forever-era chain links (0 today). Every starter has a position, so CC BY map pins are possible
  where covered. Not wired into the pipeline yet.
- Licence covers EG's compilation; quest text and names stay Blizzard's (their README says so).
  Attribution line: "Data from Efficient Games (https://efficient.games), licensed under CC BY 4.0."

## Merge results (with EG Link, 2026-11-18)
- 6,083 known quests (425 only in EG Link; 101 placeholders dropped); 4,070 edges; **847 chains**;
  1,794 standalone. Chain sizes: 350 of 2; 286 of 3-5; 164 of 6-12; 41 of 13-24; 6 of 25+.
- EG Link adds 114 edges no other source has. The six oversized chains barely change
  (Troll Cave 220 -> 221; Earnest Proposition 106 -> 125), so the splitter is still needed.
- 1,112 edges rest on QuestieDB alone (890 of them player traces only). That's the licensing
  checklist number to bring down.

## Merge results (first run, before EG Link)
- 5,659 known quests; 3,834 sequential edges; **805 chains**; 1,632 standalone quests.
- Chain sizes: 338 of 2; 268 of 3-5; 157 of 6-12; 36 of 13-24; 6 of 25+.
- Spoken `prev` disagrees with Questie/traces in only 38 places; samples look like per-race/class
  variants of the same quest, not real conflicts.
- Several new-Forever chains have 0% text coverage (e.g. "Saving Sunnyglade", "Clugfist's Decree",
  "Slay the Spitelash", "Bloodmaster's Ring", "Scraps of Knowledge"): targets for text gap-filling.

## Chain splitting (how it works now; details in `pipeline/split_chains.py`)
Link sources: questie (single prereq / next), questie-all ("needs all of these"), traces, spoken,
eglink (server's nextQuestId), items (a quest rewards an item exactly one other quest needs:
52 links). Rules, in order:
1. **incompatible** (race/class masks), **category** (class/profession/season group boundary),
   **cross_zone** (trace-only, different zones).
2. **weak_sibling**: at a fork with a well-backed child (2+ sources and an NPC handoff: the next
   quest is picked up where the previous is handed in, from QuestieDB's startedBy/finishedBy),
   a Spoken-only or traces-only sibling link with no handoff is dropped (28). QuestieDB-only ones
   are kept and flagged as **checks** (10). E.g. Kobold Candles -/-> Young Lovers.
3. **turn_in** fans (class armour turn-ins), kept with their quest.
4. **branch / side_quest**: at a fork, children whose storylines meet again form a group; the main
   line is the one rejoining group, else the longest branch (a guess: `how = "longest"`).
   Other groups whose first quest has no other way in (except from quests that feed only it)
   become their own chain marked `branches_from` (46), or, if one quest, a side quest folded into
   the fork quest (175). Faction/class alternatives and same-title versions are never split.
   E.g. Welcome to the Jungle -> "The Green Hills of Stranglethorn" (with Chapters I-IV).
Viewer filters "Split by length" and "Links to check" list the decisions worth reviewing.
NPC handoff only covers QuestieDB quests; Forever-only quests can't be judged yet. EG Link's
npcs.json would cover 288 of the 1,058 Forever-era links (see Source findings).

### Breakdown findings (2026-11-18, `uv run pipeline/analyze_chains.py` -> `pipeline/out/breakdown.md`)
- **The Troll Cave (221):** glued together by Forever's camping/profession intro quests (QuestSort
  666: 79 "Camping 101: <profession>", 7 "The Great Outdoors", 4 "The Adventurer"). Each Great
  Outdoors variant has ~75 links to them, all player-trace only and mostly rated *very high*,
  so trace confidence can't filter them. Without that group the chain falls into the real starter
  storylines: Zephras Isle 77, Northshire 19, Deathknell 15, Coldridge 9, an Elwynn book chain 9.
- **An Earnest Proposition (125):** one real storyline (dungeon set upgrades) with per-class and
  per-faction variants ("Just Compensation" x32). Keep as one chain; collapse variants into steps.
  A plain hub cut destroys it (94 quests left standalone), so don't cut at hubs blindly.
- **Naxxramas (79), Mortal Champions (47):** a story quest fanning out to 72 / 45 class-restricted
  armour turn-ins. Turn-in leaves aren't chain steps.
- **Plaguelands "Clear the Way" (48):** a genuine zone arc, 22 Alliance + 22 Horde quests joined by
  4 shared ones. Keep; compute position per faction.
- **Gadgetzan Water Survey (26):** Tanaris and Feralas joined only by trace links. Dropping
  trace-only links splits it into 10 / 8 / 7.
- **Data gap:** EG Link's `raceMask` is `ffff...` (every race) for ~4,000 quests including
  faction-only ones. Use Spoken's `races` when EG's mask is unrestricted.

**Candidate splitter rules** from the above, in order: (A) don't link a class/profession/season
QuestSort group to zone quests on trace-only evidence; (B) treat fans of leaf turn-ins as rewards,
not steps; (C) drop links between quests no one character can take (race/class masks);
(D) drop trace-only links that cross zones; (E) collapse same-title variants into one step for
"3 of 7". No blind hub cuts.

## Next steps
1. ~~Add EG Link as an input to `merge_chains.py`~~ done (raceMask feeds the splitter).
2. ~~Splitter~~ done (see "Chain splitting" above). 922 chains, 1,821 standalone quests.
   Review "Split by length" (150 chains) and "Links to check" (11 chains) in the viewer.
   Parked: Zephras Isle "Coming of Age" (60 quests, 41 steps) still has unlinked starts, e.g. a
   level-11 quest at step 1.
2b. **Forever re-issues Classic quests under new IDs** (found 2026-11-18). Classic IDs are all
   < 10000, Forever's all >= 60000 (`split_chains.era`, cut-off 30000). EG Link's `quest_scan`
   shows which IDs the Forever server answers for: 388 known quests get no answer ("not served",
   295 of them in chains). E.g. all 16 Classic "Just Compensation" are not served; 16 Forever IDs
   replace them, known only to EG Link, with no recorded "from" link. The splitter now places such
   unlinked quests at the step of a same-title quest with the same next quests (`anchored` in
   chains.json; 22 quests). Undecided: whether to drop not-served quests from shipped chains.
   Scans come from only 2-3 players, so check a sample in the viewer first.
3. Text gaps are now small (EG Link). An in-game collector capturing `QUEST_DETAIL` /
   `QUEST_PROGRESS` / `QUEST_COMPLETE` text is only needed for what's left.
4. LLM tagging prompt + spoiler-check pass + review queue.
5. Add-on skeleton: **loads in-game**. Quest dialog hints (gold line under the title in the dialog
   and quest log, badge, steps tooltip on hover): **working in-game** (`Chains.lua`, `Hints.lua`; `/plotline quest <id>`
   prints the same in chat). Steps tooltip, pinned steps panel, quest card.
   Journal (`/pl j`): Compendium (people/places/factions/items from what you did, links in quest
   text, NPC tooltip line), Timeline and Chains tabs built (Chains imports progress from completed quests).
   Next: ways to open the Journal (minimap button, quest log button, key binding) and a settings page. Text capture built (`Record.lua`).
   Later: Compendium lore layers (own words, unlocked per quest).
6. Runtime: events `QUEST_DETAIL`, `QUEST_ACCEPTED`, `QUEST_TURNED_IN`;
   `C_QuestLog.GetAllCompletedQuestIDs()` to backfill history; capture quest text at turn-in so the Journal can reread it.

7. **Screenshots without the game** (2026-11-19): `sim/` runs the add-on in wowless, a headless WoW client
   with a WoW Forever product, from GitHub Actions (`.github/workflows/screens.yml`); PNGs per scene in
   the `screens` artifact, a text report per scene in the job log. Layout is real (Blizzard's own UI code);
   rendering is approximate. See `sim/README.md`. Add a scene in `sim/PlotlineSim/Sim.lua` to check new UI.

Manual review items (viewer checks, in-game checks, open data questions) live in
`docs/REVIEW.md`. Add to it rather than to this file.

## Files
- `pipeline/merge_chains.py`: merge, then split; writes `chains.json` (`steps`, `turnins`,
  `side_quests`, `branches`/`branches_from`, `split_from`, `length`, `removed_links` with the rule
  for each, and `checks`).
- `pipeline/split_chains.py`: the splitter rules and race/class/category helpers.
- `pipeline/analyze_chains.py`: breakdown of the largest merged (pre-split) groups.
- `pipeline/build_addon_data.py`: writes the add-on's `Data/Chains.lua` (IDs, steps, side quests, turn-ins,
  branches, race/class/faction rules, retired quests). Titles are looked up in-game, never shipped.
- `addon/Plotline/Data/DevQuestText.lua` (`build_addon_data.py --dev-text`): DEV ONLY quest text for testing the
  quest card until text capture exists. Git-ignored; never commit or ship. Drop it once capture lands.
- `addon/Plotline/`: `Plotline.lua` (settings, `/plotline`), `Chains.lua` (lookups, per-character view,
  titles), `Hints.lua` (quest dialog/log hints), `Record.lua` (Compendium recording, text capture,
  timeline), `Journal.lua` (Journal window, Compendium, links), `Probe.lua` (`/plotline probe`).
- `sim/`: wowless screenshots (harness add-on `PlotlineSim`, `run.sh`, `render.py`, `report.py`,
  `wowless.patch`). Output and `Generated.lua` are git-ignored (Blizzard art and text).
- `pipeline/chain_viewer.py` + `pipeline/viewer/index.html`: local viewer (stdlib HTTP server,
  127.0.0.1). Builds chains in memory; shows quest text from the submodules, never writes it.
- `pipeline/out/chains.json`, `pipeline/out/report.md`: generated and git-ignored. Re-run the merge to recreate them.
- Third-party sources: `pipeline/sources/*` submodules (`.gitmodules`, shallow).

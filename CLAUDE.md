# Plotline: lore-aware quest add-on for WoW Forever

Project notes, carried over from a claude.ai chat. Read this first, then continue from "Next steps".

**This repo is public.** Before committing data, text or art, follow `docs/LICENSING.md`.
Never commit Blizzard text, third-party clones or `pipeline/out/`.

## Layout
- `addon/Plotline/`: the add-on (TOC, Lua).
- `pipeline/`: offline Python tools. Clones go in `pipeline/sources/` and output in `pipeline/out/`. Both are git-ignored.
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
- Runtime depends on **QuestieDB** (separate addon) for chain structure; we do not ship its data.
- Our own shipped data = overlay only: chain slug, tier, teaser, tags, keyed by quest ID.
  No Blizzard quest text and no copied DB rows in the shipped add-on.
- **Spoken** (rusty-key/spoken-wow) is used **offline only**, as pipeline input. Never a runtime dependency.
- Lore tier is hand-reviewed; LLM drafts, human approves. Curate at chain level, not quest level.
- Teasers are spoiler-free only. Chains the player hasn't started stay hidden until they've seen the first quest.
- Libraries: LibStub, CallbackHandler, optional LibDBIcon. AceDB/AceEvent optional. Plain SavedVariables is fine.
- Forever client: Questie's `Questie_Forever.toc` uses `## Interface: 16001`. I have NOT seen
  Forever's add-on API docs; assume a Classic-era API and verify against the beta.

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
1. Extract + merge chain structure: **DONE** (`merge_chains.py`).
2. Split oversized chains: **TODO** (see below).
3. Gather text per chain from Spoken's QuestText.lua: TODO.
4. LLM draft (tier, teaser, tags, confidence) + spoiler check: TODO.
5. Human review queue (Lore proposals + low confidence first): TODO.
6. Emit Lua data files + validate (IDs exist, no cycles): TODO.

### Reproduce
```bash
pip install -r pipeline/requirements.txt
git clone --depth 1 https://github.com/Questie/QuestieDB.git pipeline/sources/QuestieDB
git clone --depth 1 https://github.com/rusty-key/spoken-wow.git pipeline/sources/spoken-wow
python3 pipeline/merge_chains.py --questiedb pipeline/sources/QuestieDB \
    --spoken pipeline/sources/spoken-wow --out pipeline/out
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
- Spoken also credits Efficient Games' EG Link output
  (github.com/JIVESCORP/eg-link-output-wowf, CC BY 4.0, Forever client-recorded data). Not examined;
  may be a cleaner direct source for new-quest text and chain links.

## Merge results (first run)
- 5,659 known quests; 3,834 sequential edges; **805 chains**; 1,632 standalone quests.
- Chain sizes: 338 of 2; 268 of 3-5; 157 of 6-12; 36 of 13-24; 6 of 25+.
- Spoken `prev` disagrees with Questie/traces in only 38 places; samples look like per-race/class
  variants of the same quest, not real conflicts.
- Several new-Forever chains have 0% text coverage (e.g. "Saving Sunnyglade", "Clugfist's Decree",
  "Slay the Spitelash", "Bloodmaster's Ring", "Scraps of Knowledge"): targets for text gap-filling.

## Open problem (do this next)
Six chains are far too large because the graph merges at hub quests: "The Troll Cave" (220, with 184
new Forever quests across three starter zones, mixing class/profession and story quests),
"An Earnest Proposition" (106), the Naxxramas line (79), "Clear the Way" (48), "Mortal Champions" (47),
"Gadgetzan Water Survey" (26). Dropping low-confidence trace edges barely helps (220 -> 179 at the
strictest setting), so the cause is structural. Write a **splitter**: cut at hub nodes (high
out-degree) and/or partition by zone, race mask, class mask / `sort`. Keep the `flags` (large,
class_or_profession, dungeon, branching, group_prereq) in the output. Spoken's `prev` is a single
int and can't express "needs any of these"; Questie's `preQuestGroup` is tracked separately and not
used for merging.

## Next steps
1. Splitter for oversized chains; re-run and read `report.md`.
2. Fill text gaps: check EG Link output; otherwise an in-game collector mode capturing
   `QUEST_DETAIL` / `QUEST_PROGRESS` / `QUEST_COMPLETE` text into SavedVariables.
3. LLM tagging prompt + spoiler-check pass + review queue.
4. Add-on skeleton (TOC, events, SavedVariables): **started** in `addon/Plotline/`. Then
   quest-dialog hints and Journal UI mockups.
5. Runtime: events `QUEST_DETAIL`, `QUEST_ACCEPTED`, `QUEST_TURNED_IN`; `GetQuestsCompleted()` to
   backfill history; capture quest text at turn-in so the Journal can reread it.

## Files
- `pipeline/merge_chains.py`: the merge step (committed).
- `pipeline/out/chains.json`, `pipeline/out/report.md`: generated and git-ignored. Re-run the merge to recreate them.
- Third-party clones aren't included. Re-clone them with the commands above.

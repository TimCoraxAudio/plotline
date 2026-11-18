# Manual review list

Things the pipeline can't decide on its own. Check them by hand, in the chain viewer
(`uv run pipeline/chain_viewer.py`) or in-game, and record the outcome here. Numbers are from
the 2026-11-18 run.

## In the viewer

| # | What | How to find it | What to decide |
|---|---|---|---|
| 1 | **Branches decided by length** (39 of 46 branches; 150 chains in the filter) | Filter "Split by length" | Is the longer branch really the main storyline? If not, note the chain; we may need a title or NPC rule. |
| 2 | **Links to check** (10 QuestieDB-only links at a fork, 11 chains) | Filter "Links to check" | Real link or noise? These are kept for now. |
| 3 | **"Coming of Age"** (Zephras Isle, 60 quests, 41 steps) | Search "Coming of Age" | It now has a side quest that looks wrong, and unlinked starts, e.g. a level-11 quest at step 1. Parked. |
| 4 | **Placed by title match** (22 quests) | Card chip "placed by title match" | Is the quest really a re-issue of its namesake at that step? |
| 5 | **Weak-sibling drops** (28 links) | Filter "Has removed links", rule `weak_sibling` | Spot-check that none was the real storyline. |
| 6 | **EG Link joins two chains** (12 `nextQuestId` links) | `report.md` / removed links | Server link that our other sources disagree with. Which is right? |
| 7 | **Side quests** (175) | Folded panel on quest cards | Spot-check they really are one-off detours. |

## In-game

| # | What | What to decide |
|---|---|---|
| 8 | **Not-served quests** (388 known, 295 in chains) | Scans come from 2–3 players only. Try a sample in-game (e.g. a Classic "Just Compensation"). Then decide whether to drop not-served quests from shipped chains. |
| 9 | **Forever-only quests have no NPC handoff data** | The weak-sibling rule can't judge them. Note any Forever chain whose order looks wrong in-game. EG Link's `npcs.json` covers 288 of 1,058 such links (not wired in yet). |
| 10 | **Faction-only quests with an "any race" mask** (EG `raceMask` ffff…) | We fall back to Spoken, then QuestieDB. Note any quest the add-on shows to the wrong faction. |
| 11 | **API probe** (`/plotline probe`, then `/plotline probe watch`) | Run both, `/reload`, and share `PlotlineDB.probe` / `probeWatch` from `WTF/Account/<account>/SavedVariables/Plotline.lua`. Decides which surfaces in `docs/DESIGN.md` are possible on Forever. |

## Data questions

| # | What | Notes |
|---|---|---|
| 12 | ~525 quests EG Link describes that our merge didn't know (425 now kept, 101 placeholders dropped) | What are they? New content, test quests, re-issues? |
| 13 | EG Link `quest_prerequisites.json` | Undocumented. Looks like observed history, not prerequisites. Don't use without more data. |
| 14 | QuestieDB-only links (1,112 at last count) | Licensing checklist number before release; see `docs/LICENSING.md`. |

## Outcomes

(Record decisions here: date, item number, what was decided.)

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
| 11 | **API probe: two loose ends** | Gossip quest fields (`C_GossipInfo.GetAvailableQuests`) and `QUEST_TURNED_IN` arguments. Low risk; confirm while testing the first build. |
| 12 | **Unlinked quests placed at step 1** | Confirmed wrong in-game: "From the Ashes" (98221) is offered by Captain Stoutfist with War Banners (step 4 of "This Land Was Their Land") but sits at step 1. Same issue as "Coming of Age". |
| 16 | **Quest text pack loads on demand** | Install `Plotline_QuestText` beside Plotline and open a quest card or the Journal. Does `C_AddOns.LoadAddOn` load a `LoadOnDemand` add-on on this client? Is there a noticeable hitch the first time (2.7 MB)? `/plotline` should say "quest text: Plotline Quest Text". Also check it with the pack disabled. |

## Data questions

| # | What | Notes |
|---|---|---|
| 13 | ~525 quests EG Link describes that our merge didn't know (425 now kept, 101 placeholders dropped) | What are they? New content, test quests, re-issues? |
| 14 | EG Link `quest_prerequisites.json` | Undocumented. Looks like observed history, not prerequisites. Don't use without more data. |
| 15 | QuestieDB-only links (1,112 at last count) | Licensing checklist number before release; see `docs/LICENSING.md`. |
| 17 | Gendered description text | About 150 descriptions come from EG Link's recorded texts, where gendered words (`$g`) were already chosen by whoever recorded them. Spot-check on a female character for "Sir"-style wording. |
| 18 | **Quests with no opening text in the pack** (771 known, 347 in chains, 105 Forever-era) | 671 have only a hand-in line in Spoken and no description anywhere; 100 have no text at all. Many look item-, object- or battleground-started (Corrupted Songflower 3363, Shardtooth E'ko 4803, Hammershout the Elder 8646, Fight for Warsong Gulch 8408). **In-game:** open a few as quest links or in the quest log (`/plotline quest <id>` for the chain line). Does the game show a description? If yes, our sources are incomplete and capture will fill it in. If no, those quests have no opening text and the pack is right. Then decide: show objectives alone where we have them (about 37), or add the hand-in line back as a fallback for these quests only. |

## Outcomes

(Record decisions here: date, item number, what was decided.)

- 2026-11-18, #11: first probe pass. Modern UI on a Classic base: quest dialog, NPC quest lists
  with quest IDs, `C_QuestLog`, `WorldMapFrame:AddDataProvider`, modern Settings and templates all
  present; old quest log API gone. Details in `docs/DESIGN.md`.
- 2026-11-18, #11: second pass. NPC tooltips (`TooltipDataProcessor`) and icons on friendly NPC
  nameplates both work in-game.
- 2026-11-18, in-game: **The Defias Brotherhood** showed 5/7. Checked: correct. The player had
  killed VanCleef without the quest; 155 (Defias Traitor escort) and 166 were simply not done yet.
  An earlier guess that Forever made 155 optional was wrong: EG Link's `nextQuestId` for 142 is
  empty because 155 is started by a different NPC (the Traitor), not because the link is gone. So
  a missing `nextQuestId` is NOT evidence of an optional step. The add-on still treats a step that
  wasn't done, before one that's done or in the log, as "skipped" (harmless, and right if it ever
  happens).

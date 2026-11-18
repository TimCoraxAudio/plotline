# Add-on design

Decisions from the design walk-through on 2026-11-18. The HTML mockup that goes with this is
served by the chain viewer at `/mockup` (`uv run pipeline/chain_viewer.py`). It uses real chain
data locally; no quest text is committed.

## First build (v0.1)

Uses the chain data we have now (no tiers, teasers or summaries yet):

1. Quest dialog hints
2. Quest log detail line
3. Journal, Chains tab (with backfill)
4. Text capture and the Timeline tab

Later: tiers (Filler / Chain / Story / Lore), teasers, the "Previously…" recap, notes.

## Quest dialog (NPC quest frame)

- **Gold line under the title:** `The Defias Brotherhood, step 3 of 7`, in the dialog's own font.
- **Badge** (`3/7`) at the right end of the gold line's row, inside the quest text (on the progress
  page: after the title). Not in the frame's corner: Spoken puts a button there on some quests.
- **Hovering the badge or the gold line shows the chain's steps as a tooltip** (chain name, step,
  zone, then the step list). Tried a permanent side tab first (2026-11-18); it was too heavy, so
  the steps only show on hover.
- **Clicking the badge or the line pins the steps** as a small panel (closes with the dialog or
  map, or on a second click). In the panel, **clicking a reached step shows that quest's card**:
  the game's own quest card (what a quest link shows) now, plus the description and completion
  text the player saw once text capture exists. Shift-click links the quest in chat.

Quests in no chain: show nothing.

## Quest log

Detail pane only: the same gold line under the quest title, with the same steps tooltip on hover.
The quest list itself is left alone.

## Quest tracker and the quest log's list

A grey step count (`2/5`) right after the title of each chain quest, in the objective tracker and
in the quest log's quest list (grouped by zone); nothing for standalone quests. Hover for the steps tooltip, click to pin the panel. It's our own label on
the tracker's quest block; the tracker's own text is never changed (taint risk with quest item
buttons). Titles are found by matching the quest log's titles against the text in those frames
(ignoring Forever's `[6]` level prefix), so it doesn't depend on how Forever built them.
`/plotline tracker` lists what was matched.

**Open: utility chains** (e.g. Forever's "Camping 101: <profession>" quests, class quests). They're
real chains but not stories. Keep them in the data (Journal and Timeline history), but consider not
marking them in the tracker / quest list: either hide or dim the step count for chains whose quests
are all in a class/profession/Camping QuestSort group (the pipeline already knows each quest's
category), or let the tiers decide (only Story/Lore chains get a mark) once tagging exists.

## Step lists (steps tooltip and Journal)

- **Position counts steps**, not quests. Parallel quests share a step; variants (per class, race,
  faction) collapse into one. Steps with nothing the character can take are skipped, so a
  Horde character's count can differ from an Alliance one's.
- **Spoilers:** done steps and the current step show their titles. Everything ahead shows as
  `???`. The count ("3 of 7") still tells you how far there is to go.
- **Skipped steps:** a step not done, before a step that's done or in the quest log, shows as
  "(skipped)" and doesn't block the chain (Forever made some steps optional). A chain is done when
  every step is done or skipped.
- **A step with parallel quests is done when every quest the character can take is done.** Until
  then it shows progress, e.g. `2/3`.
- **Side quests:** indented line under their step, not counted in the position.
- **Branch chains:** an indented link under the fork step (`↳ Branch: The Green Hills of
  Stranglethorn`) that opens that chain. Hidden until the character has seen its first quest,
  like any chain. (Until v0.1 tracks seen quests, a branch shows once its fork step is done.)
- **Not-served quests** (Classic IDs the Forever server no longer offers) are hidden from step
  lists. They stay in the data so backfill can still recognise them on old characters.

## Journal

- Opened from all of: a minimap button (LibDBIcon, can be hidden), a button on the quest log
  frame, `/plotline` (or `/pl`), and a key binding.
- **Two panes, quest-log style.** Left: chains grouped by zone under collapsible headers, each
  with its status (`3/7`, `done`). Right: the selected chain's step list, with captured text
  readable per step. Tabs at the bottom: **Chains / Timeline / Notes** (Notes later).
- Chains the character hasn't seen stay hidden. A zone header may say how many are undiscovered.
- **Backfill:** chain progress uses `C_QuestLog.GetAllCompletedQuestIDs()`, so chains finished before
  Plotline was installed show as started/done right away. A chain's page says how many of its
  quests were done before Plotline (no text or history for those).
- **Chains tab (built):** started chains by zone, your current zone first and open; `3/7` or `done`
  per chain, `done/total` per zone; search. The page: zone, progress, steps (reached steps link to
  the quest page, with a Back link), what it branches off, branches reached.

## Compendium (Journal tab)

What this character knows: **people** (NPCs you talked to), **places** (zones and subzones you've
been), **factions** (standing gained after a quest) and **items** (asked for or given by quests).
Built in-game from what you did (`Record.lua`), so it never spoils anything.

- Each entry: name, kind, where (people), first/last seen, the quests involved and your role
  (gave you / took / accepted here / completed here / needed / reward), the chain each quest is
  in, and for people the text they showed you (accept text for quests they gave; hand-in text
  only for quests you've completed).
- **Links:** known names become links in Plotline's windows and in the game's quest text (dialog
  and quest log; setting `linkQuestText`, on by default). Hover for a summary, click to open the
  entry. Quest links open the quest card. NPCs you've met get a "Plotline: met ..." tooltip line.
- Names come from the game as you meet things; we ship none. Matching is by whole words, longest
  name first; names under 4 letters aren't linked.
- **Later: lore layers.** Short write-ups per entry in our own words (LLM-drafted from private
  pipeline sources, human-reviewed, never quoting Blizzard or Warcraft Wiki text), each layer
  unlocked by a quest so it only says what the character would know.

## Text capture and Timeline

- Capture **both** accept text (`QUEST_DETAIL`: description + objectives) and completion text
  (`QUEST_COMPLETE`), plus progress text. Stored per character in SavedVariables, on the player's
  machine only. **Built** (`Record.lua`); the quest card prefers it over the dev text.
- Timeline: a dated list of accepted and completed chain quests, newest first. Each opens its text.

## "Previously…" recap

Waits for the pipeline's short summaries; it won't ship in v0.1. When it does: show it at login
only after a break (12+ hours by default, configurable) and only when chains are active, in a
small panel that can be dismissed. It can also be opened from the Journal.

## Look

The game's own fonts and UI textures, referenced at runtime (`Interface\\...` paths). We never
ship copies of Blizzard art. Gold `GameFontNormal` for labels; the steps use the game's own tooltip.

## What the game API allows (probed in-game, build 1.60.1.70959, 2026-11-18)

Forever runs a **modern-style UI on a Classic-era base**. The old Classic quest log and its API are gone;
the newer `C_*` APIs are there. Design against the modern UI.

| Surface | Status | How |
|---|---|---|
| Quest dialog | **yes** | `QUEST_DETAIL` + `GetQuestID()` (returned the right IDs). Anchor under `QuestInfoTitleHeader` in `QuestFrame`. |
| NPC quest lists | **yes, with quest IDs** | Greeting: `GetAvailableQuestInfo(i)` returns the quest ID (5th value). Gossip: `C_GossipInfo.GetAvailableQuests()` exists and `GOSSIP_SHOW` fires; its fields are unconfirmed (the probed innkeeper had no quests). Check during the first build. |
| Quest log | **retail UI** | `/fstack` shows Blizzard's **Mainline (retail) UI code** (`Blizzard_UIPanels_Game/Mainline/QuestMapFrame.xml`). No old Classic log or `GetQuestLogTitle`. Details view: `QuestMapFrame.QuestsFrame.DetailsFrame` (`QuestMapFrame.DetailsFrame` exists too), scroll `QuestMapDetailsScrollFrame`, text `QuestInfoDescriptionText`. `QuestMapFrame_ShowQuestDetails` exists. Use `C_QuestLog.GetInfo` / `GetQuestIDForLogIndex`. `ObjectiveTrackerFrame` is the tracker. |
| History | **yes** | `C_QuestLog.GetAllCompletedQuestIDs()` for backfill (`GetQuestsCompleted` doesn't exist). `QUEST_ACCEPTED`'s first argument is the quest ID. `QUEST_TURNED_IN` exists; its arguments are unconfirmed (expected: quest ID, XP, money). |
| NPC tooltips | **yes** | `TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, ...)`; `data.guid` gives the NPC ID. Probe line showed in-game. (`OnTooltipSetUnit` doesn't exist.) |
| Nameplate icons | **yes** | `NAME_PLATE_UNIT_ADDED` + `C_NamePlate.GetNamePlateForUnit`; a texture anchored above the plate showed on friendly NPCs. Needs friendly nameplates on (Shift+V). |
| World map pins | **yes** | `WorldMapFrame:AddDataProvider` (modern map canvas): our own pin provider, no map library needed. Minimap pins still need positioning by hand or HereBeDragons. |
| Settings | **modern** | `Settings.RegisterAddOnCategory` (no `InterfaceOptions_AddCategory`). |
| Journal frame | **modern templates** | `ButtonFrameTemplate`, `PanelTemplates_*` tabs, `ScrollBox` (`CreateScrollBoxListLinearView`). Native look without our own art. |
| Game's own markers over NPCs' heads | **no** | Drawn by the engine; can't be hidden or changed. |

**Data limit:** everything outside the quest dialog needs NPC → quest data. EG Link `npcs.json`
(CC BY 4.0) has it with positions for ~25% of chain quests; the three Wetlands NPCs from the probe
aren't in it yet. QuestieDB has more, but its licence is unclear.

### Building on the game's windows

- Add to the game's windows wherever possible; only the Journal is our own window (built from
  `ButtonFrameTemplate`, `PanelTemplates_*` tabs and `ScrollBox`). Add a Journal button on the quest log.
- The quest dialog and the quest log details are both filled by retail's shared
  `QuestInfo_Display` (`QuestInfoTitleHeader`, `QuestInfoDescriptionText`), so one
  `hooksecurefunc("QuestInfo_Display", ...)` places the gold line in both. Insert it under the title by
  re-anchoring whichever element was anchored to the title.
- Forever **customises** the retail UI (e.g. its built-in quest tracker shows quest levels, which
  retail doesn't). Check a frame's real layout in-game (`/fstack`, the probe) before hooking it;
  don't assume retail's.
- Hook only after Blizzard's code (`hooksecurefunc`, events); never replace Blizzard functions
  (taint on the world map / tracker causes "action blocked" errors). Anchor to Blizzard frames, not
  screen positions, so reskins (ElvUI etc.) still line up.

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

All three, together:

- **Gold line under the title:** `The Defias Brotherhood · Step 3 of 7`, in the dialog's own font.
- **Badge** in the frame's top-right corner (`3/7`). Hover shows a tooltip with the chain name,
  zone and progress.
- **Side tab:** a narrow panel docked to the right of the quest frame listing the chain's steps.
  It can be toggled from the badge; the open/closed state is remembered.

Quests in no chain: show nothing.

## Quest log

Detail pane only: the same gold line under the quest title. The quest list itself is left alone.

## Step lists (side tab and Journal)

- **Position counts steps**, not quests. Parallel quests share a step; variants (per class, race,
  faction) collapse into one. Steps with nothing the character can take are skipped, so a
  Horde character's count can differ from an Alliance one's.
- **Spoilers:** done steps and the current step show their titles. Everything ahead shows as
  `???`. The count ("3 of 7") still tells you how far there is to go.
- **A step with parallel quests is done when every quest the character can take is done.** Until
  then it shows progress, e.g. `2/3`.
- **Side quests:** indented line under their step, not counted in the position.
- **Branch chains:** an indented link under the fork step (`↳ Branch: The Green Hills of
  Stranglethorn`) that opens that chain. Hidden until the character has seen its first quest,
  like any chain.
- **Not-served quests** (Classic IDs the Forever server no longer offers) are hidden from step
  lists. They stay in the data so backfill can still recognise them on old characters.

## Journal

- Opened from all of: a minimap button (LibDBIcon, can be hidden), a button on the quest log
  frame, `/plotline` (or `/pl`), and a key binding.
- **Two panes, quest-log style.** Left: chains grouped by zone under collapsible headers, each
  with its status (`3/7`, `done`). Right: the selected chain's step list, with captured text
  readable per step. Tabs at the bottom: **Chains / Timeline / Notes** (Notes later).
- Chains the character hasn't seen stay hidden. A zone header may say how many are undiscovered.
- **Backfill:** on first load, `GetQuestsCompleted()` marks chains already done. Those steps are
  labelled "before Plotline" and have no captured text.

## Text capture and Timeline

- Capture **both** accept text (`QUEST_DETAIL`: description + objectives) and completion text
  (`QUEST_COMPLETE`). It's stored per character in SavedVariables, on the player's machine only.
- Timeline: a dated list of accepted and completed chain quests, newest first. Each opens its text.

## "Previously…" recap

Waits for the pipeline's short summaries; it won't ship in v0.1. When it does: show it at login
only after a break (12+ hours by default, configurable) and only when chains are active, in a
small panel that can be dismissed. It can also be opened from the Journal.

## Look

The game's own fonts and UI textures, referenced at runtime (`Interface\\...` paths). We never
ship copies of Blizzard art. Gold `GameFontNormal` for labels, parchment quest frame styling for
the side tab so it reads as part of the dialog.

## What the game API allows (to confirm with `/plotline probe`)

- **Can't:** hide, recolour or replace the game's own quest markers over NPCs' heads (the engine draws
  them), change the game's own minimap blips, or stop the server offering a quest.
- **Can:** add lines to NPC tooltips (`UnitGUID` gives the NPC ID); attach icons to friendly
  nameplates (if `C_NamePlate` exists and friendly nameplates are on); restyle the quest buttons
  in gossip/greeting lists (quest IDs if `C_GossipInfo` exists, titles only otherwise); the quest
  dialog and quest log (planned); draw our own map and minimap pins (HereBeDragons style).
- **Data limit:** everything outside the quest dialog needs NPC → quest data. EG Link `npcs.json`
  (CC BY 4.0) has it, with positions, for ~25% of chain quests so far; QuestieDB has more but its
  licence is unclear.

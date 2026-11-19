# Storylines across chains

Some stories don't fit in one chain. The Forever Rogue quests are the example that started this
(2026-11-19). "The Horn of Xelthos" (level 23), "The Eye of Bhossca" (35) and "Fool Me Twice" (50) refer to
each other, but no `nextQuestId` or prerequisite joins them, and they're 10 to 25 levels apart. Several of their
quests also start from a letter in the mail or from an item, and only appear in the quest log when you
reach the right place and hand something in. The chain data alone can't show any of that.

This page is the plan for that: how the data marks it, what the player sees, and how an LLM can do
the first pass at linking chains without the person reviewing it getting spoiled.

## What the data already tells us (checked 2026-11-19)

- **Class quests have a QuestSort category.** EG Link `categoryId` 162 = Rogue (also 61 Warlock,
  81 Warrior, 82 Shaman, 141 Paladin, 161 Mage, 261 Hunter, 262 Priest, 263 Druid). The Forever
  Rogue quests are all 162: 18 quests in chains like "The Horn of Xelthos", "Fool Me Twice",
  "The Manor, Ravenholdt", "What's the Big Idea?", plus a few standalone ones.
- **Quests started by an item:** EG Link `startItemId`, on 1,257 quests. "Best Laid Plans" and
  "One Last Drop" in "Fool Me Twice" start this way.
- **Hand-in only quests:** quest flag `0x10000` (auto-complete). These finish as soon as you talk to
  the NPC, without ever being in your log. Only 3 known quests carry the flag, among them the second
  "The Eye of Bhossca" (78699, standalone in our data). Other letter quests do enter the log
  briefly, so runtime capture has to cover the rest.
- **Item links between quests:** a quest rewards or drops an item that starts another quest. Limited
  to items that start one or two quests, there are 32 such links. **They are not chain links**
  (tried 2026-11-19): most were already in the chains, and the new ones attached "replace a lost item"
  quests at step 1, renamed three chains and made a loop in "The Manor, Ravenholdt" (its last quest
  rewards a disguise that also starts two earlier quests). `merge_chains.py` keeps them as
  `g.start_item_links`, used only as saga evidence.
- Quest givers and enders for Forever quests are mostly missing (EG Link `npcs.json` covers only
  quests players talked to someone about). So "where do I take this letter" needs runtime capture.

## Data model

### Core data (layer 2, generated): new per-quest facts

| Field | Meaning | Source |
|---|---|---|
| `si` | item that starts the quest | EG Link `startItemId` |
| `ac` | hand-in only (auto-complete): never in the quest log | EG Link `flags & 0x10000` |

New per-chain field `cat`: the QuestSort category when the chain's quests all have the same
class or profession category (e.g. `cat=162` for the Rogue chains). The Journal groups those chains
under the class name instead of a zone.

### Overlay (layer 3, hand-edited): sagas

`addon/Plotline/Data/Sagas.lua`. A **saga** groups chains (and loose quests) that tell one story.
Chains stay mechanical, and a saga sits on top of them.

```lua
sagas["rogue-forever"] = {
  n = 78261,                     -- quest whose title names the saga (titles come from the game)
  class = 4,                     -- shown under this class (class ID), optional
  parts = {                      -- in story order
    { chain = "the-horn-of-xelthos-78261" },
    { quest = 78270 },           -- loose quests that belong here
    { quest = 78699 },
    { chain = "fool-me-twice-80526" },
  },
  links = { { from = 1, to = 4, kind = "references" } },   -- kinds: continues, references, same_cast, unlocked_by
  source = "human",              -- "human", or "llm" (drafted, approved)
}
```

- Chain IDs are the generated slugs. When the pipeline renames a chain, `build_addon_data.py`
  warns about overlay entries that point at a chain that no longer exists.
- Names are game titles looked up by quest ID (`n`). We write no Blizzard text into the overlay.
  A saga may get its own name later (`name`, our own words, spoiler-free like teasers).

## What the player sees

1. **Saga line.** In the steps tooltip: "Part of a longer storyline: chain 1 of 2". On the Journal
   chain page, a "Storyline" section lists the parts in story order. Parts are named only once the
   character has started them. Unseen ones show as "1 more part you haven't found yet". The setting
   `sagaHints` (on by default, `/plotline sagahints`) controls this: off hides the count, and the
   tooltip line too while any part is unseen.
2. **Waiting state.** A chain you've started whose next step needs a higher level shows "Continues
   at level 35" on its Journal page. The list shows the level next to the progress.
3. **Level-up reminder** (setting `levelReminder`, on by default). On level-up, one chat line for each
   started chain whose next step has just become possible: "Plotline: The Horn of Xelthos can
   continue (level 35)". Only chains you've started, so it spoils nothing. Toggle it with
   `/plotline reminders`. It moves to the settings page when that exists.
4. **Leads.** Items in your bags or mailbox that start a quest you haven't done, and that isn't in
   your log yet, are recorded with where they came from (mail sender and subject, or "in your bags"),
   when and where you were. They're listed at the top of the Journal's Chains tab under "Leads". A
   lead's page shows the item (the game's own link), where it came from, the level it needs if that's
   above yours, who to hand it in to (when the data knows), and the chain it continues if you've
   started that chain. The quest's title isn't shown, and neither is an unstarted chain. A lead
   disappears once its quest is accepted or handed in. Bags are scanned on login and whenever they
   change; the mailbox when it's opened.
5. **Grouping in the Journal's Chains tab.** A chain in a saga goes under the saga's name, in story
   order. Otherwise a class chain goes under the class name ("Rogue"), and everything else under its
   zone, as before. A waiting chain shows its level next to its progress: `2/5 (35)`.
6. **How a quest starts**, on its Journal page: "Handed in directly: this quest never appears in the
   quest log" (`ac`) or "Starts from <item>" (`si`). A hand-in quest is logged as done in the Timeline,
   and its text is captured as usual (`QUEST_COMPLETE`).

Later:
- **Map pins for leads** where we know the ender's position (EG Link `npcs.json` positions, CC BY).
- **Level ladder view.** A saga page laid out by level, with nodes done / in progress / available / waiting /
  unseen.
- **Leads from objective items.** A rare item that a quest with no known giver asks for, e.g. the
  letter you carry to the NPC. Needs a rarity rule so common items (linen, potions) don't count.

## LLM first pass (built 2026-11-19; not run yet)

Hand-linking 922 chains isn't realistic, so an LLM drafts and a person approves. The risk is the
reviewer reading spoilers, so the review is built so that approving doesn't mean reading.

1. **Candidates** (`pipeline/saga_candidates.py`, **built**): scores pairs of chains (and standalone
   quests) on cheap signals: a `start_item` or `items` link between them, a link the splitter cut, a
   shared quest giver or ender, the same class category, and rare names. A name is a capitalised word
   that never appears in lower case in any quest text (so "Xelthos", not "Talisman"), and it's rare when
   4 units or fewer mention it. Either a name from one unit's titles appears in the other's text, or both
   texts mention it. The text is read from the submodules and never written out. Writes
   `pipeline/out/saga_candidates.json` and `.md` (IDs, titles, scores, the names that matched).
   First run: 3,777 scored pairs, 632 with score 4+, in 235 groups (largest 35). This cuts the LLM's work
   from ~4 million possible pairs to a few thousand.
   - It found the Horn chain + the hand-in Eye of Bhossca + "Goblin Lockpicks" (78270, level 23,
     added to the saga). It did **not** link the Horn chain to "Fool Me Twice": our text sources
     don't show the reference (it may be in mail text, or in text EG Link and Spoken don't have). That's
     the case the LLM pass (and text captured in game) has to catch.
2. **Draft** (`pipeline/draft_sagas.py`, **built**). `prepare` turns each candidate group into one
   request, plus one per class and era (e.g. "Rogue, Forever"), because the class signal alone is
   too weak for a candidate pair but a class's own story is the main case. Groups inside a bigger
   group are dropped. First run: 234 requests (215 candidate groups, 19 class groups), about
   1.2M input tokens, **estimated ~$8 as batches** with `claude-opus-5-5` (~$15 one at a time).
   Each request holds the units' quests in step order with their text: EG Link description,
   objectives, completion, and Spoken accept/complete. The text is private pipeline input; it goes
   to the API and `pipeline/out/sagas/` only. The model answers in a fixed JSON schema (structured
   outputs; unit and quest IDs are limited to the group's own): sagas with units in story order,
   links (`continues` / `references` / `same_cast` / `unlocked_by`), confidence, evidence quest IDs,
   `reason` (may spoil) and `reason_safe` (200 characters, for someone who hasn't played).
   The prompt says a wrong link is worse than a missed one.
3. **Spoiler check**, same script. Each `reason_safe` goes back with the quest text and one question:
   does this reveal how anything turns out? If it does, the model rewrites the line from its full
   reason and the check runs again (two rewrites at most). A line that still fails is hidden on the
   review page.
   - `run` sends what's due as Message Batches (half price, usually within an hour) and collects
     them on the next `run` (or `--wait`). `--sync` sends requests one at a time for a pilot
     (`--only <request id>`, `--limit N`). Batches can't use refusal fallbacks, so a refused
     request stops being resent; `run --sync --retry-refused` resends it with server-side fallbacks.
     State is in `pipeline/out/sagas/state.json`, so every step can be resumed.
4. **Review page**, `/sagas` in the chain viewer (`uv run pipeline/chain_viewer.py`). Nothing on it
   spoils by default:
   - Chain titles show only for chains you've played. Start the viewer with
     `--wtf <WTF/Account/…/SavedVariables/Plotline.lua>`; the add-on now saves the character's
     completed quest IDs at logout (`PlotlineCharDB.completed`). "Show titles" reveals the rest for one draft.
   - Each draft shows its confidence, the cheap signals behind it, how many of its chains you've
     played, the links ("3 refers back to 1"), and the spoiler-checked line.
   - **Safe to approve blind**: high confidence plus two or more kinds of cheap signal (class doesn't
     count).
   - The full reason is behind a button with a warning.
   - Sorted with chains you've fully played first, then by confidence and size. Filters: undecided,
     played, blind-safe, later, approved, rejected.
   - Approve / reject / later go to `pipeline/review/sagas.json` (committed; IDs, links and our
     verdict only). A draft's ID is a hash of its units, so the same proposal in a later run
     keeps its verdict and a rejected one doesn't come back as new.
5. **Apply.** `draft_sagas.py apply` writes approved drafts into `Data/Sagas.lua`, between
   `BEGIN/END LLM SAGAS` markers, with `source = "llm"` and the confidence. Running it again replaces
   the block. A draft that overlaps a hand-written saga is skipped and named, so hand-written
   entries win. To take over an LLM entry, move it above the markers.

Checked without the API: the requests build (schemas valid, the Rogue class group holds the Horn
chain, both loose quests and Fool Me Twice), and the state machine, review page and `apply` work on
mock answers. Nothing has been sent to the API yet.

The same requests could also propose tiers and teasers for the chains they read (the tagging pass
in CLAUDE.md step 4). Share the run; keep the outputs separate.

## Status

- [x] Plan (this page)
- [x] Pipeline: `si`, `ac`, chain `cat`; class rules from the class category (100 class quests had
  no class mask, the Forever Rogue ones among them); rules for quests outside chains too;
  `start_item` links as saga evidence; saga candidates report; overlay check in `build_addon_data.py`
- [x] Overlay `Data/Sagas.lua` with the Forever Rogue saga (hand-written)
- [x] Add-on: saga line, waiting state, level-up reminder (setting), Leads (bags and mail),
  class grouping, hand-in-only note
- [x] Logic checked outside the game: the new code compiles as Lua 5.1, and with a stubbed game API
  on the real data the waiting level, saga line, mail lead and level-up reminders behave as designed
- [ ] In-game check (see `docs/REVIEW.md` #20 to #23)
- [x] `draft_sagas.py` + spoiler check + viewer review page + `apply` (checked on mock answers)
- [ ] First real run: a `--sync` pilot on the Rogue class group, then the full batch (~$8)
- [ ] Map pins for leads, level ladder, objective-item leads

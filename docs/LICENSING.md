# Licensing

Plotline is a public repository, so every file in it has to be ours to publish. This page
records the rules and the reasons behind them. Read it before you add data, art or text.

## Our own work

- **Code** (the add-on and the pipeline): GPL-3.0-or-later. See [`LICENSE`](../LICENSE).
- **Overlay data we write** (chain tiers, teasers, tags, notes): GPL-3.0-or-later, the
  same as the code, so the two can ship together.
- **Exception:** `addon/Plotline/Data/Places.lua` is CC BY-SA 4.0, not GPL (see "Area backgrounds").

## Never commit

| What | Why |
|---|---|
| Quest text, gossip, books, any in-game prose | © Blizzard Entertainment. Nobody can license it to us. Quest text ships only in the separate text pack, built at release time (see "The quest text pack" below). |
| Spoken's `QuestText.lua`, `Compendium.lua` or any extract of them | Blizzard text. Spoken's MIT grant covers its code only (its `THIRD_PARTY.md` says so). |
| Spoken_Bosses prose, and Spoken_Places prose outside `Data/Places.lua` | Bosses: rewritten from Blizzard's Adventure Guide and Warcraft Wiki. Places: only the wiki-sourced zone and subzone text ships, in its own CC BY-SA file (see "Area backgrounds"). Use the rest as context for drafting and never reproduce it. |
| Blizzard art (`.blp`/`.tga` files cut from the client) | Blizzard's. Reference the game's own textures by path at runtime, e.g. `Interface\QuestFrame\...`, and don't copy the files. |
| `addon/Plotline_QuestText/QuestText.lua` | The quest text pack's data: Blizzard's text. Built by `pipeline/build_quest_text.py` and git-ignored. It goes into release packages and nowhere else. |
| Raw pipeline output (`pipeline/out/`) | It contains quest titles and data derived from QuestieDB. Ignored by `.gitignore`. |
| Third-party files copied into this repo (QuestieDB, spoken-wow, EG Link) | They come in as git submodules under `pipeline/sources/`. The repo records only each one's URL and commit, which publishes none of their content. Don't copy their files out into tracked paths. |

`.gitignore` blocks the usual paths, but it's only a safety net. Before you commit anything
generated, check it.

## Third-party sources

### QuestieDB — github.com/Questie/QuestieDB

Offline pipeline input only. Plotline doesn't depend on it at runtime (decided 2026-11-18).

Its licensing is **not** a clean GPL-3.0. According to its `LICENSE.md` (read 2026-11-18):

- Content imported from Questie is under Questie's licensing.
- Historic contributions were never licensed. "When in doubt consider QuestieDB content …
  as 'all rights reserved'."
- The Questie team is fine with copying under GPLv3 terms but "can not promise all
  contributors are". They're collecting consent from contributors.
- The Questie name and logo aren't covered. **Don't name or brand Plotline after Questie.**

**What this means for us:** Plotline ships its own chain data, built offline: per-chain lists
of quest IDs, which are facts about the game that our pipeline reorganised, not copies of
QuestieDB's rows. To keep exposure low, we prefer EG Link (CC BY 4.0) for the links we ship and
use QuestieDB mainly to cross-check them. Before the first release:

- [ ] Count how many shipped chain links rely on QuestieDB alone (no EG Link or other support).
      For those, either drop them, confirm them in-game, or ask the Questie team for permission.
- [ ] Check QuestieDB's `LICENSE.md` again in case it has changed.
- [ ] Credit QuestieDB in the README (done) and in the shipped add-on.

### Spoken — github.com/rusty-key/spoken-wow

Never a runtime dependency. Its code is MIT, and its game text and lore prose aren't (see the
table above). From it we keep quest IDs, `prev` links and coverage counts. Its quest text
(Blizzard's, from vmangos) fills gaps in the text pack, mostly descriptions for Classic
quests, and is credited in the pack's `NOTICE.md`. Its lore prose is never used, except the area backgrounds below.

### Area backgrounds (Spoken_Places, from Warcraft Wiki)

Decided 2026-11-19: the Journal's Places pages show the zone and subzone story that Spoken
Places reads when you enter an area. `pipeline/build_places.py` writes it to
`addon/Plotline/Data/Places.lua`, which is committed and shipped.

- **Licence:** the text is from [Warcraft Wiki](https://warcraft.wiki.gg) under
  [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/), adapted by Spoken (page intros,
  post-vanilla sentences removed). Share-alike means our copy is CC BY-SA 4.0 too, so `Places.lua`
  is its own file under that licence, with an SPDX line and a licence notice in its header.
  The add-on code that reads it stays GPL: the two are shipped side by side, not merged.
- **Attribution:** every entry keeps its wiki page, and the Journal prints "From Warcraft Wiki,
  "<page>", adapted by Spoken. CC BY-SA 4.0." under the text. The README credits it too.
- **Only wiki-sourced entries ship.** Spoken's entries with no source (84 today, including the
  Forever-only zones Zephras Isle, Darkspear Islands, Riverglades, Shen'dralas and Mount Hyjal)
  are prose Spoken wrote itself. Its MIT grant doesn't cover prose, so they stay out unless its
  author licenses them.
- **Don't edit the file by hand.** Fix the source (Spoken) or the script, and regenerate.
- **Keep it apart from our writing.** Don't paste or paraphrase this text into teasers, tags or
  other overlay data: that would make those an adaptation under share-alike. Using it as context
  for the LLM drafts is still fine as long as the drafts don't reproduce it.
- **Residual risk:** wiki intros sometimes echo Blizzard's own zone descriptions. The wiki publishes
  them under CC BY-SA, and Spoken ships the same text; if Blizzard objects, drop the entry.

### EG Link output — github.com/JIVESCORP/eg-link-output-wowf

Examined 2026-11-18. Our preferred source for chain links, and our main source for quest text
as pipeline input.

- **License:** CC BY 4.0, covering Efficient Games' compilation and players' observations. Its
  README says the game's names and text stay Blizzard's, with no rights granted in them. So
  links, IDs, race masks, levels and reward IDs ship in the core data. The text ships only in the
  text pack, where EG Link is the first source.
- **Attribution required** wherever the data ships (README, and the add-on's credits/about text),
  and we must say we changed it:
  > Data from [Efficient Games](https://efficient.games), licensed under
  > [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). Reorganised into quest chains by Plotline.
- CC BY 4.0 data can be combined with our GPL-3.0 code. The attribution must stay.
- [ ] Add the attribution line to the add-on's in-game credits once there's a place for it.

### Libraries we may embed

LibStub (public domain), CallbackHandler-1.0 and Ace3 (Ace3 license, BSD-style), LibDBIcon
(public domain per its project page). When you embed one, put its upstream license text in
the same folder.

## The quest text pack (decided 2026-11-19)

Plotline ships Blizzard's quest text in a separate, optional add-on, `Plotline_QuestText`. How it
fits with the other data is in [`DATA.md`](DATA.md).

**The position:** nobody grants us rights in this text, and we claim none. Spoken (2.8 MB of
quest text in its repo and on CurseForge), pfQuest (a full VMaNGOS quest database) and Questie
(names and objectives) all do the same: free add-ons that ship game text labelled as Blizzard's,
relying on Blizzard's long-standing tolerance of this. This is a risk we accept, not a permission
we hold. Blizzard's UI add-on policy (2009) is about add-ons being free, with visible code and no
ads, and as far as we know it neither grants nor forbids shipping game text. Worst case is a
takedown (DMCA to GitHub or CurseForge). WoW Forever is a current product, so Blizzard's attitude
may differ from the one it shows to Classic-era data.

**How we contain it:**

- **A separate add-on.** `Plotline` itself holds nothing of Blizzard's, so its GPL licence stays
  true. A takedown hits only the pack, and Plotline works without it.
- **Never committed.** `QuestText.lua` is built from the submodules at release time
  (`pipeline/build_quest_text.py`). The repo holds only the pack's `.toc` and `NOTICE.md`.
- **Labelled** in the data file's header, the `.toc` and `NOTICE.md`: © Blizzard, not under our
  licence, with sources and a way to ask for removal (a GitHub issue).
- **EG Link first**, so most of the pack comes from a compilation we're licensed to use (CC BY 4.0,
  attributed). Spoken only fills gaps.
- **No player data.** EG Link drops any text that names a player.
- **Text stays out of everything else.** Core data, the overlay and teasers never hold or quote it.

Before a release that includes the pack:

- [ ] `NOTICE.md` is in the package, and the CurseForge/Wago description says the pack contains
      Blizzard's quest text.
- [ ] The pack and `Chains.lua` are built from the same submodule commits.
- [ ] Read Blizzard's current add-on policy again. It couldn't be fetched on 2026-11-19 (blocked
      in that session's network), so the position above relies on what we already knew of the 2009 text.
- [ ] Read CurseForge's and Wago's upload terms on third-party content.

## Teasers and the LLM drafts

An LLM drafts teasers and tags from quest text. Treat a draft as our own writing only if it
paraphrases. It must not quote quest text. The spoiler-check pass should also reject any
teaser that copies a phrase of five or more words from its source text.

## Fan-work notice

Plotline is a fan work. It isn't affiliated with, endorsed by or sponsored by Blizzard
Entertainment. World of Warcraft is a trademark of Blizzard Entertainment, Inc.

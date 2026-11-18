# Licensing

Plotline is a public repository, so every file in it has to be ours to publish. This page
records the rules and the reasons behind them. Read it before you add data, art or text.

## Our own work

- **Code** (the add-on and the pipeline): GPL-3.0-or-later. See [`LICENSE`](../LICENSE).
- **Overlay data we write** (chain tiers, teasers, tags, notes): GPL-3.0-or-later, the
  same as the code, so the two can ship together.

## Never commit

| What | Why |
|---|---|
| Quest text, gossip, books, any in-game prose | © Blizzard Entertainment. Nobody can license it to us. |
| Spoken's `QuestText.lua`, `Compendium.lua` or any extract of them | Blizzard text. Spoken's MIT grant covers its code only (its `THIRD_PARTY.md` says so). |
| Spoken_Places / Spoken_Bosses prose | Derived from Warcraft Wiki under CC BY-SA 4.0. Share-alike would conflict with how we license teasers. Use it as context for drafting and never reproduce it. |
| Blizzard art (`.blp`/`.tga` files cut from the client) | Blizzard's. Reference the game's own textures by path at runtime, e.g. `Interface\QuestFrame\...`, and don't copy the files. |
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

Offline pipeline input only, never a runtime dependency. Its code is MIT, and its game text
and lore prose aren't (see the table above). From it we keep quest IDs, `prev` links and
coverage counts, never prose.

### EG Link output — github.com/JIVESCORP/eg-link-output-wowf

Examined 2026-11-18. Our preferred source for chain links, and our main source for quest text
as pipeline input.

- **License:** CC BY 4.0, covering Efficient Games' compilation and players' observations. Its
  README says the game's names and text stay Blizzard's, with no rights granted in them. So:
  links, IDs and race masks may ship; the text is pipeline input only, like Spoken's.
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

## Teasers and the LLM drafts

An LLM drafts teasers and tags from quest text. Treat a draft as our own writing only if it
paraphrases. It must not quote quest text. The spoiler-check pass should also reject any
teaser that copies a phrase of five or more words from its source text.

## Fan-work notice

Plotline is a fan work. It isn't affiliated with, endorsed by or sponsored by Blizzard
Entertainment. World of Warcraft is a trademark of Blizzard Entertainment, Inc.

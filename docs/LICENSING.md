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
| Third-party clones (QuestieDB, spoken-wow, EG Link) | They're pipeline input only. Clone them locally. |

`.gitignore` blocks the usual paths, but it's only a safety net. Before you commit anything
generated, check it.

## Third-party sources

### QuestieDB — github.com/Questie/QuestieDB

Plotline needs it at runtime for chain structure, and the offline pipeline reads it as input.

Its licensing is **not** a clean GPL-3.0. According to its `LICENSE.md` (read 2026-11-18):

- Content imported from Questie is under Questie's licensing.
- Historic contributions were never licensed. "When in doubt consider QuestieDB content …
  as 'all rights reserved'."
- The Questie team is fine with copying under GPLv3 terms but "can not promise all
  contributors are". They're collecting consent from contributors.
- The Questie name and logo aren't covered. **Don't name or brand Plotline after Questie.**

**What this means for us:** the smallest exposure is to read chain structure from QuestieDB
at runtime and ship only our overlay (chain slug → tier, teaser, tags, plus a list of quest
IDs). A per-chain list of quest IDs is a small set of facts we've reorganised, not a copy of
QuestieDB's rows. Before the first release:

- [ ] Decide whether the shipped add-on carries generated chain lists (`chains[...]`) or
      builds them from QuestieDB at load time. The second option ships nothing derived
      from Questie.
- [ ] Check QuestieDB's `LICENSE.md` again in case it has changed.
- [ ] Credit QuestieDB in the README and in the TOC notes.

### Spoken — github.com/rusty-key/spoken-wow

Offline pipeline input only, never a runtime dependency. Its code is MIT, and its game text
and lore prose aren't (see the table above). From it we keep quest IDs, `prev` links and
coverage counts, never prose.

### EG Link output — github.com/JIVESCORP/eg-link-output-wowf

CC BY 4.0. Not examined yet. If we use it, data under CC BY 4.0 needs attribution and is
compatible with GPL-3.0 output. The game text it contains is still Blizzard's.

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

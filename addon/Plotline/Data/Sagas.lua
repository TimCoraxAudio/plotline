-- SPDX-License-Identifier: GPL-3.0-or-later
-- Plotline overlay: sagas, storylines that run across several chains (docs/STORYLINES.md).
-- Hand-edited; survives regeneration. IDs only: names are quest titles the game looks up (n),
-- so no Blizzard text is written here. Chain IDs are the slugs in Data/Chains.lua;
-- build_addon_data.py warns when one no longer exists.
--
-- sagas[id] = {
--   n = quest whose title names the saga,
--   class = class ID it belongs to (optional; the Journal files it under that class),
--   parts = { { chain = "<chain id>" } or { quest = <quest ID> }, ... } in story order,
--   links = { { from = part, to = part, kind = "continues" | "references" | "same_cast" | "unlocked_by" } },
--   source = "human" | "llm" (an LLM draft a person approved),
-- }

local _, ns = ...
ns.overlay = ns.overlay or {}

ns.overlay.sagas = {
    -- Forever's Rogue class story, levels 23 to 50. Its quests refer to each other, but no quest
    -- link joins the chains. Several start from a letter or an item rather than an NPC.
    ["rogue-forever"] = {
        n = 78261,
        class = 4,
        parts = {
            { chain = "the-horn-of-xelthos-78261" },
            { quest = 78270 },   -- level 23; shares rare names with the first chain (saga_candidates.py).
                                 -- Where it sits in the story is unchecked.
            { quest = 78699 },   -- hand-in only (never in the quest log)
            { chain = "fool-me-twice-80526" },
        },
        links = {
            { from = 1, to = 4, kind = "references" },
        },
        source = "human",
    },
}

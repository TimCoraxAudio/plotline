# SPDX-License-Identifier: GPL-3.0-or-later
"""Splitter rules: decide which merged links are real chain steps.

The merge joins any two quests that some source says follow each other, so a
few stray links glue unrelated storylines into one huge chain. These rules
remove those links (and say why), so the viewer and the report can show every
decision. See CLAUDE.md, "Breakdown findings", for the evidence behind them.

Rules, applied in this order:
  incompatible  no single character can take both quests (race or class masks)
  category      a link between a class/profession/season quest group and anything
                outside that group (any source: breadcrumbs from a zone story into
                a profession tutorial are real, but the tutorial is its own chain)
  cross_zone    a trace-only link between quests in different zones
  turn_in       a quest's fan of leaf quests, mostly class-restricted (armour
                turn-ins): kept with the chain as rewards, not as steps
Same-title variants at the same depth are then grouped into one step.
"""
import collections

# PlayableRaceBit. Bits 32 and 33 are Forever's Skyborne (Alliance and Horde).
RACES = {0: "Human", 1: "Orc", 2: "Dwarf", 3: "Night Elf", 4: "Undead", 5: "Tauren",
         6: "Gnome", 7: "Troll", 32: "Skyborne (A)", 33: "Skyborne (H)"}
ALLIANCE = sum(1 << b for b in (0, 2, 3, 6, 32))
HORDE = sum(1 << b for b in (1, 4, 5, 7, 33))
PLAYABLE = ALLIANCE | HORDE
# Class masks use class id - 1.
CLASSES = {0: "Warrior", 1: "Paladin", 2: "Hunter", 3: "Rogue", 4: "Priest", 6: "Shaman",
           7: "Mage", 8: "Warlock", 10: "Druid"}
ALL_CLASSES = sum(1 << b for b in CLASSES)
QUEST_SORT = {61: "Warlock", 81: "Warrior", 82: "Shaman", 141: "Paladin", 161: "Mage",
              162: "Rogue", 261: "Hunter", 262: "Priest", 263: "Druid", 24: "Herbalism",
              101: "Fishing", 121: "Blacksmithing", 181: "Alchemy", 182: "Leatherworking",
              201: "Engineering", 264: "Tailoring", 304: "Cooking", 324: "First Aid",
              22: "Seasonal", 284: "Special", 221: "Treasure Map", 666: "Camping (Forever)"}

FAN_MIN = 5            # a quest needs this many leaf children to count as a turn-in fan
FAN_CLASS_SHARE = 0.8  # ...and this share of them class-restricted
TRACE_ONLY = {"traces"}


def bits(mask):
    return [b for b in range(64) if mask >> b & 1]


def race_mask(g, q):
    """Race mask, or None for anyone. EG Link when it restricts the quest, else
    Spoken, else QuestieDB. EG reports every race (ffff...) for about 4,000
    quests, faction-only ones included, so that value is not evidence."""
    r = g.eg.get(q, {}).get("raceMask")
    if r:
        m = int(r, 16) & PLAYABLE
        if m and m != PLAYABLE:
            return m
    for m in (g.spoken.get(q, {}).get("races"), g.base.get(q, {}).get("races")):
        if m and m & PLAYABLE and m & PLAYABLE != PLAYABLE:
            return m & PLAYABLE
    return None


def class_mask(g, q):
    for m in (g.spoken.get(q, {}).get("classes"), g.base.get(q, {}).get("classes")):
        if m and m & ALL_CLASSES and m & ALL_CLASSES != ALL_CLASSES:
            return m & ALL_CLASSES
    return None


def category(g, q):
    """The QuestSort (or season word) a quest is filed under, or None for a zone quest."""
    s = g.spoken.get(q, {}).get("sort")
    if s:
        return s
    zs = g.base.get(q, {}).get("zoneOrSort")
    if isinstance(zs, (int, float)) and zs < 0:
        return int(-zs)
    return g.eg.get(q, {}).get("category")


def zones(g, q):
    return set(g.spoken.get(q, {}).get("zones", []))


def faction(m):
    if m is None:
        return "any"
    names = ", ".join(RACES.get(b, f"bit{b}") for b in bits(m))
    if m & ALLIANCE and not m & HORDE:
        return "Alliance" if m == ALLIANCE else f"Alliance: {names}"
    if m & HORDE and not m & ALLIANCE:
        return "Horde" if m == HORDE else f"Horde: {names}"
    return f"mixed: {names}"


def class_names(m):
    return [CLASSES[b] for b in bits(m) if b in CLASSES] if m else []


def split(g):
    """Returns (kept, removed, turnins).
    kept:    {(prev, next): edge info} for links that stay chain steps
    removed: [{"from", "to", "rule", "sources"}] for every link dropped
    turnins: {parent quest: [leaf quests]} for turn-in fans"""
    races = {}
    classes = {}

    def rm(q):
        if q not in races:
            races[q] = race_mask(g, q)
        return races[q]

    def cm(q):
        if q not in classes:
            classes[q] = class_mask(g, q)
        return classes[q]

    kept, removed = {}, []
    for (p, n), e in g.seq.items():
        rule = None
        trace_only = e["sources"] <= TRACE_ONLY
        if (rm(p) and rm(n) and not rm(p) & rm(n)) or (cm(p) and cm(n) and not cm(p) & cm(n)):
            rule = "incompatible"
        elif category(g, p) != category(g, n):
            rule = "category"
        elif trace_only and zones(g, p) and zones(g, n) and not zones(g, p) & zones(g, n):
            rule = "cross_zone"
        if rule:
            removed.append({"from": p, "to": n, "rule": rule, "sources": sorted(e["sources"])})
        else:
            kept[(p, n)] = e

    out_adj, in_deg = collections.defaultdict(list), collections.Counter()
    for p, n in kept:
        out_adj[p].append(n)
        in_deg[n] += 1
    turnins = {}
    for p, children in out_adj.items():
        leaves = [c for c in children if not out_adj.get(c) and in_deg[c] == 1]
        if len(leaves) >= FAN_MIN and sum(1 for c in leaves if cm(c)) >= FAN_CLASS_SHARE * len(leaves):
            turnins[p] = sorted(leaves)
            for c in leaves:
                del kept[(p, c)]
                removed.append({"from": p, "to": c, "rule": "turn_in",
                                "sources": sorted(g.seq[(p, c)]["sources"])})
    return kept, removed, turnins


def steps(members, edges, names):
    """Group a chain into steps: quests at the same longest-path depth, with
    same-title quests (race/class variants) merged into one entry.
    Returns (steps, depth, has_cycle)."""
    out_adj = collections.defaultdict(list)
    deg = {m: 0 for m in members}
    for p, n in edges:
        out_adj[p].append(n)
        deg[n] += 1
    depth = {m: 0 for m in members}
    queue = [m for m in members if deg[m] == 0]
    seen = 0
    while queue:
        m = queue.pop()
        seen += 1
        for n in out_adj[m]:
            depth[n] = max(depth[n], depth[m] + 1)
            deg[n] -= 1
            if deg[n] == 0:
                queue.append(n)
    layers = collections.defaultdict(lambda: collections.defaultdict(list))
    for m in sorted(members):
        layers[depth[m]][names.get(m) or str(m)].append(m)
    out = [[{"title": t, "quests": qs} for t, qs in sorted(layers[d].items(), key=lambda kv: kv[1][0])]
           for d in sorted(layers)]
    return out, depth, seen < len(members)

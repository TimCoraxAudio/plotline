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
  weak_sibling  at a fork with a well-backed link (2+ sources and an NPC handoff), a
                sibling link that only Spoken or only player traces claim, with no
                handoff (QuestieDB-only ones are kept and flagged as checks)
  turn_in       a quest's fan of leaf quests, mostly class-restricted (armour
                turn-ins): kept with the chain as rewards, not as steps
  branch /      at a fork, the main line is the group of children that meet again
  side_quest    later (or else the longest branch); other groups whose first quest has
                no other way in (but from quests that feed only it) become their own
                chain ("branch", marked as branching from the fork quest) or, for a
                single quest, a side quest kept with the fork quest. Faction or class
                alternatives of the main line (including same-title versions) are
                never split off.
Same-title variants at the same depth are then grouped into one step. A quest with
no link into it (EG Link only records "next quest") takes the step of a linked quest
with the same title and the same next quests: Forever often re-issues a Classic
quest under a new ID, and only the old ID has a recorded "from" link.
"""
import collections, functools, operator, types

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

FOREVER_MIN_ID = 30000  # Classic quest IDs are all below 10000, Forever's all 60000 and up
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


def era(q):
    return "forever" if q >= FOREVER_MIN_ID else "classic"


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


def handoff(g, p, n):
    """True if quest n is picked up from an NPC or object that quest p is handed in
    to, False if both are known and differ, None if either isn't known (QuestieDB
    only: Forever-only quests have no NPC data yet)."""
    ends, gives = g.base.get(p, {}).get("enders"), g.base.get(n, {}).get("givers")
    if not ends or not gives:
        return None
    return bool(ends & gives)


def split(g):
    """Decide which merged links are chain steps. Returns a namespace:
    kept:        {(prev, next): edge} links that stay chain steps
    removed:     [{"from", "to", "rule", "sources", ...}] every link taken out, and why
    turnins:     {quest: [leaf quests]} turn-in fans, kept with the quest as rewards
    side_quests: {quest: [quest]} one-quest side branches, kept with the quest
    branches:    [{"from", "to", "how"}] links where a side storyline starts its own chain
    checks:      [{"from", "to", "why"}] links kept but worth a look in the viewer"""
    races, classes = {}, {}

    def rm(q):
        if q not in races:
            races[q] = race_mask(g, q)
        return races[q]

    def cm(q):
        if q not in classes:
            classes[q] = class_mask(g, q)
        return classes[q]

    def drop(p, n, rule, **extra):
        removed.append({"from": p, "to": n, "rule": rule, "sources": sorted(g.seq[(p, n)]["sources"]), **extra})
        kept.pop((p, n), None)

    # --- per-link rules
    kept, removed, checks = {}, [], []
    for (p, n), e in g.seq.items():
        trace_only = e["sources"] <= TRACE_ONLY
        if (rm(p) and rm(n) and not rm(p) & rm(n)) or (cm(p) and cm(n) and not cm(p) & cm(n)):
            rule = "incompatible"
        elif category(g, p) != category(g, n):
            rule = "category"
        elif trace_only and zones(g, p) and zones(g, n) and not zones(g, p) & zones(g, n):
            rule = "cross_zone"
        else:
            kept[(p, n)] = e
            continue
        removed.append({"from": p, "to": n, "rule": rule, "sources": sorted(e["sources"])})

    def children():
        out = collections.defaultdict(list)
        for p, n in kept:
            out[p].append(n)
        return out

    # --- weak sibling: at a fork with a well-backed child (2+ sources and an NPC
    # handoff), a link only Spoken or only player traces claim, with no handoff,
    # is dropped. A QuestieDB-only one is a recorded requirement: kept, but flagged.
    for p, kids in list(children().items()):
        if len(kids) < 2:
            continue
        if not any(len(kept[(p, k)]["sources"]) >= 2 and handoff(g, p, k) for k in kids):
            continue
        for k in kids:
            src = kept[(p, k)]["sources"]
            if len(src) == 1 and handoff(g, p, k) is False:
                if src <= {"spoken", "traces"}:
                    drop(p, k, "weak_sibling")
                elif src == {"questie"}:
                    checks.append({"from": p, "to": k, "why": "QuestieDB alone, no NPC handoff, next to a well-backed link"})

    # --- turn-in fans
    out_adj, in_deg = children(), collections.Counter(n for _, n in kept)
    turnins = {}
    for p, kids in out_adj.items():
        leaves = [c for c in kids if not out_adj.get(c) and in_deg[c] == 1]
        if len(leaves) >= FAN_MIN and sum(1 for c in leaves if cm(c)) >= FAN_CLASS_SHARE * len(leaves):
            turnins[p] = sorted(leaves)
            for c in leaves:
                drop(p, c, "turn_in")

    checks = [c for c in checks if (c["from"], c["to"]) in kept]  # not ones that became turn-ins

    # --- side branches. At a fork, children whose storylines meet again later are one
    # group. The main line is the group that rejoins (if exactly one does), else the
    # branch that goes on longest; other groups become side branches. Faction or class
    # alternatives of the main line are never split off.
    side_quests, branches = collections.defaultdict(list), []
    out_adj = children()

    def below(q):
        seen, stack = set(), [q]
        while stack:
            for n in out_adj.get(stack.pop(), ()):
                if n not in seen:
                    seen.add(n)
                    stack.append(n)
        return seen

    memo = {}

    def depth_below(q):
        if q not in memo:
            memo[q] = 0  # guards against cycles
            memo[q] = 1 + max((depth_below(n) for n in out_adj.get(q, ())), default=0)
        return memo[q]

    def mask_union(qs, f):
        ms = [f(q) for q in qs]
        return None if any(m is None for m in ms) else functools.reduce(operator.or_, ms, 0)

    def alternatives(a, b):
        """Two groups of a fork's children that no one character could both take, judged
        by the children themselves: later quests are often shared by both factions."""
        if {g.names.get(k) for k in a} & {g.names.get(k) for k in b}:
            return True  # same-title quests: race/class versions whose masks aren't recorded
        ra, rb = mask_union(a, rm), mask_union(b, rm)
        ca, cb = mask_union(a, cm), mask_union(b, cm)
        return bool((ra and rb and not ra & rb) or (ca and cb and not ca & cb))

    in_from = collections.defaultdict(set)
    for a, b in kept:
        in_from[b].add(a)
    cut = []
    for p in sorted(out_adj):
        kids = sorted(out_adj[p])
        if len(kids) < 2:
            continue
        reach = {k: below(k) | {k} for k in kids}
        groups = []  # children whose storylines meet again
        for k in kids:
            hit = [grp for grp in groups if any(reach[k] & reach[o] for o in grp)]
            merged = [k] + [o for grp in hit for o in grp]
            groups = [grp for grp in groups if grp not in hit] + [merged]
        if len(groups) < 2:
            continue
        rejoining = [grp for grp in groups if len(grp) > 1]
        title = g.names.get(p)
        rank = lambda grp: (max(depth_below(k) for k in grp), len(set().union(*(reach[k] for k in grp))),
                            any(g.names.get(k) == title for k in grp),
                            max(len(kept[(p, k)]["sources"]) for k in grp), -min(grp))
        if len(rejoining) == 1:
            main, how = rejoining[0], "rejoin"
        else:
            main, how = max(rejoining or groups, key=rank), "longest"
        for grp in groups:
            if grp is main or alternatives(main, grp):
                continue
            # a side storyline starts here only if its first quest has no other way in,
            # except from quests that start nothing else (the Chapters that feed "The
            # Green Hills of Stranglethorn"). A quest the main line also leads to (shared
            # by both factions, say) stays put.
            def feeder(x, k):
                return not in_from[x] and set(out_adj.get(x, ())) == {k}
            cut += [(p, k, how) for k in grp if all(feeder(x, k) for x in in_from[k] - {p})]
    for p, k, how in cut:
        kept.pop((p, k), None)
    # what each cut child ends up in, once all cuts are made
    comp = components_of(kept)
    for p, k, how in cut:
        if comp.get(k) is not None and comp.get(k) == comp.get(p):
            kept[(p, k)] = g.seq[(p, k)]  # still joined another way: not a separate storyline
        elif comp.get(k) is None:
            side_quests[p].append(k)
            removed.append({"from": p, "to": k, "rule": "side_quest", "how": how,
                            "sources": sorted(g.seq[(p, k)]["sources"])})
        else:
            branches.append({"from": p, "to": k, "how": how})
            removed.append({"from": p, "to": k, "rule": "branch", "how": how,
                            "sources": sorted(g.seq[(p, k)]["sources"])})
    return types.SimpleNamespace(kept=kept, removed=removed, turnins=turnins,
                                 side_quests={p: sorted(v) for p, v in side_quests.items()},
                                 branches=branches, checks=checks)


def components_of(edges):
    """{quest: component id} for every quest on at least one of these links."""
    parent = {}

    def find(x):
        while parent.setdefault(x, x) != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x
    for p, n in edges:
        parent[find(n)] = find(p)
    return {q: find(q) for q in parent}


def steps(members, edges, names):
    """Group a chain into steps: quests at the same longest-path depth, with
    same-title quests (race/class variants) merged into one entry.
    Returns (steps, depth, has_cycle, anchored quest IDs)."""
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
    # anchor unlinked variants to a linked quest with the same title and next quests
    has_in = {n for _, n in edges}
    linked_depth = collections.defaultdict(list)
    for m in members:
        if m in has_in:
            linked_depth[(names.get(m), frozenset(out_adj[m]))].append(depth[m])
    anchored = []
    for m in sorted(members):
        key = (names.get(m), frozenset(out_adj[m]))
        if m not in has_in and out_adj[m] and key in linked_depth:
            d = max(linked_depth[key])
            if all(depth[c] > d for c in out_adj[m]):
                depth[m] = d
                anchored.append(m)
    layers = collections.defaultdict(lambda: collections.defaultdict(list))
    for m in sorted(members):
        layers[depth[m]][names.get(m) or str(m)].append(m)
    out = [[{"title": t, "quests": qs} for t, qs in sorted(layers[d].items(), key=lambda kv: kv[1][0])]
           for d in sorted(layers)]
    return out, depth, seen < len(members), anchored

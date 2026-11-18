#!/usr/bin/env -S uv run --script
# SPDX-License-Identifier: GPL-3.0-or-later
# /// script
# requires-python = ">=3.10"
# dependencies = ["lupa>=2"]
# ///
"""Break down the oversized chains, to decide how the splitter should cut them.

For each chain of at least --min-size quests: faction and class make-up, zones,
links between quests no single character could both take, hub quests, repeated
titles, and how far some candidate cuts would break the chain up.

Writes pipeline/out/breakdown.md (git-ignored: it holds quest titles).
Run: uv run pipeline/analyze_chains.py
"""
import argparse, collections, os, re, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import merge_chains as mc  # noqa: E402

from split_chains import CLASSES, QUEST_SORT, bits, faction, race_mask  # noqa: E402


def zone_names(spoken_root):
    """uiMapID -> name, from Spoken's API.lua lookup table (names only)."""
    path = os.path.join(spoken_root, "addons", "Spoken", "API.lua")
    try:
        src = open(path, encoding="utf-8").read()
    except OSError:
        return {}
    return {int(k): re.sub(r"(?<=[a-z])(?=[A-Z])", " ", v)
            for k, v in re.findall(r'\[(\d+)\] = "([A-Za-z]+)"', src)}


def components(nodes, edges):
    parent = {n: n for n in nodes}

    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x
    for p, n in edges:
        parent[find(n)] = find(p)
    groups = collections.defaultdict(set)
    for n in nodes:
        groups[find(n)].add(n)
    return sorted(groups.values(), key=len, reverse=True)


def sizes(comps):
    big = [len(c) for c in comps if len(c) > 1]
    solo = sum(1 for c in comps if len(c) == 1)
    return f"{len(big)} chains, largest {big[:8]}, {solo} quests left standalone"


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--questiedb", default=os.path.join(mc.SOURCES, "QuestieDB"))
    ap.add_argument("--spoken", default=os.path.join(mc.SOURCES, "spoken-wow"))
    ap.add_argument("--eglink", default=os.path.join(mc.SOURCES, "eg-link-output-wowf"))
    ap.add_argument("--out", default=os.path.join(mc.HERE, "out"))
    ap.add_argument("--min-trace-conf", type=int, default=0)
    ap.add_argument("--min-size", type=int, default=mc.LARGE_CHAIN)
    a = ap.parse_args()

    g = mc.build_graph(a)
    zones = zone_names(a.spoken)
    nm = lambda q: f"{g.names.get(q)} ({q})"
    all_nodes = {n for e in g.seq for n in e}
    big = [c for c in components(all_nodes, g.seq) if len(c) >= a.min_size]

    L = ["# Oversized chain breakdown\n",
         f"Chains of {a.min_size}+ quests: {len(big)}. Race masks come from EG Link, else Spoken; "
         "'any' means no restriction recorded.\n"]
    summary = []
    for members in big:
        edges = [(p, n) for (p, n) in g.seq if p in members]
        out_deg, in_deg = collections.Counter(p for p, _ in edges), collections.Counter(n for _, n in edges)
        root = min(members, key=lambda m: (in_deg[m] > 0, m))
        races = {q: race_mask(g, q) for q in members}
        cls = {q: g.spoken.get(q, {}).get("classes") for q in members}
        sorts = {q: g.spoken.get(q, {}).get("sort") for q in members}

        # links no single character can follow
        race_x = [(p, n) for p, n in edges if races[p] and races[n] and not races[p] & races[n]]
        class_x = [(p, n) for p, n in edges if cls[p] and cls[n] and not cls[p] & cls[n]]
        incompatible = set(race_x) | set(class_x)

        hubs = sorted(members, key=lambda m: -(out_deg[m] + in_deg[m]))[:8]
        hub_set = {m for m in members if out_deg[m] >= 5 or in_deg[m] >= 5}
        titles = collections.Counter(g.names.get(q) for q in members)
        repeated = [(t, c) for t, c in titles.most_common() if c > 1]

        L.append(f"## {nm(root)}: {len(members)} quests, {len(edges)} links\n")
        src = collections.Counter(s for e in edges for s in g.seq[e]["sources"])
        L.append(f"- Link sources: {dict(src.most_common())}")
        fac = collections.Counter(faction(races[q]) for q in members)
        L.append(f"- Factions: {dict(fac.most_common(6))}")
        cc = collections.Counter(CLASSES.get(b, f"bit{b}") for q in members if cls[q] for b in bits(cls[q]))
        sc = collections.Counter(QUEST_SORT.get(s, str(s)) for s in sorts.values() if s)
        L.append(f"- Class-restricted quests: {sum(1 for q in members if cls[q])} {dict(cc.most_common())}")
        L.append(f"- Filed under a QuestSort (class/profession/season): {dict(sc.most_common(8))}")
        zc = collections.Counter(zones.get(z, str(z)) for q in members for z in g.spoken.get(q, {}).get("zones", []))
        L.append(f"- Zones (Spoken uiMap): {dict(zc.most_common(8))}")
        L.append(f"- New Forever quests: {sum(1 for q in members if q in g.delta)}; "
                 f"EG Link only: {sum(1 for q in members if q in g.eg_only)}")
        L.append(f"- Links between race-incompatible quests: {len(race_x)}; class-incompatible: {len(class_x)}")
        for p, n in list(race_x)[:4]:
            L.append(f"    - {nm(p)} [{faction(races[p])}] -> {nm(n)} [{faction(races[n])}] "
                     f"via {sorted(g.seq[(p, n)]['sources'])}")
        L.append(f"- Repeated titles: {len(repeated)} titles cover {sum(c for _, c in repeated)} quests; "
                 f"top {repeated[:5]}")
        L.append("- Hubs (out / in links):")
        for h in hubs:
            L.append(f"    - {nm(h)}: {out_deg[h]} out / {in_deg[h]} in, {faction(races[h])}")

        keep = [e for e in edges if e not in incompatible]
        c1 = components(members, keep)
        c2 = components(members, [e for e in keep if e[0] not in hub_set and e[1] not in hub_set])
        c3 = components(members, [e for e in keep if g.seq[e]["sources"] - {"traces"}])
        L.append("- Candidate cuts:")
        L.append(f"    - drop incompatible links ({len(incompatible)}): {sizes(c1)}")
        L.append(f"    - ...and cut at hubs with 5+ links ({len(hub_set)} hubs): {sizes(c2)}")
        L.append(f"    - ...or instead drop links only player traces support: {sizes(c3)}")
        L.append("")
        summary.append((g.names.get(root), len(members), len(incompatible), len(hub_set),
                        len(c1[0]), len(c2[0]), len(c3[0])))

    L.append("## Summary\n")
    L.append("| Chain | Size | Incompatible links | Hubs | Largest after dropping incompatible | ...and hub cut | ...or traces dropped |")
    L.append("|---|---|---|---|---|---|---|")
    for row in summary:
        L.append("| " + " | ".join(map(str, row)) + " |")
    os.makedirs(a.out, exist_ok=True)
    path = os.path.join(a.out, "breakdown.md")
    open(path, "w", encoding="utf-8").write("\n".join(L) + "\n")
    print("\n".join(L[-(len(summary) + 3):]))
    print(f"\nFull breakdown: {path}")


if __name__ == "__main__":
    main()

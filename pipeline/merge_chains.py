#!/usr/bin/env -S uv run --script
# SPDX-License-Identifier: GPL-3.0-or-later
# /// script
# requires-python = ">=3.10"
# dependencies = ["lupa>=2"]
# ///
"""Merge quest-chain data for Plotline's offline pipeline.

Inputs (git submodules under pipeline/sources/, nothing is downloaded):
  --questiedb  github.com/Questie/QuestieDB
  --spoken     github.com/rusty-key/spoken-wow
  --eglink     github.com/JIVESCORP/eg-link-output-wowf

Outputs (to --out):
  chains.json   chains + standalone IDs. Names and IDs only, no quest text.
  report.md     sizes, coverage, mega-chain breakdown, source disagreements

Run: uv run pipeline/merge_chains.py   (after: git submodule update --init)
"""
import argparse, collections, glob, json, os, re, statistics, sys, types

from lupa import LuaRuntime

LUA = LuaRuntime(unpack_returned_tuples=True)
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import split_chains  # noqa: E402
LARGE_CHAIN = 25  # chains at least this long are flagged for manual splitting
HERE = os.path.dirname(os.path.abspath(__file__))
SOURCES = os.path.join(HERE, "sources")


# ---------------------------------------------------------------- loaders
def lua_list(v):
    """Lua table or None -> list of positive ints."""
    if v is None:
        return []
    if isinstance(v, (int, float)):
        return [int(v)] if v > 0 else []
    out = []
    for x in v.values():
        if isinstance(x, (int, float)) and x > 0:
            out.append(int(x))
    return out


def npc_set(v):
    """Questie startedBy/finishedBy {{creatures}, {objects}, ...} -> {"c<id>", "o<id>"}."""
    out = set()
    if v is None:
        return out
    for slot, tag in ((1, "c"), (2, "o")):
        out |= {f"{tag}{i}" for i in lua_list(v[slot])}
    return out


def load_questie_base(root):
    path = os.path.join(root, "data", "Forever", "foreverQuestDB.lua")
    src = open(path, encoding="utf-8").read()
    head, body = src.split("QuestieDB.questData = [[", 1)
    keys = {m.group(1): int(m.group(2))
            for m in re.finditer(r"\['(\w+)'\] = (\d+),", head)}
    body = body.split("]]", 1)[0]
    data = LUA.execute(body)
    quests = {}
    for qid in data.keys():
        row = data[qid]
        g = lambda k: row[keys[k]]
        nxt = g("nextQuestInChain")
        quests[int(qid)] = {
            "name": g("name"),
            "single": lua_list(g("preQuestSingle")),
            "group": lua_list(g("preQuestGroup")),
            "next": int(nxt) if isinstance(nxt, (int, float)) and nxt > 0 else None,
            "zoneOrSort": g("zoneOrSort"),
            "races": int(g("requiredRaces")) if isinstance(g("requiredRaces"), (int, float)) else None,
            "classes": int(g("requiredClasses")) if isinstance(g("requiredClasses"), (int, float)) else None,
            # who gives it and who takes it in: {"c123", "o456"} (creature / object IDs)
            "givers": npc_set(g("startedBy")),
            "enders": npc_set(g("finishedBy")),
        }
    return quests


def load_questie_delta(root, base_ids):
    """New Forever quests: id -> name. 'NYI' placeholders are excluded."""
    path = os.path.join(root, "src", "corrections", "Forever", "generated",
                        "foreverBaseQuest.lua")
    src = open(path, encoding="utf-8").read()
    out = {}
    for m in re.finditer(r"^        \[(\d+)\] = \{ -- (.*?) : https", src, re.M):
        qid, name = int(m.group(1)), m.group(2)
        if qid not in base_ids and not name.startswith("<NYI>"):
            out[qid] = name
    return out


CONF = {"very high": 3, "high": 2, "medium": 1, "low": 0}


def load_traces(root):
    """Relations inferred from player sessions. Commented-out entries are
    still accepted relations (the module just doesn't apply them), so we read
    both. Returns list of (kind, quest, other, confidence)."""
    path = os.path.join(root, "src", "corrections", "Forever", "traces",
                        "foreverQuestRelationTraces.lua")
    edges = []
    cur, conf = None, 2
    for line in open(path, encoding="utf-8"):
        s = line.strip().lstrip("-").strip()
        m = re.match(r"\[(\d+)\] = \{ ", s)
        if m:
            cur = int(m.group(1))
            continue
        m = re.search(r"Assumption: .*?\(([a-z, -]+); (very high|high|medium|low);", s)
        if m:
            conf = CONF[m.group(2)]
            continue
        m = re.match(r"\[questKeys\.(\w+)\] = (.+?),?$", s)
        if m and cur is not None:
            field, val = m.group(1), m.group(2)
            ids = [int(x) for x in re.findall(r"\d+", val)]
            if field in ("preQuestSingle", "preQuestGroup"):
                kind = "single" if field == "preQuestSingle" else "group"
                for p in ids:
                    edges.append((kind, p, cur, conf))
            elif field == "nextQuestInChain" and ids:
                edges.append(("single", cur, ids[0], conf))
    return edges


def load_spoken(root):
    d = os.path.join(root, "addons", "Spoken_Quests", "Data")
    LUA.execute(open(os.path.join(d, "Compendium.lua"), encoding="utf-8").read())
    LUA.execute(open(os.path.join(d, "QuestText.lua"), encoding="utf-8").read())
    comp = LUA.globals()["SpokenQuestsCompendium"]["quests"]
    text = LUA.globals()["SpokenQuestsText"]
    q = {}
    for k in comp.keys():
        r = comp[k]
        zones = list(r["zones"].values()) if r["zones"] else []
        q[int(k)] = {
            "title": r[1],
            "prev": int(r["prev"]) if r["prev"] else None,
            "zones": [int(z) for z in zones],
            "sort": (int(r["sort"]) if isinstance(r["sort"], (int, float)) else r["sort"]) or None,  # may be a word, e.g. a holiday
            "classes": int(r["classes"]) if r["classes"] else None,
            "races": int(r["races"]) if r["races"] else None,  # PlayableRaceBit mask; None = any
            "dungeon": int(r["dungeon"]) if r["dungeon"] else None,
            "name": r["name"],  # chain-name hint on a chain's first quest
            "notext": bool(r["notext"]),
        }
    # Only IDs are kept from the text file: we need coverage, not the prose.
    has_text = {int(k) for k in text.keys()}
    return q, has_text


PLACEHOLDER = re.compile(r"<nyi>|<txt>|<unused>|\(unused\)|\[never used\]|test quest|do not use", re.I)


def build_key(path):
    return [int(x) for x in os.path.basename(os.path.dirname(path)).split(".")]


def load_eglink(root, product="wowf"):
    """Union of every build's quests.enUS.json, newest build winning.
    Keeps IDs, titles (for the report only), links and masks; text only as
    a has-text flag. Placeholder quests (<NYI>, <UNUSED>, tests) are dropped."""
    files = sorted(glob.glob(os.path.join(root, "data", product, "*", "quests.enUS.json")),
                   key=build_key)
    q = {}
    for f in files:
        for k, v in json.load(open(f, encoding="utf-8"))["quests"].items():
            q[int(k)] = {
                "title": v.get("title"),
                "next": v.get("nextQuestId"),
                "raceMask": v.get("raceMask"),
                "zone": v.get("zoneAreaId"),
                "category": v.get("categoryId"),
                "has_text": bool(v.get("description")),
                "build": os.path.basename(os.path.dirname(f)),
                # items the quest asks for, and items it always rewards (not reward choices)
                "needs_items": sorted({o["objectId"] for o in v.get("objectives") or []
                                       if o.get("type") == "item" and o.get("objectId")}),
                "gives_items": sorted({i["itemId"] for i in (v.get("rewards") or {}).get("items") or []
                                       if i.get("itemId")}),
            }
    dropped = {i for i, r in q.items() if not r["title"] or PLACEHOLDER.search(r["title"])}
    return {i: r for i, r in q.items() if i not in dropped}, dropped, len(files)


def load_eg_scan(root, product="wowf"):
    """Which quests the Forever server answers for, from EG Link's quest_scan.
    quest -> True (described: open) or False (asked, no answer: likely removed or
    replaced in Forever). Newest build wins; quests never scanned are absent."""
    files = sorted(glob.glob(os.path.join(root, "data", product, "*", "quest_scan.json")), key=build_key)
    served = {}
    for f in files:
        d = json.load(open(f, encoding="utf-8"))
        for k in d.get("noData", []):
            served[int(k)] = False
        for k in d.get("described", {}):
            served[int(k)] = True
    return served


# ------------------------------------------------------------------ merge
def slugify(s):
    s = re.sub(r"[^a-z0-9]+", "-", (s or "chain").lower()).strip("-")
    return s[:40] or "chain"


def build_graph(a):
    """Load every source and return the merged link graph (and the lookups
    built on the way) as a namespace. Shared by the merge and the analysis tools."""
    base = load_questie_base(a.questiedb)
    delta = load_questie_delta(a.questiedb, set(base))
    traces = load_traces(a.questiedb)
    spoken, has_text = load_spoken(a.spoken)
    eg, eg_dropped, eg_builds = load_eglink(a.eglink)
    served = load_eg_scan(a.eglink)

    names = {i: q["name"] for i, q in base.items()}
    names.update(delta)
    for i, q in spoken.items():
        names[i] = q["title"] or names.get(i)
    eg_only = set()
    for i, r in eg.items():
        if i not in names:
            eg_only.add(i)
        names[i] = names.get(i) or r["title"]
    for i in eg_dropped:  # placeholders the other sources still list
        names.pop(i, None)
    known = set(names)
    has_text |= {i for i, r in eg.items() if r["has_text"]}
    eg_text = {i for i, r in eg.items() if r["has_text"]}

    # edges[(prev, nxt)] = {"sources": set, "conf": best trace confidence}
    seq = collections.defaultdict(lambda: {"sources": set(), "conf": None})
    grp = collections.defaultdict(set)

    def add_seq(p, n, src, conf=None):
        if p == n or p not in known or n not in known:
            return
        e = seq[(p, n)]
        e["sources"].add(src)
        if conf is not None:
            e["conf"] = max(conf, e["conf"] if e["conf"] is not None else conf)

    for q, r in base.items():
        for p in r["single"]:
            add_seq(p, q, "questie")
        if r["next"]:
            add_seq(q, r["next"], "questie")
        for p in r["group"]:
            grp[(p, q)].add("questie")
            add_seq(p, q, "questie-all")  # "needs all of these": each one is a link in
    for kind, p, q, conf in traces:
        if conf < a.min_trace_conf:
            continue
        if kind == "single":
            add_seq(p, q, "traces", conf)
        elif p in known and q in known:
            grp[(p, q)].add("traces")
    for q, r in spoken.items():
        if r["prev"]:
            add_seq(r["prev"], q, "spoken")
    for q, r in eg.items():
        if r["next"]:
            add_seq(q, r["next"], "eglink")
    # item links: a quest rewards an item that another quest asks for. Only items that
    # exactly one quest gives and exactly one quest needs: common items (potions, drinks)
    # would otherwise tie unrelated quests together.
    givers, needers = collections.defaultdict(set), collections.defaultdict(set)
    for q, r in eg.items():
        for i in r["gives_items"]:
            givers[i].add(q)
        for i in r["needs_items"]:
            needers[i].add(q)
    item_links = 0
    for item, gs in givers.items():
        if len(gs) == 1 and len(needers.get(item, ())) == 1:
            (p,), (n,) = gs, needers[item]
            if p != n and p in known and n in known:
                add_seq(p, n, "items")
                item_links += 1
    del add_seq
    return types.SimpleNamespace(**locals())


def components(nodes, edges, keep_single=()):
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
    return [c for c in groups.values() if len(c) > 1 or c & set(keep_single)]


def chain_title(g, members, root):
    hint = g.spoken.get(root, {}).get("name")
    return g.names.get(hint) if isinstance(hint, int) else g.names.get(root)


def make_chains(g, sp):
    """Chains = connected components over the links the splitter kept (sp, from
    split_chains.split). Turn-ins and side quests ride along with their quest."""
    kept, turnins, side = sp.kept, sp.turnins, sp.side_quests
    linked = {n for e in kept for n in e}
    extras = set(turnins) | set(side)
    # where each quest sat before splitting, to record what was split from what
    before = {}
    for comp in components({n for e in g.seq for n in e}, g.seq):
        root = min(comp, key=lambda m: (any((p, m) in g.seq for p in comp), m))
        label = f"{slugify(chain_title(g, comp, root))}-{root}"
        for m in comp:
            before[m] = (label, len(comp))
    out_adj = collections.defaultdict(list)
    for p, n in kept:
        out_adj[p].append(n)
    chains = []
    # a quest whose only links are turn-ins or side quests is a chain of one step
    for members in components(linked | extras, kept, keep_single=extras):
        edges = [(p, n) for (p, n) in kept if p in members]
        step_list, depth, cycle, anchored = split_chains.steps(members, edges, g.names)
        order = sorted(members, key=lambda m: (depth[m], m))
        root = order[0]
        title = chain_title(g, members, root)
        if len(step_list[0]) > 1 and len(step_list[-1]) == 1:
            # several parallel starts that lead to one quest: that quest names the chain
            title = step_list[-1][0]["title"]
        tins = sorted(t for m in members for t in turnins.get(m, []))
        sides = sorted(t for m in members for t in side.get(m, []))
        zones = collections.Counter(z for m in members for z in g.spoken.get(m, {}).get("zones", []))
        sorts = collections.Counter(g.spoken[m]["sort"] for m in members
                                    if m in g.spoken and g.spoken[m]["sort"])
        flags = []
        if len(members) >= LARGE_CHAIN:
            flags.append("large")
        if sorts and sum(sorts.values()) >= len(members) / 2:
            flags.append("class_or_profession")
        if any(g.spoken.get(m, {}).get("dungeon") for m in members):
            flags.append("dungeon")
        if cycle:
            flags.append("cycle")
        if any(len(out_adj[m]) > 1 for m in members):
            flags.append("branching")
        if any((p in members and n in members) for (p, n) in g.grp):
            flags.append("group_prereq")
        if tins:
            flags.append("turn_ins")
        if sides:
            flags.append("side_quests")
        n_sources = collections.Counter(len(g.seq[e]["sources"]) for e in edges)
        orig, orig_size = before.get(root, (None, 0))
        chains.append({
            "id": f"{slugify(title)}-{root}",
            "name": title,
            "root": root,
            "size": len(members),
            "length": len(step_list),
            "quests": order,
            "steps": step_list,
            "turnins": tins,
            "side_quests": sides,
            "branches": [],       # side storylines that start their own chain here
            "branches_from": [],  # where this chain branches off another
            "anchored": anchored,
            "not_served": sorted(m for m in list(members) + tins if g.served.get(m) is False),
            "forever_ids": sum(1 for m in members if split_chains.era(m) == "forever"),
            "split_from": orig if orig_size != len(members) + len(tins) + len(sides) else None,
            "zones": [z for z, _ in zones.most_common(3)],
            "sorts": [s for s, _ in sorts.most_common(3)],
            "forever_new": sum(1 for m in members if m in g.delta),
            "eglink_only_quests": sum(1 for m in members if m in g.eg_only),
            "text_coverage": round(sum(1 for m in members if m in g.has_text) / len(members), 2),
            "edges_by_agreement": {str(k): v for k, v in sorted(n_sources.items())},
            "flags": flags,
        })
    chains.sort(key=lambda c: -c["size"])
    chain_of = {q: c for c in chains for q in c["quests"]}
    for b in sp.branches:
        parent, child = chain_of.get(b["from"]), chain_of.get(b["to"])
        if parent and child:
            parent["branches"].append({"quest": b["from"], "to": b["to"], "chain": child["id"], "how": b["how"]})
            child["branches_from"].append({"quest": b["from"], "to": b["to"], "chain": parent["id"], "how": b["how"]})
    return chains


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--questiedb", default=os.path.join(SOURCES, "QuestieDB"))
    ap.add_argument("--spoken", default=os.path.join(SOURCES, "spoken-wow"))
    ap.add_argument("--eglink", default=os.path.join(SOURCES, "eg-link-output-wowf"))
    ap.add_argument("--out", default=os.path.join(HERE, "out"))
    ap.add_argument("--min-trace-conf", type=int, default=0,
                    help="drop trace-derived edges below this confidence (0 low, 1 medium, 2 high, 3 very high)")
    a = ap.parse_args()

    g = build_graph(a)
    (base, delta, spoken, has_text, eg, eg_dropped, eg_builds, names, eg_only, known,
     eg_text, seq, grp) = (g.base, g.delta, g.spoken, g.has_text, g.eg, g.eg_dropped,
                           g.eg_builds, g.names, g.eg_only, g.known, g.eg_text, g.seq, g.grp)

    sp = split_chains.split(g)
    removed, turnins = sp.removed, sp.turnins
    chains = make_chains(g, sp)
    in_chain = {m for c in chains for m in c["quests"] + c["turnins"] + c["side_quests"]}
    standalone = sorted(known - in_chain)
    rules = collections.Counter(r["rule"] for r in removed)
    not_served = {q for q, ok in g.served.items() if ok is False and q in known}

    # disagreements: Spoken's prev vs everything else
    other_prev = collections.defaultdict(set)
    for (p, n), e in seq.items():
        if e["sources"] - {"spoken"}:
            other_prev[n].add(p)
    disagree = [(q, r["prev"], sorted(other_prev[q]))
                for q, r in spoken.items()
                if r["prev"] and other_prev.get(q) and r["prev"] not in other_prev[q]]
    spoken_only = sum(1 for e in seq.values() if e["sources"] == {"spoken"})
    questie_only = sum(1 for e in seq.values() if "spoken" not in e["sources"])
    by_source = collections.Counter("+".join(sorted(e["sources"])) for e in seq.values())
    questie_alone = sum(1 for e in seq.values() if e["sources"] <= {"questie", "questie-all", "traces"})

    # ---------------------------------------------------------------- write
    os.makedirs(a.out, exist_ok=True)
    with open(os.path.join(a.out, "chains.json"), "w", encoding="utf-8") as f:
        json.dump({"chains": chains, "standalone": standalone,
                   "forever_new": sorted(delta), "removed_links": removed,
                   "checks": sp.checks}, f, indent=1)

    sizes = [c["size"] for c in chains]
    buckets = collections.Counter("2" if s == 2 else "3-5" if s < 6 else "6-12" if s < 13
                                  else "13-24" if s < LARGE_CHAIN else "25+" for s in sizes)
    nm = lambda i: f"{names.get(i)} ({i})"
    L = []
    L.append("# Chain merge report\n")
    L.append(f"- Known quests: {len(known)} (QuestieDB base {len(base)}, new Forever {len(delta)}, Spoken {len(spoken)})")
    L.append(f"- Sequential edges: {len(seq)} (without spoken: {questie_only}, spoken only: {spoken_only})")
    L.append(f"- Links removed by the splitter: {len(removed)} {dict(rules.most_common())}; "
             f"turn-in fans: {len(turnins)} ({sum(map(len, turnins.values()))} quests)")
    hows = collections.Counter(b["how"] for b in sp.branches)
    L.append(f"- Side storylines split into their own chain: {len(sp.branches)} {dict(hows)}; "
             f"one-quest side quests folded into their quest: {sum(map(len, sp.side_quests.values()))}; "
             f"links flagged to check: {len(sp.checks)}; item links: {g.item_links}")
    L.append(f"- Not served by the Forever server (EG Link quest_scan): {len(not_served)} known quests; "
             f"in chains: {sum(len(c['not_served']) for c in chains)}; "
             f"variants placed by title match: {sum(len(c['anchored']) for c in chains)}")
    L.append(f"- Chains: {len(chains)}; standalone quests: {len(standalone)}; "
             f"split from a larger merged group: {sum(1 for c in chains if c['split_from'])}")
    L.append(f"- Chain size buckets: {dict(buckets)}")
    L.append(f"- Median text coverage per chain: {statistics.median(c['text_coverage'] for c in chains):.2f}")
    L.append(f"- Spoken `prev` disagreeing with Questie/traces: {len(disagree)}")
    L.append(f"- EG Link: {len(eg)} quests from {eg_builds} builds ({len(eg_only)} unknown to the other sources, "
             f"{len(eg_dropped)} placeholders dropped); text for {len(eg_text)}")
    L.append(f"- Edges supported only by QuestieDB (base or traces): {questie_alone} "
             f"(see the release checklist in docs/LICENSING.md)\n")
    L.append("## Edges by source\n")
    for k, v in by_source.most_common():
        L.append(f"- {k}: {v}")
    L.append("")
    L.append("## Large chains (candidates to split)\n")
    for c in [c for c in chains if "large" in c["flags"]][:15]:
        first = ", ".join(names.get(m, "?") for m in c["quests"][:4])
        L.append(f"- **{c['name']}** ({c['size']} quests, {c['length']} steps), zones {c['zones']}, sorts {c['sorts']}, "
                 f"flags {c['flags']}: {first} ...")
    L.append("\n## Chains containing new Forever quests (largest 15)\n")
    for c in sorted([c for c in chains if c["forever_new"]], key=lambda c: -c["forever_new"])[:15]:
        L.append(f"- {c['name']}: {c['forever_new']}/{c['size']} new, text {c['text_coverage']:.0%}")
    L.append("\n## Sample disagreements (quest: spoken prev vs others)\n")
    for q, sp, ot in disagree[:20]:
        L.append(f"- {nm(q)}: spoken says {nm(sp)}; others say {[nm(o) for o in ot[:3]]}")
    open(os.path.join(a.out, "report.md"), "w", encoding="utf-8").write("\n".join(L) + "\n")
    print("\n".join(L[:8]))


if __name__ == "__main__":
    main()

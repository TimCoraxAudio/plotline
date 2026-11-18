#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Merge quest-chain data for the lore add-on's offline pipeline.

Inputs (local clones, nothing is downloaded):
  --questiedb  path to a clone of github.com/Questie/QuestieDB
  --spoken     path to a clone of github.com/rusty-key/spoken-wow

Outputs (to --out):
  chains.json   chains + standalone IDs. Names and IDs only, no quest text.
  report.md     sizes, coverage, mega-chain breakdown, source disagreements

Needs: pip install lupa
"""
import argparse, collections, json, os, re, statistics

from lupa import LuaRuntime

LUA = LuaRuntime(unpack_returned_tuples=True)
LARGE_CHAIN = 25  # chains at least this long are flagged for manual splitting


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
            "dungeon": int(r["dungeon"]) if r["dungeon"] else None,
            "name": r["name"],  # chain-name hint on a chain's first quest
            "notext": bool(r["notext"]),
        }
    # Only IDs are kept from the text file: we need coverage, not the prose.
    has_text = {int(k) for k in text.keys()}
    return q, has_text


# ------------------------------------------------------------------ merge
def slugify(s):
    s = re.sub(r"[^a-z0-9]+", "-", (s or "chain").lower()).strip("-")
    return s[:40] or "chain"


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--questiedb", required=True)
    ap.add_argument("--spoken", required=True)
    ap.add_argument("--out", default=".")
    ap.add_argument("--min-trace-conf", type=int, default=0,
                    help="drop trace-derived edges below this confidence (0 low, 1 medium, 2 high, 3 very high)")
    a = ap.parse_args()

    base = load_questie_base(a.questiedb)
    delta = load_questie_delta(a.questiedb, set(base))
    traces = load_traces(a.questiedb)
    spoken, has_text = load_spoken(a.spoken)

    names = {i: q["name"] for i, q in base.items()}
    names.update(delta)
    for i, q in spoken.items():
        names[i] = q["title"] or names.get(i)
    known = set(names)

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

    # chains = connected components over sequential edges
    parent = {}

    def find(x):
        while parent.setdefault(x, x) != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    for (p, n) in seq:
        parent[find(n)] = find(p)
    comps = collections.defaultdict(set)
    for (p, n) in seq:
        comps[find(p)] |= {p, n}

    out_adj = collections.defaultdict(list)
    in_deg = collections.Counter()
    for (p, n) in seq:
        out_adj[p].append(n)
        in_deg[n] += 1

    chains = []
    for members in comps.values():
        # longest-path depth via Kahn's algorithm
        deg = {m: sum(1 for (p, n) in seq if n == m and p in members) for m in members} \
            if len(members) < 200 else {m: in_deg[m] for m in members}
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
        order = sorted(members, key=lambda m: (depth[m], m))
        root = order[0]
        sp_root = spoken.get(root, {})
        hint = sp_root.get("name")
        title = names.get(hint) if isinstance(hint, int) else names.get(root)
        zones = collections.Counter(z for m in members for z in spoken.get(m, {}).get("zones", []))
        sorts = collections.Counter(spoken[m]["sort"] for m in members
                                    if m in spoken and spoken[m]["sort"])
        dungeon = any(spoken.get(m, {}).get("dungeon") for m in members)
        flags = []
        if len(members) >= LARGE_CHAIN:
            flags.append("large")
        if sorts and sum(sorts.values()) >= len(members) / 2:
            flags.append("class_or_profession")
        if dungeon:
            flags.append("dungeon")
        if seen < len(members):
            flags.append("cycle")
        if any(len(out_adj[m]) > 1 for m in members):
            flags.append("branching")
        if any((p in members and n in members) for (p, n) in grp):
            flags.append("group_prereq")
        n_sources = collections.Counter()
        for (p, n), e in seq.items():
            if p in members:
                n_sources[len(e["sources"])] += 1
        chains.append({
            "id": f"{slugify(title)}-{root}",
            "name": title,
            "root": root,
            "size": len(members),
            "quests": order,
            "zones": [z for z, _ in zones.most_common(3)],
            "sorts": [s for s, _ in sorts.most_common(3)],
            "forever_new": sum(1 for m in members if m in delta),
            "text_coverage": round(sum(1 for m in members if m in has_text) / len(members), 2),
            "edges_by_agreement": {str(k): v for k, v in sorted(n_sources.items())},
            "flags": flags,
        })
    chains.sort(key=lambda c: -c["size"])
    in_chain = {m for c in chains for m in c["quests"]}
    standalone = sorted(known - in_chain)

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

    # ---------------------------------------------------------------- write
    os.makedirs(a.out, exist_ok=True)
    with open(os.path.join(a.out, "chains.json"), "w", encoding="utf-8") as f:
        json.dump({"chains": chains, "standalone": standalone,
                   "forever_new": sorted(delta)}, f, indent=1)

    sizes = [c["size"] for c in chains]
    buckets = collections.Counter("2" if s == 2 else "3-5" if s < 6 else "6-12" if s < 13
                                  else "13-24" if s < LARGE_CHAIN else "25+" for s in sizes)
    nm = lambda i: f"{names.get(i)} ({i})"
    L = []
    L.append("# Chain merge report\n")
    L.append(f"- Known quests: {len(known)} (QuestieDB base {len(base)}, new Forever {len(delta)}, Spoken {len(spoken)})")
    L.append(f"- Sequential edges: {len(seq)} (questie-or-traces only: {questie_only}, spoken only: {spoken_only})")
    L.append(f"- Chains: {len(chains)}; standalone quests: {len(standalone)}")
    L.append(f"- Chain size buckets: {dict(buckets)}")
    L.append(f"- Median text coverage per chain: {statistics.median(c['text_coverage'] for c in chains):.2f}")
    L.append(f"- Spoken `prev` disagreeing with Questie/traces: {len(disagree)}\n")
    L.append("## Large chains (candidates to split)\n")
    for c in [c for c in chains if "large" in c["flags"]][:15]:
        first = ", ".join(names.get(m, "?") for m in c["quests"][:4])
        L.append(f"- **{c['name']}** ({c['size']}), zones {c['zones']}, sorts {c['sorts']}, "
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

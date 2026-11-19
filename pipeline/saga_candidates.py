#!/usr/bin/env -S uv run --script
# SPDX-License-Identifier: GPL-3.0-or-later
# /// script
# requires-python = ">=3.10"
# dependencies = ["lupa>=2"]
# ///
"""Find chains (and standalone quests) that may belong to one storyline: candidates for sagas.

docs/STORYLINES.md has the plan. This is step 1: cheap signals, no LLM. Each pair of units (a chain,
or a quest in no chain) gets a score from:

  start_item  one rewards or drops the item that starts a quest in the other     (4)
  item        one rewards an item the other asks for (a link the splitter cut)    (3)
  cut_link    any other link the splitter removed between them                    (1)
  title_name  a rare name from one's titles appears in the other's text           (3 each, max 6)
  same_cast   rare names that appear in both texts (people, places, things)      (1 each, max 4)
  npc         the same quest giver or ender (NPC or object)                       (2)
  class       the same class QuestSort (e.g. 162 Rogue)                           (1)

A name is "rare" when it appears in the titles or text of 4 units or fewer. Groups are the
connected parts of the pairs that score MIN_SCORE or more.

Writes pipeline/out/saga_candidates.json and saga_candidates.md (git-ignored: they hold titles).
The quest text is read from the submodules to find names, and is never written out.

Run: uv run pipeline/saga_candidates.py   (after merge_chains.py)
"""
import argparse, collections, itertools, json, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import merge_chains as mc  # noqa: E402
import split_chains as sc  # noqa: E402
import build_addon_data as bd  # noqa: E402
from build_quest_text import eg_quests  # noqa: E402

MIN_SCORE = 4
RARE = 4
# capitalised words that are names in quest text far less often than not
STOP = set("""
Alliance Horde Stormwind Orgrimmar Ironforge Undercity Darnassus Thunder Bluff Kalimdor Eastern
Kingdoms Azeroth Light Elune Lord Lady King Queen Prince Princess Captain Commander General Sergeant
Master Brother Sister Father Mother Elder Archmage Magistrate Marshal Baron Highlord Priest Mage
Warrior Rogue Hunter Druid Shaman Paladin Warlock Champion Return Bring Take Speak Find Collect
Gather Kill Slay Travel Deliver Report Seek Your There These Those This That They Them When Then
What Where Which While With Without From Into Here Have Good Well Very Some Many Much More Most
Perhaps Maybe Once After Before Though Although Still Even Also Just Only Already Again Because
""".split())
WORD = re.compile(r"\b[A-Z][a-z']{3,}(?:[A-Z][a-z']+)?\b")
TOKEN = re.compile(r"\$[A-Za-z]")   # the game's $N / $C placeholders


def names_in(text):
    text = TOKEN.sub(" ", text or "")
    return {re.sub(r"'s?$", "", w) for w in WORD.findall(text)} - STOP


def quest_texts(a):
    """Quest -> {field: text} from EG Link (description, objectives, completion) and Spoken
    (accept, complete). Private pipeline input: read from the submodules, never written to the
    repo. Call after mc.build_graph, which loads Spoken's text into the Lua state."""
    out = collections.defaultdict(dict)
    for q, t in eg_quests(a.eglink).items():
        for k, short in (("description", "description"), ("objectivesText", "objectives"),
                         ("completionText", "completion")):
            if t.get(k):
                out[q][short] = t[k]
    spoken = mc.LUA.globals()["SpokenQuestsText"]
    for k in spoken.keys():
        t = spoken[k]
        for f in ("accept", "complete"):
            if t[f]:
                out[int(k)]["spoken_" + f] = str(t[f])
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--questiedb", default=os.path.join(mc.SOURCES, "QuestieDB"))
    ap.add_argument("--spoken", default=os.path.join(mc.SOURCES, "spoken-wow"))
    ap.add_argument("--eglink", default=os.path.join(mc.SOURCES, "eg-link-output-wowf"))
    ap.add_argument("--min-trace-conf", type=int, default=0)
    ap.add_argument("--min-score", type=int, default=MIN_SCORE)
    ap.add_argument("--out", default=os.path.join(HERE, "out"))
    a = ap.parse_args()

    g = mc.build_graph(a)
    sp = sc.split(g)
    chains = mc.make_chains(g, sp)
    facts = bd.quest_facts(a)

    # units: chains, and quests in no chain
    unit_of, units = {}, {}
    for c in chains:
        units[c["id"]] = {"id": c["id"], "kind": "chain", "name": c["name"],
                          "quests": c["quests"] + c["side_quests"] + c["turnins"]}
        for q in units[c["id"]]["quests"]:
            unit_of[q] = c["id"]
    for q in sorted(g.known):
        if q not in unit_of:
            uid = f"q{q}"
            units[uid] = {"id": uid, "kind": "quest", "name": g.names.get(q), "quests": [q]}
            unit_of[q] = uid
    for u in units.values():
        lv = [int(facts[q]["l"]) for q in u["quests"] if facts.get(q, {}).get("l")]
        u["levels"] = [min(lv), max(lv)] if lv else None
        cats = {bd.class_sort(g, q) for q in u["quests"]} - {None}
        u["class"] = cats.pop() if len(cats) == 1 else None

    pairs = collections.defaultdict(lambda: collections.defaultdict(list))

    def hit(qa, qb, signal, detail):
        ua, ub = unit_of.get(qa), unit_of.get(qb)
        if ua and ub and ua != ub:
            key = tuple(sorted((ua, ub)))
            pairs[key][signal].append(detail)

    # links between units
    for p, n, item in g.start_item_links:
        hit(p, n, "start_item", [p, n, item])
    for r in sp.removed:
        src = set(r["sources"])
        hit(r["from"], r["to"], "item" if src == {"items"} else "cut_link", [r["from"], r["to"], r["rule"]])

    # names: from titles and quest text (text is read, never written). EG Link, plus Spoken's
    # accept and complete text (build_graph has already loaded it into the Lua state).
    text = {q: " ".join(t.values()) for q, t in quest_texts(a).items()}
    # a name is a word that's always capitalised: one that also appears in lower case
    # ("talisman", "drop") is an ordinary word
    lower = set()
    for t in list(text.values()) + [n or "" for n in g.names.values()]:
        lower |= set(re.findall(r"\b[a-z][a-z']{3,}\b", t))
    def proper(ns_):
        return {n for n in ns_ if n.lower() not in lower}
    title_names, text_names = collections.defaultdict(set), collections.defaultdict(set)
    for uid, u in units.items():
        for q in u["quests"]:
            title_names[uid] |= proper(names_in(g.names.get(q)))
            text_names[uid] |= proper(names_in(text.get(q, "")))
        text_names[uid] |= title_names[uid]
    spread = collections.Counter(n for s in text_names.values() for n in s)
    rare = {n for n, k in spread.items() if 2 <= k <= RARE}
    by_name = collections.defaultdict(set)
    for uid, s in text_names.items():
        for n in s & rare:
            by_name[n].add(uid)
    for n, us in by_name.items():
        for ua, ub in itertools.combinations(sorted(us), 2):
            key = (ua, ub)
            if n in title_names[ua] or n in title_names[ub]:
                pairs[key]["title_name"].append(n)
            else:
                pairs[key]["same_cast"].append(n)

    # same giver / ender
    givers, enders = bd.quest_givers(a, g), bd.quest_givers(a, g, "takes", "enders")
    by_npc = collections.defaultdict(set)
    for q in g.known:
        for npc in {givers.get(q), enders.get(q)} - {None}:
            by_npc[npc].add(unit_of[q])
    for npc, us in by_npc.items():
        if len(us) <= RARE * 2:   # hub NPCs (inn keepers, faction quartermasters) say little
            for ua, ub in itertools.combinations(sorted(us), 2):
                pairs[(ua, ub)]["npc"].append(npc)

    # class: only between units that already have another signal, or both small class units
    by_class = collections.defaultdict(set)
    for uid, u in units.items():
        if u["class"]:
            by_class[u["class"]].add(uid)

    WEIGHT = {"start_item": 4, "item": 3, "cut_link": 1, "title_name": 3, "same_cast": 1, "npc": 2}
    CAP = {"title_name": 6, "same_cast": 4}
    out = []
    for (ua, ub), sig in pairs.items():
        s = 0
        for k, v in sig.items():
            s += min(CAP.get(k, 99), WEIGHT[k] * len(v))
        ca, cb = units[ua]["class"], units[ub]["class"]
        if ca and ca == cb:
            sig["class"] = [ca]
            s += 1
        out.append({"a": ua, "b": ub, "score": s, "signals": {k: v for k, v in sig.items()}})
    out.sort(key=lambda r: -r["score"])

    # groups: connected parts over strong pairs
    parent = {}

    def find(x):
        parent.setdefault(x, x)
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x
    strong = [r for r in out if r["score"] >= a.min_score]
    for r in strong:
        parent[find(r["a"])] = find(r["b"])
    groups = collections.defaultdict(set)
    for r in strong:
        groups[find(r["a"])] |= {r["a"], r["b"]}
    glist = sorted(({"units": sorted(m), "pairs": [r for r in strong if r["a"] in m]} for m in groups.values()),
                   key=lambda gr: (-len(gr["units"]), gr["units"][0]))
    # class collections: every chain of one class, for the Journal's class grouping and the LLM pass
    classes = {str(c): sorted(us) for c, us in sorted(by_class.items())}

    os.makedirs(a.out, exist_ok=True)
    with open(os.path.join(a.out, "saga_candidates.json"), "w", encoding="utf-8") as f:
        json.dump({"min_score": a.min_score, "units": units, "pairs": out, "groups": glist, "classes": classes},
                  f, indent=1)

    def label(uid):
        u = units[uid]
        lv = u["levels"]
        lvl = f", level {lv[0]}" + (f"-{lv[1]}" if lv[1] != lv[0] else "") if lv else ""
        return f"{u['name']} (`{uid}`, {len(u['quests'])} quests{lvl})"
    L = ["# Saga candidates", "",
         f"{len(out)} scored pairs; {len(strong)} with score >= {a.min_score}, in {len(glist)} groups.",
         "Signals: " + ", ".join(f"{k} {w}" for k, w in WEIGHT.items()) + ", class 1. See the script's docstring.", ""]
    for i, gr in enumerate(glist[:150], 1):
        L.append(f"## {i}. {len(gr['units'])} units")
        for uid in gr["units"]:
            L.append(f"- {label(uid)}")
        for r in gr["pairs"][:12]:
            sig = "; ".join(f"{k}: {', '.join(map(str, v[:4]))}" for k, v in r["signals"].items())
            L.append(f"  - `{r['a']}` + `{r['b']}`: **{r['score']}** ({sig})")
        L.append("")
    with open(os.path.join(a.out, "saga_candidates.md"), "w", encoding="utf-8") as f:
        f.write("\n".join(L))
    print(f"Wrote pipeline/out/saga_candidates.json and .md: {len(out)} pairs, {len(strong)} strong, "
          f"{len(glist)} groups (largest {len(glist[0]['units']) if glist else 0}).")


if __name__ == "__main__":
    main()

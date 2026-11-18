#!/usr/bin/env -S uv run --script
# SPDX-License-Identifier: GPL-3.0-or-later
# /// script
# requires-python = ">=3.10"
# dependencies = ["lupa>=2"]
# ///
"""Write the add-on's chain data: addon/Plotline/Data/Chains.lua.

Builds the chains the same way merge_chains.py does (merge, then splitter) and writes
them as Lua tables of quest IDs. No names or text: the add-on asks the game for quest
titles at runtime (docs/LICENSING.md). The output is git-ignored until the release
checklist in docs/LICENSING.md is done.

Run: uv run pipeline/build_addon_data.py   (after: git submodule update --init --depth 1)

--dev-text also writes addon/Plotline/Data/DevQuestText.lua: quest text (Blizzard's) from EG Link,
then Spoken, for testing the add-on before text capture exists. It is for your own machine only:
git-ignored, never committed, never in a release (docs/LICENSING.md).
"""
import argparse, datetime, os, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import merge_chains as mc  # noqa: E402
import split_chains as sc  # noqa: E402

OUT = os.path.join(HERE, "..", "addon", "Plotline", "Data", "Chains.lua")
DEV_TEXT = os.path.join(HERE, "..", "addon", "Plotline", "Data", "DevQuestText.lua")


def restriction(g, q):
    """Who can take quest q, as Lua fields: f (faction "A"/"H"), r (race IDs), c (class IDs).
    Empty when anyone can. Mask bit b is race/class ID b + 1."""
    out = {}
    m = sc.race_mask(g, q)
    if m and m & sc.PLAYABLE != sc.PLAYABLE:
        m &= sc.PLAYABLE
        if m & sc.ALLIANCE and not m & sc.HORDE:
            out["f"] = '"A"'
        elif m & sc.HORDE and not m & sc.ALLIANCE:
            out["f"] = '"H"'
        if m not in (sc.ALLIANCE, sc.HORDE):
            out["r"] = lua_list(b + 1 for b in sc.bits(m))
    c = sc.class_mask(g, q)
    if c and c & sc.ALL_CLASSES != sc.ALL_CLASSES:
        out["c"] = lua_list(b + 1 for b in sc.bits(c & sc.ALL_CLASSES))
    return out


def lua_list(xs):
    return "{" + ",".join(str(x) for x in xs) + "}"


def name_quest(g, c):
    """The quest whose title names the chain (titles are looked up in-game)."""
    hint = g.spoken.get(c["root"], {}).get("name")
    if isinstance(hint, int) and g.names.get(hint) == c["name"]:
        return hint
    for layer in c["steps"]:
        for grp in layer:
            for q in grp["quests"]:
                if g.names.get(q) == c["name"]:
                    return q
    return c["root"]


DUNGEON, RAID = 81, 62   # QuestInfo IDs (EG Link questInfoId)


def quest_kinds(a, g):
    """Quest -> "d" (dungeon) or "r" (raid): EG Link's questInfoId (union across builds, newest
    wins), else Spoken's dungeon flag."""
    import glob, json
    files = sorted(glob.glob(os.path.join(a.eglink, "data", "wowf", "*", "quests.enUS.json")), key=mc.build_key)
    info = {}
    for f in files:
        for k, v in json.load(open(f, encoding="utf-8"))["quests"].items():
            if v.get("questInfoId") is not None:
                info[int(k)] = v["questInfoId"]
    out = {}
    for q in g.known:
        i = info.get(q)
        if i == RAID:
            out[q] = "r"
        elif i == DUNGEON or (i is None and g.spoken.get(q, {}).get("dungeon")):
            out[q] = "d"
    return out


def quest_givers(a, g, eg_key="offers", questie_key="givers"):
    """Quest -> who gives it (or, with "takes"/"enders", who takes it in): an NPC ID (positive) or a
    game object ID (negative). EG Link's npcs.json first (union across builds), else QuestieDB.
    IDs only: the add-on asks the game for names."""
    import glob, json
    eg = {}
    for f in sorted(glob.glob(os.path.join(a.eglink, "data", "wowf", "*", "npcs.json")), key=mc.build_key):
        d = json.load(open(f, encoding="utf-8"))
        for kind, sign in (("npcs", 1), ("objects", -1)):
            for nid, n in d.get(kind, {}).items():
                for q in n.get(eg_key, {}):
                    eg.setdefault(int(q), set()).add(sign * int(nid))
    out = {}
    for q in g.known:
        ids = eg.get(q)
        if not ids:
            ids = {(1 if k[0] == "c" else -1) * int(k[1:]) for k in (g.base.get(q, {}).get(questie_key) or ())}
        if ids:
            npcs = sorted(i for i in ids if i > 0)
            out[q] = npcs[0] if npcs else sorted(ids)[0]
    return out


def build(g, sp, chains, kinds=None, givers=None, enders=None):
    kinds = kinds or {}
    givers = givers or {}
    enders = enders or {}
    lines, quests = [], {}
    side_of = {k: p for p, ks in sp.side_quests.items() for k in ks}
    turnin_of = {k: p for p, ks in sp.turnins.items() for k in ks}
    for c in chains:
        steps = "{" + ",".join("{" + ",".join(lua_list(grp["quests"]) for grp in layer) + "}"
                               for layer in c["steps"]) + "}"
        fields = [f'n={name_quest(g, c)}', f's={steps}']
        if c["zones"]:
            fields.append(f'z={c["zones"][0]}')
        steps_kinds = {kinds.get(q) for layer in c["steps"] for grp in layer for q in grp["quests"]}
        if "r" in steps_kinds:
            fields.append('k="r"')
        elif "d" in steps_kinds:
            fields.append('k="d"')
        side = {}
        for k in c["side_quests"]:
            side.setdefault(side_of[k], []).append(k)
        if side:
            fields.append("side={" + ",".join(f"[{p}]={lua_list(sorted(ks))}" for p, ks in sorted(side.items())) + "}")
        tin = {}
        for k in c["turnins"]:
            tin.setdefault(turnin_of[k], []).append(k)
        if tin:
            fields.append("t={" + ",".join(f"[{p}]={lua_list(sorted(ks))}" for p, ks in sorted(tin.items())) + "}")
        if c["branches"]:
            fields.append("br={" + ",".join(f'{{at={b["quest"]},to="{b["chain"]}"}}' for b in c["branches"]) + "}")
        if c["branches_from"]:
            b = c["branches_from"][0]
            fields.append(f'from={{at={b["quest"]},chain="{b["chain"]}"}}')
        lines.append(f'  ["{c["id"]}"]={{{",".join(fields)}}},')
        for q in c["quests"] + c["side_quests"] + c["turnins"]:
            r = restriction(g, q)
            if g.served.get(q) is False:
                r["gone"] = "true"
            if kinds.get(q):
                r["k"] = f'"{kinds[q]}"'
            if givers.get(q):
                r["g"] = str(givers[q])
            if enders.get(q):
                r["e"] = str(enders[q])
            if r:
                quests[q] = r
    qlines = [f"  [{q}]={{{','.join(f'{k}={v}' for k, v in r.items())}}}," for q, r in sorted(quests.items())]
    return lines, qlines


def lua_str(t):
    return '"' + t.replace("\\", "\\\\").replace('"', '\\"').replace("\r", "").replace("\n", "\\n") + '"'


def write_dev_text(a, g, chains, path):
    """Accept and completion text for every quest in a chain: EG Link first, then Spoken."""
    from chain_viewer import load_eg_text
    eg = load_eg_text(a.eglink)
    try:
        st = mc.LUA.globals()["SpokenQuestsText"]
        sp = {int(k): (st[k]["accept"], st[k]["complete"]) for k in st.keys()}
    except Exception:
        sp = {}
    # details beyond text, union across builds (newest wins): level, zone, rewards
    import glob, json
    more = {}
    for f in sorted(glob.glob(os.path.join(a.eglink, "data", "wowf", "*", "quests.enUS.json")), key=mc.build_key):
        for k, v in json.load(open(f, encoding="utf-8"))["quests"].items():
            m = more.setdefault(int(k), {})
            for key in ("level", "minLevel", "zoneAreaId"):
                if v.get(key) is not None:
                    m[key] = v[key]
            if v.get("rewards"):
                m["rewards"] = v["rewards"]
    lines, n = [], 0
    for q in sorted({q for c in chains for q in c["quests"] + c["side_quests"] + c["turnins"]}):
        e = eg.get(q, {})
        d = e.get("description") or (sp.get(q) or (None, None))[0]
        c = e.get("completionText") or (sp.get(q) or (None, None))[1]
        o = e.get("objectivesText")
        fields = [f"{k}={lua_str(v)}" for k, v in (("d", d), ("o", o), ("c", c)) if v]
        m = more.get(q, {})
        for key, short in (("level", "l"), ("minLevel", "ml"), ("zoneAreaId", "za")):
            if isinstance(m.get(key), int) and m[key] > 0:
                fields.append(f"{short}={m[key]}")
        rw = m.get("rewards") or {}
        if rw.get("money"):
            fields.append(f"m={int(rw['money'])}")
        for key, short in (("items", "ri"), ("choices", "rc")):
            ids = [str(x["itemId"]) for x in rw.get(key) or [] if x.get("itemId")]
            if ids:
                fields.append(f"{short}={{{','.join(ids)}}}")
        reps = [str(x["factionId"]) for x in rw.get("reputation") or [] if x.get("factionId")]
        if reps:
            fields.append(f"rp={{{','.join(reps)}}}")
        if fields:
            lines.append(f"  [{q}]={{{','.join(fields)}}},")
            n += 1
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join([
            "-- DEV ONLY. Quest text (c) Blizzard Entertainment, from EG Link and Spoken, for testing",
            "-- Plotline on your own machine. Never commit or ship this file (docs/LICENSING.md).",
            "-- Generated by: uv run pipeline/build_addon_data.py --dev-text",
            "local _, ns = ...",
            "-- [quest] = { d description, o objectives, c completion, l level, ml min level, za area ID,",
            "--   m money (copper), ri reward items, rc reward choices, rp reputation faction IDs }",
            "ns.devText = {",
            *lines,
            "}",
            "",
        ]))
    print(f"Wrote {os.path.relpath(path)}: text for {n} quests (dev only, git-ignored).")


def source_commits():
    out = []
    for name in ("QuestieDB", "spoken-wow", "eg-link-output-wowf"):
        try:
            rev = subprocess.run(["git", "-C", os.path.join(mc.SOURCES, name), "rev-parse", "--short", "HEAD"],
                                 capture_output=True, text=True, check=True).stdout.strip()
        except Exception:
            rev = "?"
        out.append(f"{name}@{rev}")
    return " ".join(out)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--questiedb", default=os.path.join(mc.SOURCES, "QuestieDB"))
    ap.add_argument("--spoken", default=os.path.join(mc.SOURCES, "spoken-wow"))
    ap.add_argument("--eglink", default=os.path.join(mc.SOURCES, "eg-link-output-wowf"))
    ap.add_argument("--min-trace-conf", type=int, default=0)
    ap.add_argument("--out", default=OUT)
    ap.add_argument("--dev-text", action="store_true",
                    help="also write Data/DevQuestText.lua (Blizzard text, your machine only)")
    a = ap.parse_args()

    g = mc.build_graph(a)
    sp = sc.split(g)
    chains = mc.make_chains(g, sp)
    kinds = quest_kinds(a, g)
    lines, qlines = build(g, sp, chains, kinds, quest_givers(a, g),
                          quest_givers(a, g, "takes", "enders"))
    today = datetime.date.today().isoformat()
    text = "\n".join([
        "-- Generated by pipeline/build_addon_data.py. Do not edit; re-run the script instead.",
        f"-- Built {today} from {source_commits()}.",
        "-- Quest IDs only: titles come from the game at runtime.",
        "-- Data from Efficient Games (https://efficient.games), licensed under CC BY 4.0;",
        "-- cross-checked against QuestieDB. Reorganised into quest chains by Plotline.",
        "--",
        "-- chains[id] = { n = quest whose title names the chain, s = steps (each a list of",
        "--   groups of quest IDs: parallel quests are separate groups, variants share one),",
        "--   z = uiMap, side = { [quest] = side quests }, t = { [quest] = turn-ins },",
        "--   br = branches off this chain, from = the chain this one branches off,",
        "--   k = \"d\" has a dungeon quest / \"r\" a raid quest }",
        "-- quests[id] = { f = faction, r = race IDs, c = class IDs, gone = not served, k = \"d\"/\"r\",",
        "--   g = quest giver, e = who takes it in: NPC ID, or -object ID }",
        "local _, ns = ...",
        "ns.data = {",
        f' built = "{today}",',
        " chains = {",
        *lines,
        " },",
        " quests = {",
        *qlines,
        " },",
        "}",
        "",
    ])
    os.makedirs(os.path.dirname(a.out), exist_ok=True)
    with open(a.out, "w", encoding="utf-8") as f:
        f.write(text)
    print(f"Wrote {os.path.relpath(a.out)}: {len(chains)} chains, {len(qlines)} quests with rules or a kind, "
          f"{len(text) // 1024} KB.")
    if a.dev_text:
        write_dev_text(a, g, chains, DEV_TEXT)


if __name__ == "__main__":
    main()

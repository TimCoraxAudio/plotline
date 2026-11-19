#!/usr/bin/env -S uv run --script
# SPDX-License-Identifier: GPL-3.0-or-later
# /// script
# requires-python = ">=3.10"
# dependencies = ["lupa>=2"]
# ///
"""Write the quest text pack: addon/Plotline_QuestText/QuestText.lua.

The pack is a separate, optional, load-on-demand add-on holding Blizzard's quest text (titles,
descriptions and objectives: what the player is first shown) for every quest the merge knows. The text
is Blizzard's and not under Plotline's licence: this file is git-ignored, never committed, and
built only for a local test or a release package (docs/LICENSING.md, docs/DATA.md).

Sources, per field (first that has it wins):
  t  title        EG Link quests (newest build), else the merge's name (QuestieDB / Spoken / EG)
  d  description  EG Link quests, else EG Link texts "accept" (templated), else Spoken accept,
                  else EG Link texts "accept" as players saw them
  o  objectives   EG Link quests, else EG Link texts "objectives"
Progress and completion text are deliberately left out: Plotline only reminds players of the
opening prompt, and completion text gives away how a quest ends. (Captured text still shows them.)
Every source used keeps the game's placeholders ($N, $C, $R, $g...;) except the last fallback for
descriptions (about 150 quests), which players saw with gendered words already chosen.

Run: uv run pipeline/build_quest_text.py   (after: git submodule update --init --depth 1)
"""
import argparse, collections, datetime, glob, json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import merge_chains as mc  # noqa: E402
from build_addon_data import lua_str, source_commits  # noqa: E402

OUT = os.path.join(HERE, "..", "addon", "Plotline_QuestText", "QuestText.lua")


def eg_files(root, name):
    return sorted(glob.glob(os.path.join(root, "data", "wowf", "*", name)), key=mc.build_key)


def eg_quests(root):
    """Quest -> {title, description, objectivesText, completionText}, union across builds, newest wins."""
    out = {}
    for f in eg_files(root, "quests.enUS.json"):
        for k, v in json.load(open(f, encoding="utf-8"))["quests"].items():
            m = out.setdefault(int(k), {})
            for key in ("title", "description", "objectivesText", "completionText"):
                if (v.get(key) or "").strip():
                    m[key] = v[key]
    return out


def eg_texts(root):
    """Quest -> kind -> {text: {"times", "male", "female", "template"}}, summed across builds."""
    out = collections.defaultdict(lambda: collections.defaultdict(dict))
    for f in eg_files(root, "texts.enUS.json"):
        for k, kinds in json.load(open(f, encoding="utf-8")).get("quests", {}).items():
            for kind, variants in kinds.items():
                for v in variants:
                    t = (v.get("text") or "").strip()
                    if not t:
                        continue
                    e = out[int(k)][kind].setdefault(t, {"times": 0, "male": 0, "female": 0, "template": None})
                    e["times"] += v.get("times") or 1
                    for sex in ("male", "female"):
                        e[sex] += (v.get("sexes") or {}).get(sex, 0)
                    e["template"] = e["template"] or v.get("template")
    return out


def pick(variants, templated):
    """The most-shown variant of one field that is (templated=True) or isn't the game's own template
    with its placeholders. None if there is none."""
    ok = [t for t, e in (variants or {}).items() if bool(e["template"]) == templated]
    return max(ok, key=lambda t: variants[t]["times"]) if ok else None


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--questiedb", default=os.path.join(mc.SOURCES, "QuestieDB"))
    ap.add_argument("--spoken", default=os.path.join(mc.SOURCES, "spoken-wow"))
    ap.add_argument("--eglink", default=os.path.join(mc.SOURCES, "eg-link-output-wowf"))
    ap.add_argument("--min-trace-conf", type=int, default=0)
    ap.add_argument("--out", default=OUT)
    a = ap.parse_args()

    g = mc.build_graph(a)   # the known quests, their names, and Spoken's text (in mc.LUA)
    eq, et = eg_quests(a.eglink), eg_texts(a.eglink)
    try:
        st = mc.LUA.globals()["SpokenQuestsText"]
        sp = {int(k): (st[k]["accept"], st[k]["complete"]) for k in st.keys()}
    except Exception:
        sp = {}

    counts, lines = collections.Counter(), []
    for q in sorted(g.known):
        e, t = eq.get(q, {}), et.get(q, {})
        s_acc = (sp.get(q) or (None, None))[0]
        fields = {}
        fields["t"] = e.get("title") or g.names.get(q)
        fields["d"] = (e.get("description") or pick(t.get("accept"), True) or s_acc
                       or pick(t.get("accept"), False))
        fields["o"] = e.get("objectivesText") or pick(t.get("objectives"), True) or pick(t.get("objectives"), False)
        fields = {k: v for k, v in fields.items() if v and str(v).strip()}
        if set(fields) - {"t"}:
            counts.update(fields.keys())
            counts["quests"] += 1
            lines.append(f"  [{q}]={{{','.join(f'{k}={lua_str(v)}' for k, v in fields.items())}}},")

    today = datetime.date.today().isoformat()
    text = "\n".join([
        "-- Quest text (c) Blizzard Entertainment. It is NOT covered by Plotline's licence (GPL-3.0):",
        "-- see NOTICE.md beside this file. Never commit this file; it is built for local tests and releases.",
        f"-- Built {today} by pipeline/build_quest_text.py from {source_commits()}.",
        "-- Collected by Efficient Games (https://efficient.games), whose compilation is licensed under",
        "-- CC BY 4.0, with gaps filled from Spoken (github.com/rusty-key/spoken-wow), from vmangos.",
        "--",
        "-- quests[id] = { t title, d description, o objectives }",
        "-- Placeholders are the game's: $N name, $C class, $R race, $g male:female; $B line break.",
        "PlotlineQuestText = {",
        f' built = "{today}",',
        ' locale = "enUS",',
        " quests = {",
        *lines,
        " },",
        "}",
        "",
    ])
    os.makedirs(os.path.dirname(a.out), exist_ok=True)
    with open(a.out, "w", encoding="utf-8") as f:
        f.write(text)
    known = len(g.known)
    print(f"Wrote {os.path.relpath(a.out)}: {counts['quests']} of {known} known quests, {len(text) // 1024} KB "
          f"(git-ignored: never commit).")
    for k, label in (("t", "title"), ("d", "description"), ("o", "objectives")):
        print(f"  {label}: {counts[k]}")


if __name__ == "__main__":
    main()

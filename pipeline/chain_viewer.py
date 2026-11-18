#!/usr/bin/env -S uv run --script
# SPDX-License-Identifier: GPL-3.0-or-later
# /// script
# requires-python = ">=3.10"
# dependencies = ["lupa>=2"]
# ///
"""Local viewer for checking chains and the links between their quests.

Builds the chains the same way merge_chains.py does (merge, then splitter),
then serves a page on 127.0.0.1 that lists chains by zone and name and shows
each chain step by step, one card per quest, with its details, its text and
every link in or out: which sources back it, and whether the splitter kept it.

Quest text is shown from the source submodules at runtime only. Nothing is
written to disk.

Run: uv run pipeline/chain_viewer.py [--port 8765] [--no-browser]
"""
import argparse, collections, glob, http.server, json, os, sys, threading, urllib.parse, webbrowser

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import merge_chains as mc  # noqa: E402
import split_chains as sc  # noqa: E402
from analyze_chains import zone_names  # noqa: E402

PAGE = os.path.join(HERE, "viewer", "index.html")

# Turn-in grids: an item word in a quest title -> the gear slot it is (the grid's columns).
SLOTS = {
    "Head": "helmet helm tiara crown circlet diadem headpiece cowl hood mask cap faceguard headdress",
    "Shoulders": "pauldrons spaulders mantle shoulders shoulderpads epaulets amice",
    "Chest": "breastplate robes robe vest tunic chestguard chestpiece hauberk raiment vestments",
    "Wrist": "bracers wristguards bindings bracelets wristwraps",
    "Hands": "gauntlets gloves handguards grips handwraps",
    "Waist": "waistguard belt girdle cinch sash cord",
    "Legs": "legplates legguards leggings trousers pants kilt breeches",
    "Feet": "sabatons boots greaves footwraps footguards sandals treads stompers slippers walkers",
    "Finger": "ring band signet",
}
SLOT_OF = {w: slot for slot, words in SLOTS.items() for w in words.split()}
SLOT_ORDER = list(SLOTS)
CLASS_ORDER = [sc.CLASSES[b] for b in sorted(sc.CLASSES)]


def slot_of(title):
    for word in reversed((title or "").replace("'s", "").split()):
        if word.lower() in SLOT_OF:
            return SLOT_OF[word.lower()]
    return None


def load_eg_text(root):
    """Text and levels per quest from EG Link, newest build winning."""
    files = sorted(glob.glob(os.path.join(root, "data", "wowf", "*", "quests.enUS.json")), key=mc.build_key)
    out = {}
    for f in files:
        for k, v in json.load(open(f, encoding="utf-8"))["quests"].items():
            out[int(k)] = {key: v.get(key) for key in
                           ("level", "minLevel", "objectivesText", "description", "completionText",
                            "areaDescription", "zoneAreaId", "categoryId")}
    return out


class Data:
    def __init__(self, a):
        print("Loading sources...", flush=True)
        g = mc.build_graph(a)
        kept, removed, turnins = sc.split(g)
        self.turnins = turnins  # parent quest -> leaf turn-in quests
        self.g = g
        self.chains = mc.make_chains(g, kept, turnins)
        self.by_id = {c["id"]: c for c in self.chains}
        self.chain_of = {}
        for c in self.chains:
            for q in c["quests"] + c["turnins"]:
                self.chain_of[q] = c["id"]
        self.removed = {(r["from"], r["to"]): r["rule"] for r in removed}
        self.anchored = {q for c in self.chains for q in c["anchored"]}
        self.links_out, self.links_in = collections.defaultdict(list), collections.defaultdict(list)
        for p, n in g.seq:
            self.links_out[p].append(n)
            self.links_in[n].append(p)
        self.zones = zone_names(a.spoken)
        self.eg_text = load_eg_text(a.eglink)
        try:
            st = mc.LUA.globals()["SpokenQuestsText"]
            self.sp_text = {int(k): {"accept": st[k]["accept"], "complete": st[k]["complete"]}
                            for k in st.keys()}
        except Exception:
            self.sp_text = {}
        self.index = self._index()
        print(f"Ready: {len(self.chains)} chains, {len(g.known)} quests.", flush=True)

    # ---------------------------------------------------------------- views
    def zone_list(self, q):
        return [self.zones.get(z, f"map {z}") for z in self.g.spoken.get(q, {}).get("zones", [])]

    def _index(self):
        zone_count = collections.Counter()
        rows = []
        for c in self.chains:
            members = c["quests"]
            zs = collections.Counter(z for m in members for z in self.zone_list(m))
            for z in zs:
                zone_count[z] += 1
            fac = collections.Counter(sc.faction(sc.race_mask(self.g, m)).split(":")[0] for m in members)
            removed_here = sum(1 for (p, n), rule in self.removed.items() if rule != "turn_in" and
                               c["id"] in (self.chain_of.get(p), self.chain_of.get(n)))
            rows.append({
                "id": c["id"], "name": c["name"], "size": c["size"], "length": c["length"],
                "turnins": len(c["turnins"]), "zones": [z for z, _ in zs.most_common(3)],
                "flags": c["flags"], "split_from": c["split_from"], "factions": dict(fac),
                "removed_links": removed_here, "text_coverage": c["text_coverage"],
                "titles": sorted({self.g.names.get(m) or "" for m in members}),
            })
        return {"chains": rows, "zones": sorted(zone_count.items()),
                "stats": {"chains": len(self.chains), "quests": len(self.g.known),
                          "removed_links": len(self.removed)}}

    def link(self, p, n, other):
        e = self.g.seq[(p, n)]
        return {"id": other, "title": self.g.names.get(other), "chain": self.chain_of.get(other),
                "sources": sorted(e["sources"]), "conf": e["conf"],
                "removed": self.removed.get((p, n))}

    def card(self, q):
        g = self.g
        eg, sp = self.eg_text.get(q, {}), self.sp_text.get(q, {})
        cat = sc.category(g, q)
        have = [s for s, ok in (("questie", q in g.base), ("questie-forever", q in g.delta),
                                ("spoken", q in g.spoken), ("eglink", q in g.eg)) if ok]
        return {
            "id": q, "title": g.names.get(q), "chain": self.chain_of.get(q),
            "level": eg.get("level"), "minLevel": eg.get("minLevel"),
            "faction": sc.faction(sc.race_mask(g, q)),
            "classes": sc.class_names(sc.class_mask(g, q)),
            "category": sc.QUEST_SORT.get(cat, cat) if cat else None,
            "zones": self.zone_list(q), "dungeon": bool(g.spoken.get(q, {}).get("dungeon")),
            "known_to": have, "era": sc.era(q), "served": g.served.get(q),
            "anchored": q in self.anchored,
            "text": {"objectives": eg.get("objectivesText"), "description": eg.get("description"),
                     "completion": eg.get("completionText"),
                     "accept": sp.get("accept"), "complete": sp.get("complete")},
            "links_in": [self.link(p, q, p) for p in sorted(self.links_in[q])],
            "links_out": [self.link(q, n, n) for n in sorted(self.links_out[q])],
        }

    def chain(self, cid):
        c = self.by_id.get(cid)
        if not c:
            return None
        steps = [[{"title": grp["title"], "variants": [self.card(q) for q in grp["quests"]]}
                  for grp in layer] for layer in c["steps"]]
        siblings = [{"id": o["id"], "name": o["name"], "size": o["size"]} for o in self.chains
                    if c["split_from"] and o["split_from"] == c["split_from"] and o["id"] != cid]
        meta = {k: c[k] for k in ("id", "name", "size", "length", "flags", "split_from", "text_coverage")}
        meta["zones"] = self.index["chains"][self.chains.index(c)]["zones"]
        members = set(c["quests"])
        turnins = {p: self.turnin_group(p) for p in sorted(members) if p in self.turnins}
        return {"chain": meta, "steps": steps, "turnins": turnins, "siblings": siblings}

    def turnin_group(self, parent):
        """A parent's turn-ins as a class x item grid, with a summary and anything odd."""
        g = self.g
        items = []
        for q in self.turnins[parent]:
            classes = sc.class_names(sc.class_mask(g, q))
            title = g.names.get(q) or str(q)
            items.append({"id": q, "title": title, "row": " / ".join(classes) or "Any class",
                          "col": slot_of(title) or title, "faction": sc.faction(sc.race_mask(g, q)),
                          "era": sc.era(q), "served": g.served.get(q),
                          "sources": sorted(g.seq[(parent, q)]["sources"])})
        # a column only one row uses (a lone quest that isn't part of the set) goes under "Other"
        rows_per_col = collections.defaultdict(set)
        for i in items:
            rows_per_col[i["col"]].add(i["row"])
        if len({i["row"] for i in items}) > 1:
            for i in items:
                if len(rows_per_col[i["col"]]) == 1 and len(rows_per_col) > 1:
                    i["col"] = "Other"
        cols = sorted({i["col"] for i in items},
                      key=lambda c: (SLOT_ORDER.index(c) if c in SLOT_ORDER else len(SLOT_ORDER), c))
        rows = sorted({i["row"] for i in items},
                      key=lambda r: (CLASS_ORDER.index(r) if r in CLASS_ORDER else len(CLASS_ORDER), r))
        cells = collections.defaultdict(list)
        for i in items:
            cells[f"{i['row']}|{i['col']}"].append(i)
        src = collections.Counter("+".join(i["sources"]) for i in items)
        usual = src.most_common(1)[0][0]
        odd, gaps = [], []
        set_cols = [c for c in cols if c != "Other"]
        for i in items:
            if i["col"] == "Other":
                odd.append(f"#{i['id']} {i['title']} ({i['row']}) doesn't fit the grid")
        if len(rows) > 1 and len(set_cols) > 1:
            for r in rows:
                if sum(1 for c in set_cols if f"{r}|{c}" in cells) < 2:
                    continue  # a row with a lone quest: already reported above
                missing = [c for c in set_cols if f"{r}|{c}" not in cells]
                gaps += [f"{r}|{c}" for c in missing]
                if missing:
                    odd.append(f"{r}: no {', '.join(missing)}")
        for i in items:
            if "+".join(i["sources"]) != usual:
                odd.append(f"#{i['id']} {i['title']}: linked by {', '.join(i['sources'])} (most: {usual.replace('+', ', ')})")
        gone = sum(1 for i in items if i["served"] is False)
        if gone:
            odd.append(f"none of the {len(items)} is served by the Forever server" if gone == len(items)
                       else f"{gone} of {len(items)} not served by the Forever server")
        eras = collections.Counter(i["era"] for i in items)
        if len(eras) > 1:
            odd.append(f"mixes Classic ({eras['classic']}) and Forever ({eras['forever']}) quest IDs")
        return {"parent": parent, "parent_title": g.names.get(parent), "rows": rows, "cols": cols,
                "cells": cells, "gaps": gaps, "count": len(items), "sources": dict(src.most_common()),
                "not_served": sum(1 for i in items if i["served"] is False),
                "eras": dict(eras), "odd": odd}

    def search(self, text):
        text = text.strip().lower()
        if not text:
            return []
        hits = []
        for q in sorted(self.g.known):
            t = (self.g.names.get(q) or "")
            if text == str(q) or text in t.lower():
                hits.append({"id": q, "title": t, "chain": self.chain_of.get(q),
                             "zones": self.zone_list(q)[:2]})
                if len(hits) >= 60:
                    break
        return hits


def serve(data, port, open_browser):
    class Handler(http.server.BaseHTTPRequestHandler):
        def send(self, code, body, ctype="application/json; charset=utf-8"):
            raw = body if isinstance(body, bytes) else json.dumps(body).encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(raw)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(raw)

        def do_GET(self):
            url = urllib.parse.urlparse(self.path)
            qs = urllib.parse.parse_qs(url.query)
            arg = lambda k: (qs.get(k) or [""])[0]
            if url.path in ("/", "/index.html"):
                return self.send(200, open(PAGE, "rb").read(), "text/html; charset=utf-8")
            if url.path == "/api/index":
                return self.send(200, data.index)
            if url.path == "/api/chain":
                c = data.chain(arg("id"))
                return self.send(200, c) if c else self.send(404, {"error": "no such chain"})
            if url.path == "/api/quest":
                try:
                    q = int(arg("id"))
                except ValueError:
                    return self.send(400, {"error": "bad id"})
                if q not in data.g.known:
                    return self.send(404, {"error": "unknown quest"})
                return self.send(200, data.card(q))
            if url.path == "/api/search":
                return self.send(200, data.search(arg("q")))
            self.send(404, {"error": "not found"})

        def log_message(self, *args):
            pass

    httpd = http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler)
    url = f"http://127.0.0.1:{port}/"
    print(f"Chain viewer at {url}  (Ctrl+C to stop)", flush=True)
    if open_browser:
        threading.Timer(0.5, webbrowser.open, [url]).start()
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--questiedb", default=os.path.join(mc.SOURCES, "QuestieDB"))
    ap.add_argument("--spoken", default=os.path.join(mc.SOURCES, "spoken-wow"))
    ap.add_argument("--eglink", default=os.path.join(mc.SOURCES, "eg-link-output-wowf"))
    ap.add_argument("--min-trace-conf", type=int, default=0)
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--no-browser", action="store_true")
    a = ap.parse_args()
    serve(Data(a), a.port, not a.no_browser)


if __name__ == "__main__":
    main()

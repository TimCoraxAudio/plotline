#!/usr/bin/env -S uv run --script
# SPDX-License-Identifier: GPL-3.0-or-later
# /// script
# requires-python = ">=3.10"
# dependencies = ["lupa>=2", "anthropic>=2.11"]
# ///
"""LLM first pass at sagas: storylines that run across chains (docs/STORYLINES.md, step 2-3).

Reads the candidate groups from saga_candidates.py, sends each to Claude with the quest text,
and asks which units (chains or loose quests) tell one story, in what order, and how they're
linked. Every draft carries two explanations: `reason` (may spoil; hidden in the review page until
you click) and `reason_safe` (for a reviewer who hasn't played the quests). A second pass checks
that `reason_safe` gives nothing away, and rewrites it if it does (twice at most).

Steps (each resumable; state lives in pipeline/out/sagas/, git-ignored):

  prepare   build the requests from pipeline/out/saga_candidates.json and print a cost estimate.
            Nothing is sent. Run saga_candidates.py first.
  run       send what's due: drafts, then spoiler checks, then rewrites. By default as Message
            Batches (half price; most finish within an hour); --wait polls until each is done.
            --sync sends one request at a time instead (with server-side refusal fallbacks), for a
            pilot: --only <request id> [--only ...] or --limit N.
  status    where each request is.
  apply     write approved drafts (pipeline/review/sagas.json, set in the viewer's /sagas page) into
            addon/Plotline/Data/Sagas.lua, between the LLM markers. Hand-written sagas are kept.

The quest text goes to the API and into pipeline/out/ only; it is never written into the repo.
Needs an Anthropic API key (ANTHROPIC_API_KEY, or an `ant auth login` profile).

Run: uv run pipeline/draft_sagas.py prepare   (after: uv run pipeline/saga_candidates.py)
"""
import argparse, collections, datetime, hashlib, json, os, re, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import merge_chains as mc  # noqa: E402
import split_chains as sc  # noqa: E402
import build_addon_data as bd  # noqa: E402
from saga_candidates import quest_texts  # noqa: E402

OUT = os.path.join(HERE, "out", "sagas")
CANDIDATES = os.path.join(HERE, "out", "saga_candidates.json")
REVIEW = os.path.join(HERE, "review", "sagas.json")
SAGAS_LUA = os.path.join(HERE, "..", "addon", "Plotline", "Data", "Sagas.lua")

MODEL = "claude-opus-5-5"
PRICE_IN, PRICE_OUT = 4.00, 20.00          # $ per million tokens, standard; batches are half
FALLBACK_BETA = "server-side-fallback-2026-07-01"
MAX_REWRITES = 2
MAX_UNITS = 40                             # bigger candidate groups are split by class/era first
CLASS_NAMES = {61: "Warlock", 81: "Warrior", 82: "Shaman", 141: "Paladin", 161: "Mage", 162: "Rogue",
               261: "Hunter", 262: "Priest", 263: "Druid"}
LINK_KINDS = ["continues", "references", "same_cast", "unlocked_by"]
SPOILER_KINDS = ["none", "outcome", "twist", "identity", "death", "betrayal", "ending", "other"]

SYSTEM = """You help build Plotline, an add-on for World of Warcraft (the Forever realm) that keeps a \
journal of the quest storylines a player has done.

Quest chains were built automatically from quest links (one quest leads to the next). Some stories \
run across several chains that no quest link joins: a letter arrives levels later, a character \
returns, an item from one chain turns out to matter in another. Plotline calls such a storyline a \
saga. You'll be shown a group of units. A unit is a chain (quests in step order) or a single quest \
in no chain. They were grouped by cheap signals (shared names, quest givers, items, class), so many \
groups hold units that only look related.

Two units belong to one saga when the story connects them: the same named characters with an \
ongoing plot, one unit picking up events, items or threads from another, or one explicitly leading \
to the other. Sharing only a zone, a town, a faction, a class trainer or a quest giver who hands out \
unrelated jobs is not enough. Filler (kill or collect with no plot) joins a saga only if the text \
ties it in."""

DRAFT_TASK = """Decide which of these units form sagas.

For each saga, give:
- units: the unit IDs in story order (two or more; a unit belongs to at most one saga).
- links: how the units connect, each from an earlier unit to a later one. Kinds: "continues" (the \
later unit picks up where the earlier left off), "references" (it mentions people, events or \
items of the earlier one), "same_cast" (the same characters, no direct continuation), \
"unlocked_by" (the earlier one must be done first, or gives what starts the later one).
- confidence: "high" when the text states the connection, "medium" when it is very likely, "low" \
when it is a guess.
- evidence: quest IDs whose text shows the connection.
- reason: your full explanation, citing quest IDs. It may mention anything, spoilers included; \
the reviewer sees it only on request.
- reason_safe: at most 200 characters, for a reviewer who has NOT played these quests. Say what \
kind of connection it is using only what a player knows when starting each unit: who asks, where, \
what they are first asked to do. Never reveal how anything turns out: no outcomes, deaths, \
betrayals, twists, true identities, who is behind events, or how a unit ends. Prefer vague over \
revealing, e.g. "The same informant contacts you again, ten levels later, about the same \
artifact."

If nothing here forms a saga, return an empty list. Don't stretch: a wrong link is worse than a \
missed one."""

CHECK_TASK = """A reviewer who has not played these quests will read the line below. Does it reveal \
anything a player would only learn by playing on: how a quest or chain turns out, a death, a \
betrayal, a twist, someone's true identity, who is behind events, or how a unit ends? Mentioning \
who asks, where, and what the player is first asked to do is fine.

Line: {line}

Answer with reveals (true or false) and the kind of reveal ("none" if it reveals nothing)."""

REWRITE_TASK = """This line was meant for a reviewer who has not played these quests, but it gives \
something away ({kind}):

{line}

Full explanation, for your eyes only:
{reason}

Write a new line, at most 200 characters, that says what kind of connection links these units \
using only what a player knows when starting each unit. Prefer vague over revealing."""


# ------------------------------------------------------------------ helpers
def load_json(path, default):
    if os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    return default


def save_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=1, ensure_ascii=False)
    os.replace(tmp, path)


def draft_key(units):
    """Stable ID for a draft: the same set of units gets the same ID in every run, so a decision
    (approve / reject) sticks."""
    return "s" + hashlib.sha1("|".join(sorted(units)).encode()).hexdigest()[:10]


def schema(props, required=None):
    return {"type": "object", "additionalProperties": False,
            "required": required or list(props), "properties": props}


def draft_schema(unit_ids, quest_ids):
    uid = {"type": "string", "enum": unit_ids}
    return schema({"sagas": {"type": "array", "items": schema({
        "units": {"type": "array", "items": uid},
        "links": {"type": "array", "items": schema({"from": uid, "to": uid,
                                                    "kind": {"type": "string", "enum": LINK_KINDS}})},
        "confidence": {"type": "string", "enum": ["high", "medium", "low"]},
        "evidence": {"type": "array", "items": {"type": "integer", "enum": quest_ids}},
        "reason": {"type": "string"},
        "reason_safe": {"type": "string"},
    })}})


CHECK_SCHEMA = schema({"reveals": {"type": "boolean"}, "kind": {"type": "string", "enum": SPOILER_KINDS}})
REWRITE_SCHEMA = schema({"reason_safe": {"type": "string"}})


# ------------------------------------------------------------------ prepare
def unit_block(u, g, texts, facts):
    """One unit as the model sees it: its quests in step order with their text."""
    lv = u.get("levels")
    attrs = [f'id="{u["id"]}"', f'kind="{u["kind"]}"']
    if lv:
        attrs.append(f'levels="{lv[0]}-{lv[1]}"' if lv[0] != lv[1] else f'level="{lv[0]}"')
    if u.get("class"):
        attrs.append(f'class="{CLASS_NAMES[u["class"]]}"')
    lines = [f"<unit {' '.join(attrs)}>"]
    for step, q in u["order"]:
        t = texts.get(q, {})
        qa = [f'id="{q}"', f'title="{g.names.get(q) or "?"}"']
        if step:
            qa.append(f'step="{step}"')
        if facts.get(q, {}).get("l"):
            qa.append(f'level="{facts[q]["l"]}"')
        body = "".join(f"<{k}>{v.strip()}</{k}>" for k, v in t.items() if v and v.strip())
        lines.append(f"  <quest {' '.join(qa)}>{body or '<no_text/>'}</quest>")
    lines.append("</unit>")
    return "\n".join(lines)


def prepare(a):
    if not os.path.exists(CANDIDATES):
        sys.exit("No pipeline/out/saga_candidates.json: run uv run pipeline/saga_candidates.py first.")
    cand = load_json(CANDIDATES, {})
    units = cand["units"]
    g = mc.build_graph(a)
    sp = sc.split(g)
    chains = {c["id"]: c for c in mc.make_chains(g, sp)}
    facts = bd.quest_facts(a)
    texts = quest_texts(a)
    for uid, u in units.items():
        c = chains.get(uid)
        if c:
            order = [(i + 1, q) for i, layer in enumerate(c["steps"]) for grp in layer for q in grp["quests"]]
            seen = {q for _, q in order}
            order += [(None, q) for q in c["side_quests"] + c["turnins"] if q not in seen]
            u["order"] = order
            u["nq"] = bd.name_quest(g, c)
        else:
            u["order"] = [(None, u["quests"][0])]
            u["nq"] = u["quests"][0]

    # groups to ask about: candidate groups, plus each class's units by era (the class signal alone
    # is too weak for a candidate pair, but a class's own story is the main case: see the Rogue saga)
    groups = []
    for gr in cand["groups"]:
        groups.append({"why": "candidates", "units": gr["units"]})
    for cls, us in cand["classes"].items():
        for era in ("forever", "classic"):
            sel = [u for u in us if all(sc.era(q) == era for q in units[u]["quests"])]
            for i in range(0, len(sel), MAX_UNITS):
                part = sel[i:i + MAX_UNITS]
                if len(part) >= 2:
                    groups.append({"why": f"class {CLASS_NAMES[int(cls)]} ({era})", "units": part})
    # drop a group that another group fully contains
    sets = [set(gr["units"]) for gr in groups]
    keep = [gr for i, gr in enumerate(groups)
            if not any(j != i and sets[i] <= sets[j] and (sets[i] != sets[j] or j < i) for j in range(len(sets)))]

    # signals between units, for the review page (blind approval needs 2+ kinds)
    signals = collections.defaultdict(set)
    for r in cand["pairs"]:
        for k in r["signals"]:
            signals[f'{r["a"]}|{r["b"]}'].add(k)

    requests = {}
    for gr in sorted(keep, key=lambda gr: (-len(gr["units"]), gr["units"][0])):
        rid = "g" + hashlib.sha1("|".join(sorted(gr["units"])).encode()).hexdigest()[:8]   # stable across runs
        us = sorted(gr["units"], key=lambda u: ((units[u]["levels"] or [0])[0], u))
        block = "\n\n".join(unit_block(units[u], g, texts, facts) for u in us)
        qids = sorted({q for u in us for _, q in units[u]["order"]})
        requests[rid] = {"why": gr["why"], "units": us, "content": block, "quest_ids": qids}
    meta = {"units": {uid: {k: u[k] for k in ("id", "kind", "name", "levels", "class", "nq", "quests")}
                      for uid, u in units.items()},
            "signals": {k: sorted(v) for k, v in signals.items()},
            "built": datetime.date.today().isoformat()}
    save_json(os.path.join(OUT, "requests.json"), requests)
    save_json(os.path.join(OUT, "meta.json"), meta)
    state = load_json(os.path.join(OUT, "state.json"), {"requests": {}, "batches": []})
    for rid in requests:
        state["requests"].setdefault(rid, {"phase": "draft"})
    save_json(os.path.join(OUT, "state.json"), state)

    # cost estimate: ~4 characters a token for the text; drafts write ~1.5k tokens (thinking included)
    sys_tok = len(SYSTEM) // 4
    tin = sum(len(r["content"]) // 4 + sys_tok + 600 for r in requests.values())
    draft_out = 1500 * len(requests)
    check_in = tin * 0.4                     # checks and rewrites only for groups that yield a saga
    est = ((tin + check_in) * PRICE_IN + (draft_out + 300 * len(requests)) * PRICE_OUT) / 1e6
    biggest = max(requests.values(), key=lambda r: len(r["content"]))
    print(f"Wrote {len(requests)} requests to pipeline/out/sagas/requests.json "
          f"({sum(1 for r in requests.values() if r['why'] == 'candidates')} candidate groups, "
          f"{sum(1 for r in requests.values() if r['why'] != 'candidates')} class groups).")
    print(f"Input ~{tin / 1e6:.2f}M tokens (largest request ~{len(biggest['content']) // 4 // 1000}k). "
          f"Estimated cost with {MODEL}: ~${est / 2:.0f} as batches, ~${est:.0f} with --sync. "
          f"(A rough estimate: ~4 characters a token.)")


# ------------------------------------------------------------------ requests
def params_for(rid, r, st, phase):
    """Messages API parameters for one request in the given phase."""
    content = [{"type": "text", "text": "<units>\n" + r["content"] + "\n</units>",
                "cache_control": {"type": "ephemeral"}}]
    if phase == "draft":
        task, fmt, effort = DRAFT_TASK, draft_schema(r["units"], r["quest_ids"]), "high"
    elif phase == "check":
        task = CHECK_TASK.format(line=st["draft"]["reason_safe"])
        fmt, effort = CHECK_SCHEMA, "medium"
    else:
        task = REWRITE_TASK.format(kind=st["draft"]["spoiler"], line=st["draft"]["reason_safe"],
                                   reason=st["draft"]["reason"])
        fmt, effort = REWRITE_SCHEMA, "medium"
    content.append({"type": "text", "text": task})
    return {"model": MODEL, "max_tokens": 16000, "system": SYSTEM,
            "messages": [{"role": "user", "content": content}],
            "output_config": {"effort": effort, "format": {"type": "json_schema", "schema": fmt}}}


def work_items(state, requests):
    """(custom id, request id, draft index, phase) for everything due now."""
    items = []
    for rid, st in state["requests"].items():
        if rid not in requests:
            continue
        if st["phase"] == "draft":
            items.append((rid, rid, None, "draft"))
        elif st["phase"] == "checks":
            for i, d in enumerate(st["drafts"]):
                if d.get("todo") in ("check", "rewrite"):
                    items.append((f"{rid}-{i}-{d['todo']}{d.get('round', 0)}", rid, i, d["todo"]))
    return items


def apply_result(state, requests, rid, i, phase, msg, err=None):
    """Record one response. msg: the Message (or None with err)."""
    st = state["requests"][rid]

    def fail(why, refused=False):
        st.setdefault("errors", []).append(f"{phase}: {why}")
        target = st if i is None else st["drafts"][i]
        target["attempts"] = target.get("attempts", 0) + 1
        if refused or target["attempts"] >= 3:        # stop resending; --retry-refused picks refusals up
            if i is None:
                st["phase"] = "refused" if refused else "failed"
            else:
                target["todo"], target["safe"] = None, False
                target["refused"] = refused or None
                if not any(x.get("todo") for x in st["drafts"]):
                    st["phase"] = "done"

    if err or msg is None:
        return fail(err)
    if msg.stop_reason == "refusal":
        cat = getattr(getattr(msg, "stop_details", None), "category", None)
        return fail(f"refused ({cat})", refused=True)
    if msg.stop_reason == "max_tokens":
        return fail("hit max_tokens")
    text = next((b.text for b in msg.content if b.type == "text"), "")
    try:
        data = json.loads(text)
    except json.JSONDecodeError as e:
        return fail(f"bad JSON ({e})")
    usage = st.setdefault("usage", {"in": 0, "out": 0})
    usage["in"] += (msg.usage.input_tokens or 0) + (msg.usage.cache_read_input_tokens or 0) \
        + (msg.usage.cache_creation_input_tokens or 0)
    usage["out"] += msg.usage.output_tokens or 0
    if phase == "draft":
        allowed = set(requests[rid]["units"])
        drafts, used = [], set()
        for s in data.get("sagas", []):
            us = [u for u in dict.fromkeys(s["units"]) if u in allowed and u not in used]
            if len(us) < 2:
                continue
            used |= set(us)
            drafts.append({"id": draft_key(us), "units": us, "confidence": s["confidence"],
                           "links": [l for l in s["links"] if l["from"] in us and l["to"] in us],
                           "evidence": s["evidence"], "reason": s["reason"],
                           "reason_safe": s["reason_safe"][:240], "todo": "check", "round": 0})
        st["drafts"], st["phase"] = drafts, ("checks" if drafts else "done")
    else:
        d = st["drafts"][i]
        if phase == "check":
            if data["reveals"]:
                d["spoiler"] = data["kind"] if data["kind"] != "none" else "other"
                d["todo"] = "rewrite" if d["round"] < MAX_REWRITES else None
                d["safe"] = False
            else:
                d["todo"], d["safe"], d["spoiler"] = None, True, None
        else:
            d["reason_safe"] = data["reason_safe"][:240]
            d["round"] += 1
            d["todo"] = "check"
        if not any(x.get("todo") for x in st["drafts"]):
            st["phase"] = "done"


def client():
    import anthropic
    return anthropic.Anthropic()


def run_sync(a, state, requests):
    import anthropic
    cl = client()
    if a.retry_refused:   # the batch can't use refusal fallbacks; these calls do
        for st in state["requests"].values():
            if st["phase"] == "refused":
                st["phase"], st["attempts"] = "draft", 0
            for d in st.get("drafts", []):
                if d.get("refused"):
                    d["refused"], d["attempts"], d["todo"] = None, 0, "check"
                    st["phase"] = "checks"
    items = [it for it in work_items(state, requests) if not a.only or it[1] in a.only]
    rounds = 0
    while items and rounds < 2 * MAX_REWRITES + 3:
        if a.limit:
            items = items[:a.limit]
        for cid, rid, i, phase in items:
            p = params_for(rid, requests[rid], state["requests"][rid] if i is None
                           else {"draft": state["requests"][rid]["drafts"][i]}, phase)
            try:
                msg = cl.beta.messages.create(**p, betas=[FALLBACK_BETA], fallbacks="default")
                apply_result(state, requests, rid, i, phase, msg)
            except anthropic.BadRequestError as e:
                apply_result(state, requests, rid, i, phase, None, f"bad request: {e.message}")
            except anthropic.RateLimitError:
                print("Rate limited; stopping here. Run again to continue.")
                save_state(state)
                return
            except anthropic.APIStatusError as e:
                apply_result(state, requests, rid, i, phase, None, f"API error {e.status_code}")
            except anthropic.APIConnectionError:
                print("Network error; stopping here. Run again to continue.")
                save_state(state)
                return
            save_state(state)
            print(f"  {cid}: {phase} done -> {state['requests'][rid]['phase']}")
        items = [it for it in work_items(state, requests) if not a.only or it[1] in a.only]
        rounds += 1


def run_batch(a, state, requests):
    from anthropic.types.message_create_params import MessageCreateParamsNonStreaming
    from anthropic.types.messages.batch_create_params import Request
    cl = client()
    while True:
        open_batches = [b for b in state["batches"] if not b.get("collected")]
        for b in open_batches:
            got = cl.messages.batches.retrieve(b["id"])
            if got.processing_status != "ended":
                print(f"Batch {b['id']} ({b['phase']}): {got.processing_status}, "
                      f"{got.request_counts.processing} processing, {got.request_counts.succeeded} done.")
                continue
            for res in cl.messages.batches.results(b["id"]):
                rid, i, phase = b["items"][res.custom_id]
                if res.result.type == "succeeded":
                    apply_result(state, requests, rid, i, phase, res.result.message)
                else:
                    apply_result(state, requests, rid, i, phase, None, res.result.type)
            b["collected"] = True
            save_state(state)
            print(f"Collected batch {b['id']} ({b['phase']}).")
        if any(not b.get("collected") for b in state["batches"]):
            if not a.wait:
                print("Batches still running. Run again (or with --wait) to collect them.")
                return
            time.sleep(60)
            continue
        items = work_items(state, requests)
        if a.limit:
            items = items[:a.limit]
        if not items:
            print("Nothing left to send.")
            return
        reqs, index = [], {}
        for cid, rid, i, phase in items:
            st = state["requests"][rid] if i is None else {"draft": state["requests"][rid]["drafts"][i]}
            reqs.append(Request(custom_id=cid, params=MessageCreateParamsNonStreaming(**params_for(rid, requests[rid], st, phase))))
            index[cid] = (rid, i, phase)
        batch = cl.messages.batches.create(requests=reqs)
        phases = collections.Counter(p for *_, p in items)
        state["batches"].append({"id": batch.id, "phase": dict(phases), "items": index,
                                 "sent": datetime.datetime.now().isoformat(timespec="seconds")})
        save_state(state)
        print(f"Sent batch {batch.id}: {dict(phases)}.")
        if not a.wait:
            return


def save_state(state):
    save_json(os.path.join(OUT, "state.json"), state)


def drafts_file(state, requests):
    """Every finished draft, for the review page: pipeline/out/sagas/drafts.json."""
    meta = load_json(os.path.join(OUT, "meta.json"), {})
    out = {}
    for rid, st in state["requests"].items():
        for d in st.get("drafts", []):
            if d.get("todo"):
                continue
            us = d["units"]
            kinds = set()
            for x in range(len(us)):
                for y in range(x + 1, len(us)):
                    kinds |= set(meta.get("signals", {}).get("|".join(sorted((us[x], us[y]))), []))
            out[d["id"]] = {**{k: d[k] for k in ("id", "units", "confidence", "links", "evidence", "reason",
                                                 "reason_safe", "safe", "spoiler")},
                            "request": rid, "why": requests.get(rid, {}).get("why"), "signals": sorted(kinds),
                            "blind_ok": d["confidence"] == "high" and len(kinds - {"class"}) >= 2}
    save_json(os.path.join(OUT, "drafts.json"), out)
    return out


def run(a):
    requests = load_json(os.path.join(OUT, "requests.json"), None)
    if not requests:
        sys.exit("Run prepare first.")
    state = load_json(os.path.join(OUT, "state.json"), {"requests": {}, "batches": []})
    (run_sync if a.sync else run_batch)(a, state, requests)
    d = drafts_file(state, requests)
    print(f"{len(d)} drafts ready for review in pipeline/out/sagas/drafts.json "
          "(open the viewer's /sagas page: uv run pipeline/chain_viewer.py).")


def status(a):
    requests = load_json(os.path.join(OUT, "requests.json"), {})
    state = load_json(os.path.join(OUT, "state.json"), {"requests": {}, "batches": []})
    phases = collections.Counter(st["phase"] for rid, st in state["requests"].items() if rid in requests)
    drafts = [d for st in state["requests"].values() for d in st.get("drafts", [])]
    errors = [(rid, e) for rid, st in state["requests"].items() for e in st.get("errors", [])]
    used = [st.get("usage", {"in": 0, "out": 0}) for st in state["requests"].values()]
    tin, tout = sum(u["in"] for u in used), sum(u["out"] for u in used)
    print(f"Requests: {dict(phases)}. Drafts: {len(drafts)} "
          f"({sum(1 for d in drafts if d.get('safe'))} with a spoiler-checked line, "
          f"{sum(1 for d in drafts if d.get('safe') is False and not d.get('todo'))} that failed the check). "
          f"Batches: {len(state['batches'])} ({sum(1 for b in state['batches'] if not b.get('collected'))} open).")
    print(f"Tokens so far: {tin / 1e6:.2f}M in, {tout / 1e6:.2f}M out "
          f"(about ${(tin * PRICE_IN + tout * PRICE_OUT) / 2e6:.2f} at batch prices).")
    for rid, e in errors[:20]:
        print(f"  {rid}: {e}")
    if len(errors) > 20:
        print(f"  ... {len(errors) - 20} more")


# ------------------------------------------------------------------ apply
BEGIN = "    -- BEGIN LLM SAGAS (written by pipeline/draft_sagas.py apply; edit by moving an entry above)"
END = "    -- END LLM SAGAS"


def apply(a):
    review = load_json(REVIEW, {})
    drafts = load_json(os.path.join(OUT, "drafts.json"), {})
    meta = load_json(os.path.join(OUT, "meta.json"), {"units": {}})
    text = open(SAGAS_LUA, encoding="utf-8").read()
    hand = re.sub(r"(?s)" + re.escape(BEGIN) + r".*?" + re.escape(END) + r"\n?", "", text)
    taken = set(re.findall(r'chain\s*=\s*"([^"]+)"', re.sub(r"--[^\n]*", "", hand)))
    taken |= {f"q{q}" for q in re.findall(r"quest\s*=\s*(\d+)", re.sub(r"--[^\n]*", "", hand))}
    entries, skipped = [], []
    for key, r in sorted(review.items()):
        if r.get("decision") != "approve":
            continue
        d = drafts.get(key) or r
        us = d["units"]
        if set(us) & taken:
            skipped.append(key)
            continue
        taken |= set(us)
        parts = ", ".join(f'{{ chain = "{u}" }}' if not u.startswith("q") or not u[1:].isdigit()
                          else f"{{ quest = {u[1:]} }}" for u in us)
        idx = {u: i + 1 for i, u in enumerate(us)}
        links = ", ".join(f'{{ from = {idx[l["from"]]}, to = {idx[l["to"]]}, kind = "{l["kind"]}" }}'
                          for l in d.get("links", []) if l["from"] in idx and l["to"] in idx)
        nq = meta["units"].get(us[0], {}).get("nq") or r.get("nq")
        cls = {meta["units"].get(u, {}).get("class") for u in us}
        cls_id = bd.CLASS_SORTS.get(cls.pop()) if len(cls) == 1 and None not in cls else None
        entries.append(f'    ["llm-{key}"] = {{ n = {nq},{f" class = {cls_id}," if cls_id else ""} parts = {{ {parts} }},\n'
                       f'        links = {{ {links} }}, source = "llm", confidence = "{d.get("confidence")}" }},')
    block = "\n".join([BEGIN, *entries, END]) + "\n"
    # the generated block goes just before the closing brace of ns.overlay.sagas
    m = list(re.finditer(r"(?m)^}\s*$", hand))
    if not m:
        sys.exit("Couldn't find the end of ns.overlay.sagas in Data/Sagas.lua.")
    end = m[-1].start()
    with open(SAGAS_LUA, "w", encoding="utf-8") as f:
        f.write(hand[:end] + block + hand[end:])
    print(f"Wrote {len(entries)} approved sagas into {os.path.relpath(SAGAS_LUA)}."
          + (f" Skipped {len(skipped)} that overlap a saga already there: {', '.join(skipped)}." if skipped else ""))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("step", choices=["prepare", "run", "status", "apply"])
    ap.add_argument("--questiedb", default=os.path.join(mc.SOURCES, "QuestieDB"))
    ap.add_argument("--spoken", default=os.path.join(mc.SOURCES, "spoken-wow"))
    ap.add_argument("--eglink", default=os.path.join(mc.SOURCES, "eg-link-output-wowf"))
    ap.add_argument("--min-trace-conf", type=int, default=0)
    ap.add_argument("--sync", action="store_true", help="one request at a time, not batches (for pilots)")
    ap.add_argument("--wait", action="store_true", help="poll until the batches are done")
    ap.add_argument("--only", action="append", help="only this request id (g000...); repeatable")
    ap.add_argument("--limit", type=int, help="send at most this many requests")
    ap.add_argument("--retry-refused", action="store_true",
                    help="with --sync: resend requests a batch refused, with server-side fallbacks")
    a = ap.parse_args()
    {"prepare": prepare, "run": run, "status": status, "apply": apply}[a.step](a)


if __name__ == "__main__":
    main()

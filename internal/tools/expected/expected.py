#!/usr/bin/env python3 -I
"""Independent oracle for the parser eval. Writes expected.json next to a fixture.

  python3 -I internal/tools/expected/expected.py internal/testdata/sessions/<fixture-dir>

Implemented separately from the Go parser on purpose (see docs/record-anatomy.md for the rules):
usage once per requestId (model "<synthetic>" is not a request), title = last ai-title, prompts = human turns that are not tool results,
summaries or meta, images in user content and inside tool_result lists, chain = walk from
last-prompt.leafUuid (or latest timestamp) up parentUuid / logicalParentUuid.
"""
import collections, glob, json, os, sys

def main(fixture_dir):
    files = glob.glob(os.path.join(fixture_dir, "*.jsonl"))
    assert len(files) == 1, files
    recs = []
    for line in open(files[0], "rb"):
        line = line.strip()
        if not line: continue
        try: recs.append(json.loads(line))
        except Exception: recs.append({"type": "<malformed>"})
    e = dict(records=len(recs), prompts=0, turns=0, system_turns=0, requests=0, assistant_records=0, tool_calls=0, tool_results=0,
             images=0, compactions=0, api_errors=0, output_tokens=0, cache_read_input_tokens=0,
             models=collections.Counter(), tools=collections.Counter(), title="", chain_len=0)
    seen_req = set(); by_uuid = {}; leaf = None; latest = None
    for r in recs:
        t = r.get("type")
        if r.get("uuid"):
            by_uuid[r["uuid"]] = r
            ts = r.get("timestamp")
            if ts and (latest is None or ts > latest[0]): latest = (ts, r["uuid"])
        m = r.get("message") or {}
        c = m.get("content")
        blocks = c if isinstance(c, list) else ([{"type": "text", "text": c}] if isinstance(c, str) else [])
        if t == "ai-title" and r.get("aiTitle"): e["title"] = r["aiTitle"]
        elif t == "last-prompt" and r.get("leafUuid"): leaf = r["leafUuid"]
        elif t == "system":
            if r.get("subtype") == "compact_boundary": e["compactions"] += 1
            if r.get("subtype") == "api_error": e["api_errors"] += 1
        elif t == "assistant":
            e["assistant_records"] += 1
            key = r.get("requestId") or "uuid:" + r.get("uuid", "")
            if m.get("model") == "<synthetic>":
                key = None  # Claude Code's own message, not an API request
            if key is not None and key not in seen_req:
                seen_req.add(key); e["requests"] += 1; e["models"][m.get("model")] += 1
                u = m.get("usage") or {}
                e["output_tokens"] += u.get("output_tokens", 0) or 0
                e["cache_read_input_tokens"] += u.get("cache_read_input_tokens", 0) or 0
            for b in blocks:
                if b.get("type") == "tool_use": e["tool_calls"] += 1; e["tools"][b.get("name")] += 1
        elif t == "user":
            has_result = False
            for b in blocks:
                if b.get("type") == "image": e["images"] += 1
                if b.get("type") == "tool_result":
                    has_result = True; e["tool_results"] += 1
                    cc = b.get("content")
                    for x in (cc if isinstance(cc, list) else []):
                        if x.get("type") == "image": e["images"] += 1
            if not has_result and not r.get("isCompactSummary") and not r.get("isMeta") and r.get("turnOrigin"):
                if r.get("turnOrigin") == "human":
                    e["prompts"] += 1; e["turns"] += 1
                else:
                    e["system_turns"] += 1
    tip = leaf if leaf in by_uuid else (latest[1] if latest else None)
    seen = set()
    while tip and tip in by_uuid and tip not in seen:
        seen.add(tip); e["chain_len"] += 1
        r = by_uuid[tip]; tip = r.get("parentUuid") or r.get("logicalParentUuid")
    subdir = os.path.join(fixture_dir, os.path.basename(files[0])[:-6], "subagents")
    e["subagents"] = len(glob.glob(os.path.join(subdir, "*.jsonl"))) if os.path.isdir(subdir) else 0
    e["models"] = dict(e["models"]); e["tools"] = dict(e["tools"])
    out = os.path.join(fixture_dir, "expected.json")
    json.dump(e, open(out, "w"), indent=2, sort_keys=True); open(out, "a").write("\n")
    print(out, json.dumps({k: e[k] for k in ("records", "prompts", "requests", "tool_calls", "images", "compactions", "subagents", "chain_len")}))

if __name__ == "__main__":
    main(sys.argv[1])

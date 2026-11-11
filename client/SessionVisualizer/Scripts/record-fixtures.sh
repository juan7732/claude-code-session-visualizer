#!/bin/sh
# Records the /v0 responses the contract tests decode, from the engine in this
# checkout serving the synthetic-basics fixture in a throwaway home.
#
#   Scripts/record-fixtures.sh [output directory]
#
# Default output: Sources/SkitTestSupport/Fixtures. CI records into a temp directory
# and points the tests at it (SKIT_FIXTURES), so the tests always decode what
# the current engine really serves.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
repo=$(cd "$here/../.." && pwd)
out=${1:-$here/Sources/SkitTestSupport/Fixtures}
# A throwaway directory. Its path appears in the responses and is rewritten to
# /fixture below, so a recording does not depend on where it was made.
work=$(mktemp -d)
id=aaaaaaaa-0000-0000-0000-000000000001

mkdir -p "$work/home/.claude/projects/-Users-me-work" "$out"
cp -R "$repo/internal/testdata/sessions/synthetic-basics/." "$work/home/.claude/projects/-Users-me-work/"
rm -f "$work/home/.claude/projects/-Users-me-work/expected.json"
# A session Claude Code opened and never used: no prompt, no request. Real homes have several.
printf '%s\n' '{"type":"queue-operation","operation":"enqueue","sessionId":"bbbbbbbb-0000-0000-0000-000000000002","timestamp":"2026-11-08T09:00:00.000Z"}' \
  > "$work/home/.claude/projects/-Users-me-work/bbbbbbbb-0000-0000-0000-000000000002.jsonl"
# A session that reached outside the machine and committed: what the first fixture never does.
out_id=cccccccc-0000-0000-0000-000000000003
cat > "$work/home/.claude/projects/-Users-me-work/$out_id.jsonl" <<'JSONL'
{"type":"user","uuid":"u1","sessionId":"cccccccc-0000-0000-0000-000000000003","cwd":"/Users/me/work","turnOrigin":"human","timestamp":"2026-11-08T11:00:00Z","message":{"role":"user","content":"Read the docs, then commit."}}
{"type":"assistant","uuid":"a1","parentUuid":"u1","requestId":"r1","timestamp":"2026-11-08T11:00:01Z","message":{"model":"claude-fable-5-1","content":[{"type":"tool_use","id":"toolu_w1","name":"WebFetch","input":{"url":"https://docs.example.com/guide","prompt":"what does it say"}},{"type":"tool_use","id":"toolu_w2","name":"mcp__notes__search","input":{"query":"guide"}}],"usage":{"input_tokens":10,"output_tokens":5}}}
{"type":"user","uuid":"r1a","parentUuid":"a1","timestamp":"2026-11-08T11:00:02Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_w1","content":"It says hello."}]}}
{"type":"user","uuid":"r1b","parentUuid":"a1","timestamp":"2026-11-08T11:00:03Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_w2","content":"one note"}]}}
{"type":"assistant","uuid":"a2","parentUuid":"r1b","requestId":"r2","timestamp":"2026-11-08T11:00:04Z","message":{"model":"claude-fable-5-1","content":[{"type":"tool_use","id":"toolu_c1","name":"Bash","input":{"command":"git commit -am 'Add the guide'","description":"Commit the guide"}}],"usage":{"input_tokens":12,"output_tokens":5}}}
{"type":"user","uuid":"r2a","parentUuid":"a2","timestamp":"2026-11-08T11:00:05Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_c1","content":"[main 2b4b1ec] Add the guide\n 1 file changed, 3 insertions(+)"}]}}
{"type":"assistant","uuid":"a3","parentUuid":"r2a","requestId":"r3","timestamp":"2026-11-08T11:00:06Z","message":{"model":"claude-fable-5-1","stop_reason":"end_turn","content":[{"type":"text","text":"Committed as 2b4b1ec."}],"usage":{"input_tokens":14,"output_tokens":6}}}
JSONL
(cd "$repo" && CGO_ENABLED=0 go build -ldflags "-X main.version=fixture" -o "$work/skit" ./cmd/skit)

export HOME="$work/home"
# Times in the Markdown export are local: record them the same everywhere.
export TZ=UTC
unset SKIT_HOME CLAUDE_CONFIG_DIR
sock="$work/s.sock"
"$work/skit" serve --socket "$sock" --no-watch --quiet 2>"$work/serve.log" &
pid=$!
trap 'kill $pid 2>/dev/null; rm -rf "$work"' EXIT
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do [ -S "$sock" ] && break; sleep 0.1; done
[ -S "$sock" ] || { cat "$work/serve.log" >&2; exit 1; }

get() { curl -sS --fail-with-body --unix-socket "$sock" "http://skit$1" -o "$out/$2"; }
send() { curl -sS --fail-with-body --unix-socket "$sock" -X "$1" -d "$3" "http://skit$2" -o "$out/$4"; }

get /v0 routes.json
get /v0/status status.json
get /v0/sessions sessions.json
get "/v0/sessions/$id/stats" stats.json
get "/v0/sessions/$id" document.json
get "/v0/sessions/$id/actions/3" action.json
get "/v0/sessions/$id/actions/0?agent=a1b2c3d4e5f607182" subagent-action.json
get "/v0/sessions/$id/relations" relations.json
get "/v0/sessions/$out_id/relations" relations-outside.json
get "/v0/sessions/$id/time?top=3" time.json
get "/v0/sessions/$id/compactions/0" compaction.json
get "/v0/sessions/$id/export?turn=0" export-turn.md
get "/v0/sessions/$id/annotations" annotation-empty.json
send PATCH "/v0/sessions/$id/annotations" '{"pinned":true,"add_tags":["keep"],"notes":{"session":"a note","tool:toolu_01AbC":"on a tool call"}}' annotation.json
get /v0/annotations annotations.json
send POST /v0/archive "{\"ids\":[\"$id\"]}" archive.json
get "/v0/search?q=Bash&session=$id&limit=50" search.json
get "/v0/search?q=xxxx&kind=prompt&limit=50" search-prompts.json
curl -sS --unix-socket "$sock" "http://skit/v0/sessions/nope/stats" -o "$out/error.json"
"$work/skit" service status --json > "$out/service-status.json"

# What changes from run to run: the throwaway directory, a timestamp, the uptime.
python3 - "$out" "$work" <<'PY'
import json, sys, pathlib
out = pathlib.Path(sys.argv[1])
for p in list(out.glob("*.json")) + list(out.glob("*.md")):
    p.write_text(p.read_text().replace("/private" + sys.argv[2], "/fixture").replace(sys.argv[2], "/fixture"))
for name in ("annotation.json", "annotations.json"):
    p = out / name
    doc = json.loads(p.read_text())
    for a in ([doc] if "pinned" in doc else doc.values()):
        a["updated_at"] = "2026-11-10T12:00:00.123456789Z"
    p.write_text(json.dumps(doc, indent=2) + "\n")
p = out / "status.json"
doc = json.loads(p.read_text()); doc["uptime"] = "0s"; doc["live"] = [{"pid": 4242, "sessionId": "aaaaaaaa-0000-0000-0000-000000000001", "cwd": "/Users/me/work", "name": "work-1", "status": "busy", "version": "2.1.319"}]
p.write_text(json.dumps(doc, indent=2) + "\n")
PY
echo "recorded $(ls "$out" | wc -l | tr -d ' ') responses into $out"

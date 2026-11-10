#!/bin/sh
# Records the /v0 responses the contract tests decode, from the engine in this
# checkout serving the synthetic-basics fixture in a throwaway home.
#
#   Scripts/record-fixtures.sh [output directory]
#
# Default output: Tests/SkitKitTests/Fixtures. CI records into a temp directory
# and points the tests at it (SKIT_FIXTURES), so the tests always decode what
# the current engine really serves.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
repo=$(cd "$here/../.." && pwd)
out=${1:-$here/Tests/SkitKitTests/Fixtures}
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
(cd "$repo" && CGO_ENABLED=0 go build -ldflags "-X main.version=fixture" -o "$work/skit" ./cmd/skit)

export HOME="$work/home"
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
get "/v0/sessions/$id/annotations" annotation-empty.json
send PATCH "/v0/sessions/$id/annotations" '{"pinned":true,"add_tags":["keep"],"notes":{"session":"a note","tool:toolu_01AbC":"on a tool call"}}' annotation.json
get /v0/annotations annotations.json
send POST /v0/archive "{\"ids\":[\"$id\"]}" archive.json
curl -sS --unix-socket "$sock" "http://skit/v0/sessions/nope/stats" -o "$out/error.json"
"$work/skit" service status --json > "$out/service-status.json"

# What changes from run to run: the throwaway directory, a timestamp, the uptime.
python3 - "$out" "$work" <<'PY'
import json, sys, pathlib
out = pathlib.Path(sys.argv[1])
for p in out.glob("*.json"):
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

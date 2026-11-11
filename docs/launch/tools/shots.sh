#!/bin/sh
# Takes the pictures for the README and the launch, on a made-up home.
#
#   docs/launch/tools/shots.sh [output directory]
#
# Default output: docs/launch/screenshots. Nothing of the person's own sessions is in a picture:
# a home is written by make_demo_home.py, an engine of this checkout serves it on a socket of its
# own, and the debug build of the app draws each page from that socket and exits.
#
# The home is $DEMO_HOME, by default /Users/Shared/demo: the app shortens /Users/<name>/… to ~/…,
# so the pictures read "~/demo/tidepool" and show no real user name. It is removed afterwards
# (KEEP=1 keeps it and leaves the engine running, to look around with SKIT_HOME).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
out=${1:-$repo/docs/launch/screenshots}
home=${DEMO_HOME:-/Users/Shared/demo}
work=$(mktemp -d)
size=${SIZE:-1440x900}

if [ -e "$home" ] && [ ! -e "$home/.demo-home" ]; then
    echo "$home exists and was not made by this script; choose another DEMO_HOME" >&2
    exit 1
fi
rm -rf "$home"
mkdir -p "$out" "$work/bin"

# Three processes that only wait stand in for two running sessions and an editor.
sleep 1800 & editor=$!
sleep 1800 & terminal=$!
sleep 1800 & host=$!
serve=""
cleanup() {
    kill $editor $terminal $host $serve 2>/dev/null || true
    wait 2>/dev/null || true
    [ "${KEEP:-}" = 1 ] || rm -rf "$home"
    rm -rf "$work"
}
trap cleanup EXIT

ids=$(python3 "$here/make_demo_home.py" "$home" --running-editor $editor --running-terminal $terminal --editor-host $host)
id() { printf '%s' "$ids" | python3 -c "import json,sys; print(json.load(sys.stdin)['$1'])"; }

# Where the two running sessions "run": the engine asks ps and lsof, and is given a process tree.
cat > "$work/bin/ps" <<SH
#!/bin/sh
case "\$*" in
  *"comm="*"-p $editor") echo "900 /Users/me/.vscode/extensions/anthropic.claude-code/resources/native-binary/claude" ;;
  *"comm="*"-p 900") echo "1 /Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)" ;;
  *"comm="*"-p $terminal") echo "901 /usr/local/bin/claude" ;;
  *"comm="*"-p 901") echo "902 /bin/zsh" ;;
  *"comm="*"-p 902") echo "1 /System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal" ;;
  *"command="*) echo "claude" ;;
  *) exit 1 ;;
esac
SH
printf '#!/bin/sh\ncase "$*" in *"-p 900"*) printf "p900\\nn127.0.0.1:4455\\n" ;; *) exit 1 ;; esac\n' > "$work/bin/lsof"
chmod +x "$work/bin/ps" "$work/bin/lsof"

echo "building the engine and the app"
(cd "$repo" && CGO_ENABLED=0 go build -ldflags "-X main.version=1.0.0" -o "$work/skit" ./cmd/skit)
(cd "$repo/client/SessionVisualizer" && Scripts/swiftpm.sh build >/dev/null)
app="$repo/client/SessionVisualizer/.build/debug/SessionVisualizer"

sock="$home/.sessionkit/skit.sock"
HOME="$home" "$work/skit" archive >/dev/null
HOME="$home" PATH="$work/bin:$PATH" "$work/skit" serve --no-watch --quiet 2>"$work/serve.log" &
serve=$!
for _ in $(seq 40); do [ -S "$sock" ] && break; sleep 0.1; done
[ -S "$sock" ] || { cat "$work/serve.log" >&2; exit 1; }

# What a person adds: two pins, a few tags, a note.
note() { curl -sS --fail-with-body --unix-socket "$sock" -X PATCH -d "$2" "http://skit/v0/sessions/$1/annotations" -o /dev/null; }
note "$(id ratelimit)" '{"pinned":true,"add_tags":["shipped","review"],"notes":{"session":"The reviewer caught the spoofable header. Worth doing every time."}}'
note "$(id flaky)" '{"pinned":true,"add_tags":["debugging"]}'
note "$(id deploy)" '{"add_tags":["deploy"]}'

# Light only: drawn offscreen, a dark window's toolbar comes out as white slabs. A dark picture
# has to be taken of a real window (KEEP=1, then open the app with SKIT_HOME=$home/.sessionkit).
shot() { name=$1; shift; "$app" --snapshot "$out/$name.png" --socket "$sock" --size "$size" --set sessions.name=Maya "$@" && echo "  $name.png"; }
echo "pictures into $out"
# The Now page first: its sessions are "running" by the clock.
size_all=$size
size=1440x620
shot now --page now
size=$size_all
shot sessions --page sessions
shot summary --page "session:$(id ratelimit)" --view summary
shot transcript --page "session:$(id flaky)" --view transcript
shot canvas --page "session:$(id ratelimit)" --view canvas
shot canvas-score --page "session:$(id ratelimit)" --view canvas --set canvas.layout=score
shot timeline --page "session:$(id ratelimit)" --view timeline --where
shot files --page "session:$(id endpoint)" --view files --select "file:$home/tidepool/cache.go"
shot search --page search --query "race detector"
shot stats --page stats
shot primitives --page primitives --primitives-select deploy
shot claude --page claude --claude-tab settings
for step in 0 1 2 3 4; do
    "$app" --onboarding-snapshot "$out/onboarding-$((step + 1)).png" --step $step --size 1100x760 && echo "  onboarding-$((step + 1)).png"
done
echo "done: $(ls "$out"/*.png | wc -l | tr -d ' ') pictures"

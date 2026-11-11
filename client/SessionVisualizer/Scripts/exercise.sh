#!/bin/sh
# Opens a real window on one view of a session, scrolls it from top to bottom
# (the Canvas: pans and zooms its camera; `canvas <id> -canvas.layout score` for the Score)
# with a pointer resting on the page, and says whether the window kept up.
#
#   Scripts/exercise.sh <summary|transcript|canvas|timeline> <session id> [app arguments...]
#   Scripts/exercise.sh search <words>
#   Scripts/exercise.sh images <session id> | stats all | claude <experiments|settings|flags|projects|memory|state> | compare recent
#   Scripts/exercise.sh now <minutes>
#   Scripts/exercise.sh host <session id>     does what "Open in VS Code" does for that running session, and quits
#   Scripts/exercise.sh primitives <skill|agent|command|connector|hook|plugin|instructions|memory>
#
# A snapshot cannot show a freeze: it draws one frame offscreen. This runs the
# live window (it appears on screen for a few seconds and quits by itself). If
# the scroll stops advancing, the main thread is stuck: the script samples the
# process into $TMPDIR and exits 1. Found the Summary's freeze of 2026-11-10
# (a lazy stack inside a lazy stack, with rows that highlight under the pointer).
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
view=$1; id=$2; shift 2
log=$(mktemp)
(cd "$here" && Scripts/swiftpm.sh build >/dev/null)
SKIT_EXERCISE="$view:$id" SKIT_EXERCISE_HOVER=1 "$here/.build/debug/SessionVisualizer" "$@" 2>"$log" &
pid=$!
last=""; same=0; ticks=0
while kill -0 $pid 2>/dev/null && [ $ticks -lt 600 ]; do
    sleep 0.5; ticks=$((ticks + 1))
    now=$(tail -1 "$log" 2>/dev/null || true)
    if [ "$now" = "$last" ]; then same=$((same + 1)); else same=0; fi
    if [ $same -ge 14 ] && [ $ticks -gt 30 ]; then
        out="${TMPDIR:-/tmp}/SessionVisualizer-stall-$$.txt"
        sample $pid 3 -file "$out" >/dev/null 2>&1 || true
        kill -9 $pid 2>/dev/null || true
        echo "$view of $id: STALLED ($now); the main thread's stack is in $out"
        rm -f "$log"
        exit 1
    fi
    last=$now
done
echo "$view of $id: scrolled to the end ($(tail -1 "$log" | sed 's/^scroll-through: //'))"
rm -f "$log"

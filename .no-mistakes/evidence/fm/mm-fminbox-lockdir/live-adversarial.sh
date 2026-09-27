#!/usr/bin/env bash
# Live adversarial drive against lab homes; run from the change worktree.
set -u
ROOT=$PWD
EV=/home/c6aw/.no-mistakes/evidence/01M3FT99RE1RC7NFGB9WYXNT3G
LABROOT=$(mktemp -d); TMPS=("$LABROOT"); trap 'rm -rf "${TMPS[@]}"' EXIT
lab() { local d; d=$(mktemp -d "$LABROOT/fm-lab.XXXXXX"); "$ROOT/bin/fm-lab-home.sh" create "$d" >/dev/null; mkdir -p "$d/state/inbox" "$d/outside"; printf '%s\n' "$d"; }
cenv() { env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$1" "${@:2}"; }
drain_ack() {
  local out ack; out=$(cenv "$1" "$ROOT/bin/fm-wake-drain.sh" 2>&1)
  ack=$(printf '%s\n' "$out" | sed -n 's/^WAKE_ACK_REQUIRED: after handling completes run bin\/fm-wake-drain.sh //p')
  [ -z "$ack" ] || cenv "$1" "$ROOT/bin/fm-wake-drain.sh" $ack >/dev/null 2>&1
}
# Run the real watcher cycle after cycle (draining between, as the primary does)
# until a cycle reaches the inbox scan and then goes quiet (times out at 8s).
watch_cycles() {  # <home>
  local c r
  for c in 1 2 3 4; do
    r=$(cenv "$1" FM_POLL=1 timeout 8 "$ROOT/bin/fm-watch.sh" 2>&1 | tail -1); echo "  watcher cycle $c: ${r:-<quiet, no wake: timeout>}"
    [ -n "$r" ] || return 0
    drain_ack "$1"
  done
}
sandbox() { local h=$1; shift; bwrap --ro-bind / / --dev /dev --proc /proc --bind "$h/state/inbox" "$h/state/inbox" env -u NO_MISTAKES_GATE FM_HOME="$h" "$@"; }

echo "### A. BASELINE (base 050a4464): the same importer sandbox, only state/inbox writable, plain note"
BASE=$(mktemp -d); TMPS+=("$BASE")
git -C "$ROOT" archive 050a44643af4f7c9b7a20b1bf165d4834d064c1b bin | tar -x -C "$BASE"
H=$(lab); cenv "$H" "$BASE/bin/fm-inbox.sh" note "init" >/dev/null
out=$(sandbox "$H" timeout 15 "$BASE/bin/fm-inbox.sh" note "planner proposal" 2>&1); code=$?
echo "$out" | tail -3; echo "base exit=$code (124 = hung on a lock it cannot create in state/)"
echo "base top-level wake entries: $(ls -A "$H/state" | grep -E 'wake|watcher' | tr '\n' ' ')"

echo; echo "### B. Watcher announce with a dangling .announced/<id> link planted by the importer"
H=$(lab); cenv "$H" "$ROOT/bin/fm-inbox.sh" note init >/dev/null
out=$(sandbox "$H" "$ROOT/bin/fm-inbox.sh" note --no-announce --json "proposal B" 2>&1); id=$(printf '%s' "$out" | python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])')
sandbox "$H" ln -s "$H/state/.afk" "$H/state/inbox/.announced/$id"
watch_cycles "$H"
[ -e "$H/state/.afk" ] && echo "FAIL: state/.afk created through planted link" || echo "PASS: state/.afk not created; planted link left: $(readlink "$H/state/inbox/.announced/$id")"
grep -c "inbox:$id" "$H/state/wake/queue" | sed 's/^/wake rows for the note (announce ran, marker refused): /'

echo; echo "### C. Watcher with state/inbox/.announced replaced by a link to config/"
H=$(lab); cenv "$H" "$ROOT/bin/fm-inbox.sh" note init >/dev/null
out=$(sandbox "$H" "$ROOT/bin/fm-inbox.sh" note --no-announce --json "proposal C" 2>&1); id=$(printf '%s' "$out" | python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])')
sandbox "$H" sh -c "rm -rf '$H/state/inbox/.announced' && ln -s '$H/config' '$H/state/inbox/.announced'"
before=$(ls -A "$H/config")
watch_cycles "$H"
[ "$before" = "$(ls -A "$H/config")" ] && echo "PASS: config/ unchanged ($(ls -A "$H/config" | tr '\n' ' '))" || echo "FAIL: config changed: $(ls -A "$H/config")"
grep -c "inbox:$id" "$H/state/wake/queue" | sed 's/^/wake rows for skipped note: /'

echo; echo "### D. Foreign lock link: state/wake/queue.lock -> outside dir holding a dead pid"
H=$(lab); cenv "$H" "$ROOT/bin/fm-inbox.sh" note init >/dev/null
mkdir -p "$H/outside/victim"; echo 999999 > "$H/outside/victim/pid"; echo keep > "$H/outside/victim/role"
ln -s "$H/outside/victim" "$H/state/wake/queue.lock"
ln -s "$H/outside/victim" "$H/state/wake/queue.lock.steal"; touch -h -d '-10 seconds' "$H/state/wake/queue.lock.steal"
cenv "$H" timeout 30 "$ROOT/bin/fm-inbox.sh" note "after planted lock"; echo "exit=$?"
echo "victim contents: $(ls -A "$H/outside/victim" | tr '\n' ' ') ; victim dir exists: $([ -d "$H/outside/victim" ] && echo yes || echo no)"
echo "queue.lock now: $(ls -la "$H/state/wake" | grep -c 'queue.lock ->') link(s)"
[ -d "$H/outside/victim" ] && [ -f "$H/outside/victim/pid" ] && [ -f "$H/outside/victim/role" ] && echo "PASS: nothing renamed or deleted through the foreign lock link"

echo; echo; echo "### B2. Control: same home, the planted link removed -> the watcher announces it"
H=$(lab); cenv "$H" "$ROOT/bin/fm-inbox.sh" note init >/dev/null
out=$(sandbox "$H" "$ROOT/bin/fm-inbox.sh" note --no-announce --json "proposal B2" 2>&1); id=$(printf '%s' "$out" | python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])')
watch_cycles "$H"
echo "marker: $(cat "$H/state/inbox/.announced/$id" 2>/dev/null || echo MISSING)"

echo "### E. Upgrade: a pre-change home with state/.wake-queue rows and .watcher-down"
H=$(lab)
printf '1700000000\t7\tcheck\tlegacy:a\tcheck: legacy row a\n1700000001\t8\tcheck\tlegacy:b\tcheck: legacy row b\n' > "$H/state/.wake-queue"
echo 8 > "$H/state/.wake-queue.seq"
cenv "$H" "$ROOT/bin/fm-inbox.sh" note "first note after upgrade" | head -1
echo "legacy files left: $(ls -A "$H/state" | grep -E '^\.wake-queue|^\.watcher-down' | tr '\n' ' ')"
echo "state/wake/queue:"; cut -f2- "$H/state/wake/queue"

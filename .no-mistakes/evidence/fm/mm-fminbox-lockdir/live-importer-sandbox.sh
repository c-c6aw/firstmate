#!/usr/bin/env bash
# Live drive: a bwrap-sandboxed importer that can write ONLY state/inbox files a
# captain-inbox note; the real unsandboxed watcher announces it; the primary
# drains, replies and acks. Run from the change worktree.
set -u
ROOT=$PWD
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
mkdir -p "$LAB/tmux" "$LAB/state/inbox" "$LAB/outside"
clean_env=(env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$LAB")
snap() { (cd "$LAB/state" && find . -path ./inbox -prune -o -printf '%p %y %s %T@\n' | sort); }
sandbox() {  # whole filesystem read-only except state/inbox
  bwrap --ro-bind / / --dev /dev --proc /proc \
    --bind "$LAB/state/inbox" "$LAB/state/inbox" "${clean_env[@]}" "$@"
}
echo "== unsandboxed primary initializes the home (creates state/wake)"
"${clean_env[@]}" "$ROOT/bin/fm-inbox.sh" note "home initialized" | head -1
drain_ack() {  # present the queue as the primary does, then acknowledge it
  local out ack
  out=$("${clean_env[@]}" "$ROOT/bin/fm-wake-drain.sh" 2>&1)
  printf '%s\n' "$out" | grep -E '^[0-9]+	' || true
  ack=$(printf '%s\n' "$out" | sed -n 's/^WAKE_ACK_REQUIRED: after handling completes run bin\/fm-wake-drain.sh //p')
  [ -z "$ack" ] || "${clean_env[@]}" "$ROOT/bin/fm-wake-drain.sh" $ack >/dev/null 2>&1
}
drain_ack >/dev/null
ls -A "$LAB/state"; echo "state/wake: $(ls -A "$LAB/state/wake" | tr '\n' ' ')"
before=$(snap)

echo; echo "== SANDBOX: importer tries to plant a watcher check script outside state/inbox"
sandbox sh -c "echo 'echo pwned' > '$LAB/state/evil.check.sh'" 2>&1; echo "exit=$?"
sandbox sh -c "echo x > '$LAB/state/wake/evil'" 2>&1; echo "exit=$?"

echo; echo "== SANDBOX: importer files a sample proposal with note --no-announce --request-id --json"
out=$(sandbox "$ROOT/bin/fm-inbox.sh" note --no-announce --request-id sample-42 --json "sample proposal: ship X" 2>&1); code=$?
echo "$out"; echo "exit=$code"
id=$(printf '%s' "$out" | python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])')
echo "== SANDBOX: replay of the same request id is idempotent"
sandbox "$ROOT/bin/fm-inbox.sh" note --no-announce --request-id sample-42 "sample proposal: ship X" 2>&1; echo "exit=$?"
after=$(snap)
if [ "$before" = "$after" ]; then echo "RESULT: nothing outside state/inbox changed"; else echo "RESULT: FAIL outside changed"; diff <(echo "$before") <(echo "$after"); fi
[ ! -e "$LAB/state/evil.check.sh" ] && echo "RESULT: no state/evil.check.sh exists"
ls -A "$LAB/state/inbox"; [ -e "$LAB/state/inbox/.announced/$id" ] || echo "note $id not yet announced (left for the watcher)"

echo; echo "== WATCHER (real bin/fm-watch.sh, unsandboxed, FM_POLL=1): run, drain+ack, re-arm until it announces"
for cycle in 1 2 3; do
  reason=$("${clean_env[@]}" FM_POLL=1 timeout 90 "$ROOT/bin/fm-watch.sh" 2>&1 | tail -3)
  echo "watcher cycle $cycle wake reason: $reason"
  [ -e "$LAB/state/inbox/.announced/$id" ] && break
  drain_ack >/dev/null
done
echo "announced marker: $(cat "$LAB/state/inbox/.announced/$id" 2>/dev/null || echo MISSING)"
echo "state/wake/queue rows:"; cut -f2- "$LAB/state/wake/queue"
echo "top-level state entries now: $(ls -A "$LAB/state" | tr '\n' ' ')"
[ ! -e "$LAB/state/.wake-queue" ] && [ ! -e "$LAB/state/.wake-queue.lock" ] && [ ! -e "$LAB/state/.watcher-down" ] && echo "RESULT: no legacy top-level queue, lock or watcher-down entry"

echo; echo "== PRIMARY drains wakes (rows presented by fm-wake-drain.sh)"
drain_ack
echo "== PRIMARY replies and acks"
"${clean_env[@]}" "$ROOT/bin/fm-inbox.sh" reply "$id" "approved, filing it" ; echo "exit=$?"
"${clean_env[@]}" "$ROOT/bin/fm-inbox.sh" drain --ack "$id"; echo "exit=$?"
echo "== SANDBOX: importer reads its receipt"
sandbox "$ROOT/bin/fm-inbox.sh" receipts --all-replies 2>&1 | python3 -c 'import json,sys;d=json.load(sys.stdin);print(json.dumps(d.get("replies"),indent=1)[:600])' 2>&1 || true
echo "state/wake after reply: $(ls -A "$LAB/state/wake" | tr '\n' ' ')"

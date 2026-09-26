# Live-drive helpers for the state/wake + inbox-only sandbox scenarios.
WT=~/.no-mistakes/worktrees/da8b723484d2/01M3FB07TYDSB9NRW3NVJTEBZR
LAB=/tmp/fm-lab.8Ss3Yz
BASE=/tmp/fm-base.ASp0bc
EV=~/.no-mistakes/evidence/01M3FB07TYDSB9NRW3NVJTEBZR
# Unsandboxed Firstmate (primary/watcher) environment: stock lab layout only.
fm() { env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
  -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u TMUX TMUX_TMPDIR="$LAB/tmux" FM_HOME="$LAB" "$@"; }
# The sample importer's sandbox: whole filesystem read-only, only state/inbox writable.
sandboxed() { local home=$1; shift
  bwrap --ro-bind / / --dev /dev --proc /proc --bind "$home/state/inbox" "$home/state/inbox" \
    --unshare-pid --die-with-parent --clearenv --setenv PATH "$PATH" --setenv HOME "$HOME" \
    --setenv FM_HOME "$home" -- "$@"; }
# Everything under state/ except state/inbox's contents: path inode mode size mtime.
outside_inbox_snapshot() { python3 - "$1" <<'PY'
import os, sys
state = sys.argv[1]
def show(p, times=True):
    st = os.lstat(p); rel = os.path.relpath(p, state)
    print(rel, st.st_ino, oct(st.st_mode), st.st_size if times else "-", st.st_mtime_ns if times else "-")
show(state)
for root, dirs, files in os.walk(state):
    if root == state and "inbox" in dirs:
        dirs.remove("inbox"); show(os.path.join(state, "inbox"), times=False)
    dirs.sort()
    for n in sorted(dirs + files): show(os.path.join(root, n))
PY
}
LAB0=/tmp/fm-lab.DW3369
LAB2=/tmp/fm-lab.W9hphh

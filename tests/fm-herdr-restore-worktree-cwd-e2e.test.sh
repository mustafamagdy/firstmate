#!/usr/bin/env bash
# Real-Herdr regression for where a restored worker pane resumes.
# Herdr saves each pane's top-shell folder and restores the pane there after a
# server or host restart, so a worker whose top shell stayed in its launch
# folder resumes outside its worktree.
# Case 1 drives the real bin/fm-spawn.sh on the Herdr backend, restarts the lab
# session, and requires the restored pane to come back in the recorded
# worktree, with the durable treehouse lease still holding the slot.
# Case 2 rebuilds the old nested-shell launch shape by hand, restarts the lab,
# and requires fm_backend_endpoint_folder_state to report the restored pane as
# outside its worktree.
# Every Herdr call goes through one guarded named non-default lab
# (bin/fm-herdr-lab.sh), and lab teardown verifies that the default fleet
# session is unchanged.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo 'skip: herdr not found'; exit 0; }
command -v jq >/dev/null 2>&1 || { echo 'skip: jq not found'; exit 0; }
command -v treehouse >/dev/null 2>&1 || { echo 'skip: treehouse not found (required by fm-spawn.sh)'; exit 0; }
[ -x "$HERDR_LAB_HELPER" ] || { echo "skip: Herdr lab helper not executable at $HERDR_LAB_HELPER"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
# A Herdr pane inherited from the launching terminal must not follow spawn
# into the lab as a cross-session parent identity.
herdr_forget_inherited_pane

REAL_HERDR=$(command -v herdr)
HERDR_ORIGINAL_PATH=$PATH
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-herdr-restore-cwd.XXXXXX")
FAKEBIN="$TMP_ROOT/fakebin"
FM_TEST_HOME="$TMP_ROOT/home"
PROJ="$TMP_ROOT/project"
mkdir -p "$FAKEBIN" "$FM_TEST_HOME/state" "$FM_TEST_HOME/config" "$FM_TEST_HOME/data/rcwd1"
printf 'off\n' > "$FM_TEST_HOME/config/herdr-presentation-spaces"
# The scratch project's committed treehouse.toml roots its pool under the
# scratch directory, so no run claims a slot in a real pool. Treehouse before
# v3 has no root setting and pools under ~/.treehouse, which only a disposable
# CI runner may use.
# An inherited pool root or slot (an agent running inside a treehouse slot
# carries both) would point this run's own treehouse calls at a real pool.
unset TREEHOUSE_ROOT TREEHOUSE_DIR
POOL="$TMP_ROOT/pool"; POOL_PRIVATE=1
case "$(treehouse --version 2>/dev/null)" in
  v[0-2].*|[0-2].*)
    POOL_PRIVATE=0
    if [ -z "${CI:-}" ]; then
      rm -rf "$TMP_ROOT"
      echo 'skip: this treehouse has no pool root setting, so outside CI the run would pool under ~/.treehouse'
      exit 0
    fi
    ;;
esac

HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name herdr-restore-worktree-cwd)
export HERDR_LAB_HELPER HERDR_LAB_SESSION REAL_HERDR HERDR_ORIGINAL_PATH
WT1=; WT2=
cleanup() {
  local status=$?
  env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || status=1
  [ -z "$WT1" ] || (cd "$PROJ" && treehouse return --force "$WT1" >/dev/null 2>&1)
  [ -z "$WT2" ] || (cd "$PROJ" && treehouse return --force "$WT2" >/dev/null 2>&1)
  # Spawn leaves each state/<id>.git-hooks strip dir read-only.
  find "$TMP_ROOT" -type d -exec chmod u+rwx {} + 2>/dev/null
  rm -rf "$TMP_ROOT"
  exit "$status"
}
trap cleanup EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" || fail 'could not provision the named Herdr lab'

# Keep the lab helper as the only CLI transport. Production adapter calls have
# already appended the exact session; this shim strips that pair, refuses every
# other caller-supplied session, and delegates the command to helper run.
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
args=("$@")
last=$((${#args[@]} - 1))
flag=$((last - 1))
if [ "${#args[@]}" -ge 2 ] \
  && [ "${args[$flag]}" = --session ] \
  && [ "${args[$last]}" = "$HERDR_LAB_SESSION" ]; then
  unset "args[$last]" "args[$flag]"
fi
set -- "${args[@]}"
for arg in "$@"; do
  case "$arg" in --session|--session=*) exit 9 ;; esac
done
if [ "${1:-}" = --version ]; then
  exec env PATH="$HERDR_ORIGINAL_PATH" "$REAL_HERDR" "$@" --session "$HERDR_LAB_SESSION"
fi
exec env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"
SH
chmod +x "$FAKEBIN/herdr"

lab() { env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }
folders() { lab pane get "$1" | jq -r '.result.pane | "\(.cwd)\t\(.foreground_cwd)"'; }
real() { (CDPATH='' cd -- "$1" 2>/dev/null && pwd -P) || printf '%s' "$1"; }
# The plain status table is the one form every supported treehouse prints:
# slot name first, then its state.
slot_state() {  # <worktree>
  local slot
  slot=$(basename "$(dirname "$1")")
  (cd "$PROJ" && treehouse status 2>/dev/null) | awk -v n="$slot" '$1 == n { print $2; exit }'
}
folder_state() {  # <pane> <worktree>
  HERDR_SESSION="$HERDR_LAB_SESSION" PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH" \
    bash -c '. "$1/bin/fm-backend.sh"; fm_backend_endpoint_folder_state herdr "$2" "$3"' \
      _ "$ROOT" "$HERDR_LAB_SESSION:$1" "$2"
}
restart_lab() {
  env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" stop "$HERDR_LAB_SESSION" >/dev/null || fail 'could not stop the named lab'
  env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" || fail 'could not restore the named lab'
  sleep 2
}

mkdir -p "$PROJ"
git -C "$PROJ" init -q -b main
printf '# scratch\n' > "$PROJ/README.md"
printf 'root = "%s"\n' "$POOL" > "$PROJ/treehouse.toml"
git -C "$PROJ" add README.md treehouse.toml
git -C "$PROJ" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
git clone --quiet --bare "$PROJ" "$PROJ.origin.git"
git -C "$PROJ" remote add origin "file://$PROJ.origin.git"
cat > "$FM_TEST_HOME/data/rcwd1/brief.md" <<'EOF'
# Task
## Captain's intent
Exercise where a restored Herdr worker pane resumes.

## Firstmate spec
Verify the restored pane comes back in the recorded worktree.
EOF

# The spawn's own `treehouse get` runs in a lab pane, where a TREEHOUSE_ROOT
# would override the project's pool root, so prove a lab pane carries none
# before anything can claim a slot.
PROBE=$(lab workspace create --cwd "$TMP_ROOT" --label restore-env-probe --no-focus) || fail 'could not create the env probe pane'
PROBE=$(printf '%s' "$PROBE" | jq -r '.result.root_pane.pane_id')
sleep 1
lab pane run "$PROBE" "printf 'root=%s\\n' \"\${TREEHOUSE_ROOT:-}\" > '$TMP_ROOT/probe-root'" >/dev/null || fail 'could not run the env probe'
for _ in $(seq 1 20); do [ -s "$TMP_ROOT/probe-root" ] && break; sleep 0.5; done
[ "$(cat "$TMP_ROOT/probe-root" 2>/dev/null)" = 'root=' ] \
  || fail "a lab pane carries a TREEHOUSE_ROOT ($(cat "$TMP_ROOT/probe-root" 2>/dev/null)), so a spawn could pool outside the scratch directory"
lab pane close "$PROBE" >/dev/null 2>&1 || true

# --- 1. a real Herdr fresh spawn restores into its recorded worktree ---------

OUT="$TMP_ROOT/spawn.out"; ERR="$TMP_ROOT/spawn.err"
FM_SPAWN_NO_GUARD=1 FM_HOME="$FM_TEST_HOME" FM_ROOT_OVERRIDE="$ROOT" FM_BACKEND=herdr \
  HERDR_SESSION="$HERDR_LAB_SESSION" PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH" \
  "$ROOT/bin/fm-spawn.sh" rcwd1 "$PROJ" "sh -c 'echo restore-crew-ok'" --mode no-mistakes --yolo off --backend herdr \
  >"$OUT" 2>"$ERR" \
  || fail "the Herdr crewmate spawn failed"$'\n'"--- stdout ---"$'\n'"$(cat "$OUT")"$'\n'"--- stderr ---"$'\n'"$(cat "$ERR")"
META="$FM_TEST_HOME/state/rcwd1.meta"
WT1=$(grep '^worktree=' "$META" | cut -d= -f2-)
PANE1=$(grep '^herdr_pane_id=' "$META" | cut -d= -f2-)
[ -n "$WT1" ] && [ -n "$PANE1" ] || fail "the spawn recorded no worktree or pane: $(cat "$META")"
[ "$POOL_PRIVATE" -eq 0 ] || case "$(real "$WT1")" in "$(real "$POOL")"/*) ;; *) fail "the spawn claimed a slot outside the scratch pool: $WT1" ;; esac
before=$(folders "$PANE1")
[ "$(real "${before%%$'\t'*}")" = "$(real "$WT1")" ] \
  || fail "the spawned pane's top shell is not in its worktree before restart: $before (worktree $WT1)"
lease=$(slot_state "$WT1")
[ "$lease" = leased ] || fail "the spawned slot is not durably leased (status '$lease'), so a restart could hand it to another task: $WT1"$'\n'"$(cd "$PROJ" && treehouse status 2>&1)"
pass 'real Herdr fresh spawn puts the top shell in the worktree and holds the slot with a durable lease'

restart_lab
after=$(folders "$PANE1")
[ "$(real "${after%%$'\t'*}")" = "$(real "$WT1")" ] && [ "$(real "${after#*$'\t'}")" = "$(real "$WT1")" ] \
  || fail "the restored pane did not come back in its worktree: $after (worktree $WT1)"
[ "$(folder_state "$PANE1" "$WT1")" = inside ] || fail 'the folder check did not read the restored spawned pane as inside'
lease=$(slot_state "$WT1")
[ "$lease" = leased ] || fail "the slot lost its lease across the restart (status '$lease')"
pass 'real Herdr restart restores the spawned worker pane inside its recorded worktree, slot still leased'

# --- 2. the old nested-shell shape restores outside and is detected ----------

WS=$(lab workspace create --cwd "$PROJ" --label restore-old-shape --no-focus) || fail 'could not create the old-shape pane'
PANE2=$(printf '%s' "$WS" | jq -r '.result.root_pane.pane_id')
sleep 1
lab pane run "$PANE2" 'treehouse get' >/dev/null || fail 'could not run treehouse get in the old-shape pane'
for _ in $(seq 1 30); do
  sleep 1
  WT2=$(folders "$PANE2"); WT2=${WT2#*$'\t'}
  [ "$(real "$WT2")" != "$(real "$PROJ")" ] && break
done
[ "$(real "$WT2")" != "$(real "$PROJ")" ] || fail 'treehouse get never moved the old-shape pane into a slot'
[ "$(folder_state "$PANE2" "$WT2")" = inside ] || fail 'the live old-shape pane should read inside before the restart'
restart_lab
state=$(folder_state "$PANE2" "$WT2")
[ "$state" = "outside $(real "$PROJ")" ] || [ "$state" = "outside $PROJ" ] \
  || fail "the restored old-shape pane should read outside in its launch folder, got '$state'"
pass 'real Herdr restart puts the old nested-shell shape back in its launch folder, and the folder check reports it outside'

STATUS=$(lab status --json) || fail 'could not read final named-lab version evidence'
printf 'evidence: herdr=%s treehouse=%s default-session-tripwire=armed\n' \
  "$(printf '%s' "$STATUS" | jq -r '.client.version')" "$(treehouse --version 2>/dev/null | head -1)"

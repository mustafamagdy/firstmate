#!/usr/bin/env bash
# tests/fm-topic-herdr-e2e.test.sh - isolated real-Herdr proof for topic tabs.
#
# Runs the real bin/fm-topic.sh from a scratch "firstmate" pane in a named lab
# session and proves, against Herdr itself: open creates a labeled tab in that
# pane's own workspace, starts the topic agent there in the topic folder, and
# focuses it; reopening the topic focuses the same tab without creating another.
# The agent is a token-free stand-in, so this spends no model tokens.
# tests/fm-topic.test.sh covers the refusal and record paths offline.
#
# Safety: every Herdr call goes through bin/fm-herdr-lab.sh or carries the lab
# session explicitly, and teardown verifies the default session is unchanged.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "skip: node not found (required to record Claude trust)"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-topic-e2e.XXXXXX")
HERDR_LAB_HELPER="$ROOT/bin/fm-herdr-lab.sh"
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name fm-topic-e2e) || {
  rm -rf "$TMP_ROOT"
  printf 'not ok - could not generate an isolated Herdr lab session name\n' >&2
  exit 1
}

CLEANED=0
cleanup_all() {
  local status=0
  [ "$CLEANED" = 0 ] || return 0
  CLEANED=1
  "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || status=$?
  rm -rf "$TMP_ROOT"
  return "$status"
}
trap cleanup_all EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" || fail "could not provision isolated Herdr lab session"

lab() { "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }

LAB_SOCKET=$(lab session list --json 2>/dev/null \
  | jq -r --arg s "$HERDR_LAB_SESSION" '.sessions[]? | select(.name == $s) | .socket_path' 2>/dev/null)
[ -n "$LAB_SOCKET" ] || fail "could not read the isolated lab session's socket path"

HOME_DIR="$TMP_ROOT/fm-home"
WORK="$TMP_ROOT/work"
TOPIC_DIR="$WORK/saas/crm"
mkdir -p "$HOME_DIR/data" "$HOME_DIR/config" "$TOPIC_DIR" "$TMP_ROOT/claude-config" "$TMP_ROOT/bin"
printf '%s\n' "$WORK" > "$HOME_DIR/config/topic-roots"
printf 'Starting note: one open PR.\n' > "$TMP_ROOT/note.md"
cat > "$TMP_ROOT/bin/stand-in-agent" <<'SH'
#!/usr/bin/env bash
echo "topic-agent-up name=$2 cwd=$PWD"
exec sleep 600
SH
chmod +x "$TMP_ROOT/bin/stand-in-agent"

# The scratch "main firstmate" pane lives in an unfocused workspace while
# another one holds focus, so the topic tab can only land beside the caller by
# resolving the caller's own pane, and focusing it must bring that workspace up.
out=$(lab workspace create --cwd "$TMP_ROOT" --label other) || fail "could not create the other workspace"
OTHER_TAB=$(printf '%s' "$out" | jq -r '.result.tab.tab_id')
out=$(lab workspace create --cwd "$TMP_ROOT" --label main --no-focus) || fail "could not create the main workspace"
MAIN_WS=$(printf '%s' "$out" | jq -r '.result.workspace.workspace_id')
MAIN_PANE=$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id')
[ "$(lab workspace list | jq -r '.result.workspaces[] | select(.focused == true) | .label')" = other ] \
  || fail "setup expected the other workspace to hold focus"

run_topic() {
  env HERDR_ENV=1 HERDR_PANE_ID="$MAIN_PANE" HERDR_SESSION="$HERDR_LAB_SESSION" HERDR_SOCKET_PATH="$LAB_SOCKET" \
    CLAUDE_CONFIG_DIR="$TMP_ROOT/claude-config" FM_TOPIC_CLAUDE_BIN="$TMP_ROOT/bin/stand-in-agent" \
    FM_HOME="$HOME_DIR" "$ROOT/bin/fm-topic.sh" "$@"
}

topic_tabs() { lab tab list --workspace "$MAIN_WS" | jq -r '[.result.tabs[] | select(.label == "topic:crm") | .tab_id] | join(" ")'; }
focused_tab() { lab tab list --workspace "$MAIN_WS" | jq -r '.result.tabs[] | select(.focused == true) | .tab_id'; }
focused_ws() { lab workspace list | jq -r '.result.workspaces[] | select(.focused == true) | .workspace_id'; }

out=$(run_topic open crm "$TOPIC_DIR" --context "$TMP_ROOT/note.md" 2>&1) || fail "open failed: $out"
TAB=$(topic_tabs)
[ -n "$TAB" ] && [ "${TAB#* }" = "$TAB" ] || fail "expected exactly one topic:crm tab in the main workspace, got '$TAB'"
[ "$(focused_tab)" = "$TAB" ] || fail "the new topic tab is not focused (focused: $(focused_tab))"
[ "$(focused_ws)" = "$MAIN_WS" ] || fail "focusing the topic tab did not bring up the caller's workspace"
PANE=$(lab pane list --workspace "$MAIN_WS" | jq -r --arg t "$TAB" '.result.panes[] | select(.tab_id == $t) | .pane_id')
seen=
for _ in $(seq 1 50); do
  seen=$(lab pane read "$PANE" --source recent --lines 200 2>/dev/null | grep -F "topic-agent-up" || true)
  [ -n "$seen" ] && break
  sleep 0.2
done
case "$seen" in
  *"name=crm cwd=$TOPIC_DIR"*) ;;
  *) fail "the topic agent did not start in the topic folder (saw: '$seen')" ;;
esac
pass "open creates, starts, and focuses a labeled topic tab in the caller's own workspace"

lab tab focus "$OTHER_TAB" >/dev/null || fail "could not move focus to the other workspace"
out=$(run_topic open crm "$TOPIC_DIR" 2>&1) || fail "reopen failed: $out"
case "$out" in *"focused: crm tab $TAB (existing)"*) ;; *) fail "reopen did not report the existing tab: $out" ;; esac
[ "$(topic_tabs)" = "$TAB" ] || fail "reopen changed the topic tabs: '$(topic_tabs)'"
[ "$(focused_tab)" = "$TAB" ] && [ "$(focused_ws)" = "$MAIN_WS" ] || fail "reopen did not focus the existing tab"
[ "$(lab tab list --workspace "$MAIN_WS" | jq '.result.tabs | length')" = 2 ] || fail "reopen created an extra tab"
pass "reopening the topic focuses the same tab without creating another"

cleanup_all || { printf 'not ok - lab teardown or default-session tripwire failed\n' >&2; exit 1; }
pass "lab torn down with the default session unchanged"

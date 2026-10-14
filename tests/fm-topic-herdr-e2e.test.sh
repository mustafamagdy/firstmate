#!/usr/bin/env bash
# tests/fm-topic-herdr-e2e.test.sh - isolated real-Herdr proof for topic tabs.
#
# Runs the real bin/fm-topic.sh from a scratch "firstmate" pane in a named lab
# session and proves, against Herdr itself: open creates a labeled tab in that
# pane's own workspace, starts the topic agent there in the topic folder, and
# focuses it; reopening the topic focuses the same tab without creating another;
# logging a result types the doorbell into the live tab, whose prompt hook then
# shows the result once; a closed tab reopens on its recorded chat and shows a
# result logged while it was closed first; a chat that cannot be resumed falls
# back to a new chat with the starting note; and a renamed tab or a stale pane
# record is rebound to the live tab and pane.
# The agent is a token-free stand-in that registers itself with Herdr, runs the
# topic's SessionStart hook with a chat id, and runs its prompt hook on its
# first prompt and on every line it receives, as Claude Code does, so this
# spends no model tokens. A resume of the chat named in $TMP_ROOT/gone-chat
# fails as a deleted Claude chat does.
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
cat > "$TMP_ROOT/bin/stand-in-agent" <<AGENT
#!/usr/bin/env python3
import json, os, subprocess, sys, uuid
args = sys.argv[1:]
resume = args[args.index("--resume") + 1] if "--resume" in args else ""
try:
    gone = open("$TMP_ROOT/gone-chat").read().strip()
except OSError:
    gone = ""
if resume and resume == gone:
    print("No conversation found with session ID: " + resume, file=sys.stderr, flush=True)
    sys.exit(1)
chat = resume or str(uuid.uuid4())
subprocess.run(["herdr", "pane", "report-agent", "--source", "fm-topic-e2e", "--agent", "stand-in",
                "--state", "idle", "--agent-session-id", chat, os.environ["HERDR_PANE_ID"],
                "--session", "$HERDR_LAB_SESSION"],
               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
with open(args[args.index("--settings") + 1]) as f:
    hooks = json.load(f)["hooks"]
hook = hooks["UserPromptSubmit"][0]["hooks"][0]["command"]
subprocess.run(["bash", "-c", hooks["SessionStart"][0]["hooks"][0]["command"]],
               input=json.dumps({"hook_event_name": "SessionStart", "session_id": chat, "cwd": os.getcwd()}),
               text=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
def prompt(text):
    print("prompt: " + text.strip(), flush=True)
    print(subprocess.run(["bash", "-c", hook], capture_output=True, text=True).stdout, flush=True)
print("topic-agent-up name=%s cwd=%s chat=%s" % (args[1], os.getcwd(), chat), flush=True)
print("resumed=%s" % bool(resume), flush=True)
prompt(args[-1])
for line in sys.stdin:
    prompt(line)
AGENT
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
meta_val() { sed -n "s/^$1=//p" "$HOME_DIR/data/topics/crm/topic.meta"; }
tab_pane() { lab pane list --workspace "$MAIN_WS" | jq -r --arg t "$1" '.result.panes[] | select(.tab_id == $t) | .pane_id'; }

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
  *"name=crm cwd=$TOPIC_DIR chat="*) ;;
  *) fail "the topic agent did not start in the topic folder (saw: '$seen')" ;;
esac
CHAT=${seen##*chat=}
CHAT=${CHAT%% *}
case "$out" in *"new chat: no earlier crm chat is recorded"*) ;; *) fail "a first open did not report a new chat: $out" ;; esac
[ "$(meta_val agent_session)" = "$CHAT" ] || fail "the tab's chat $CHAT was not recorded (recorded: '$(meta_val agent_session)')"
pass "open creates, starts, and focuses a labeled topic tab in the caller's own workspace and records its chat"

lab tab focus "$OTHER_TAB" >/dev/null || fail "could not move focus to the other workspace"
out=$(run_topic open crm "$TOPIC_DIR" 2>&1) || fail "reopen failed: $out"
case "$out" in *"focused: crm tab $TAB (existing)"*) ;; *) fail "reopen did not report the existing tab: $out" ;; esac
[ "$(topic_tabs)" = "$TAB" ] || fail "reopen changed the topic tabs: '$(topic_tabs)'"
[ "$(focused_tab)" = "$TAB" ] && [ "$(focused_ws)" = "$MAIN_WS" ] || fail "reopen did not focus the existing tab"
[ "$(lab tab list --workspace "$MAIN_WS" | jq '.result.tabs | length')" = 2 ] || fail "reopen created an extra tab"
pass "reopening the topic focuses the same tab without creating another"

pane_shows() {  # <pane> <text>: wait for <text> in the pane's recent output
  for _ in $(seq 1 50); do
    lab pane read "$1" --source recent --lines 400 2>/dev/null | grep -F -- "$2" >/dev/null && return 0
    sleep 0.2
  done
  return 1
}

out=$(run_topic log crm "The CRM import fix is merged: https://example.invalid/pr/7" 2>&1) || fail "log failed: $out"
case "$out" in *"delivered: crm tab $TAB"*) ;; *) fail "log did not deliver into the live tab: $out" ;; esac
pane_shows "$PANE" "prompt: : New crm topic result from the main firstmate" \
  || fail "the doorbell line did not reach the live tab"
pane_shows "$PANE" "The CRM import fix is merged: https://example.invalid/pr/7" \
  || fail "the prompt hook did not show the logged result in the tab"
[ -z "$(run_topic unseen crm)" ] || fail "the result shown through the hook is still unseen"
pass "logging a result rings the live tab, whose prompt hook shows it once"

lab tab close "$TAB" >/dev/null || fail "could not close the topic tab"
out=$(run_topic log crm "Second result while the tab was closed" 2>&1) || fail "log with the tab closed failed: $out"
case "$out" in *"not delivered: its tab is closed or its pane is gone"*) ;; *) fail "log with the tab closed did not report the skip: $out" ;; esac
out=$(run_topic open crm "$TOPIC_DIR" 2>&1) || fail "reopen after close failed: $out"
case "$out" in *"resumed: the last crm chat $CHAT"*) ;; *) fail "reopening did not resume the recorded chat: $out" ;; esac
TAB=$(topic_tabs)
PANE=$(tab_pane "$TAB")
pane_shows "$PANE" "resumed=True" || fail "the recreated tab did not resume chat $CHAT"
pane_shows "$PANE" "Second result while the tab was closed" \
  || fail "the resumed tab did not show the result logged while it was closed"
pass "a closed tab reopens on its recorded chat and shows the result it missed first"

lab tab rename "$TAB" crm >/dev/null || fail "could not rename the topic tab"
out=$(run_topic open crm "$TOPIC_DIR" 2>&1) || fail "open of the renamed tab failed: $out"
case "$out" in *"focused: crm tab $TAB (existing)"*"restored the tab label topic:crm"*) ;; *) fail "open did not recognize the renamed tab: $out" ;; esac
[ "$(topic_tabs)" = "$TAB" ] || fail "the renamed tab did not get its topic label back"
lab tab rename "$TAB" crm >/dev/null || fail "could not rename the topic tab again"
out=$(run_topic log crm "Third result after a rename" 2>&1) || fail "log after a rename failed: $out"
case "$out" in *"delivered: crm tab $TAB"*) ;; *) fail "log did not reach the renamed tab: $out" ;; esac
[ "$(topic_tabs)" = "$TAB" ] || fail "log did not restore the topic label"
pane_shows "$PANE" "Third result after a rename" || fail "the renamed tab did not show the result"
sed -i 's/^pane_id=.*/pane_id=gone-pane/' "$HOME_DIR/data/topics/crm/topic.meta"
out=$(run_topic log crm "Fourth result with a stale pane record" 2>&1) || fail "log with a stale pane failed: $out"
case "$out" in *"delivered: crm tab $TAB"*) ;; *) fail "log did not reach the live pane: $out" ;; esac
[ "$(meta_val pane_id)" = "$PANE" ] || fail "log did not rebind the stale pane record to $PANE"
pane_shows "$PANE" "Fourth result with a stale pane record" || fail "the live pane did not show the result"
pass "a renamed tab and a stale pane record are rebound to the live tab"

printf '%s\n' "$CHAT" > "$TMP_ROOT/gone-chat"
lab tab close "$TAB" >/dev/null || fail "could not close the topic tab"
out=$(run_topic open crm "$TOPIC_DIR" --context "$TMP_ROOT/note.md" 2>&1) || fail "reopen of a gone chat failed: $out"
case "$out" in *"new chat: the last crm chat $CHAT could not be resumed"*) ;; *) fail "a failed resume was not reported: $out" ;; esac
TAB=$(topic_tabs)
PANE=$(tab_pane "$TAB")
pane_shows "$PANE" "resumed=False" || fail "the fallback did not start a new chat"
pane_shows "$PANE" "Starting note: one open PR." || fail "the fallback chat did not get the starting note"
[ "$(meta_val agent_session)" != "$CHAT" ] || fail "the fallback chat was not recorded"
pass "a chat that cannot be resumed falls back to a new chat with the starting note"

cleanup_all || { printf 'not ok - lab teardown or default-session tripwire failed\n' >&2; exit 1; }
pass "lab torn down with the default session unchanged"

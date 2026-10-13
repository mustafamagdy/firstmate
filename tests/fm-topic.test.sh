#!/usr/bin/env bash
# tests/fm-topic.test.sh - topic tabs (bin/fm-topic.sh) against a stateful fake
# herdr: create, reuse of an existing tab, label adoption and ambiguity,
# directory refusals, the generated launcher and its unseen-results hook, the
# topic log with its seen tracking and skipped deliveries, task links, and the
# inbox handoff command the topic agent is told to run, the chat recorded for
# each tab, resume on reopen with its fallback, and rebinding to the live pane
# of a refocused or relabeled tab, and decision entries.
# tests/fm-topic-herdr-e2e.test.sh proves create, reuse, focus, doorbell
# delivery, resume with its fallback, and rebinding on real Herdr.
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-topic)
TOPIC_BIN="$ROOT/bin/fm-topic.sh"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
STATE_JSON="$TMP_ROOT/herdr-state.json"
CALLS="$TMP_ROOT/herdr-calls.log"
SOCKET="$TMP_ROOT/sock/herdr.sock"
mkdir -p "$TMP_ROOT/sock"

# A stateful herdr stand-in: one session, workspaces, tabs, and panes kept in a
# JSON file, with every call logged one line each (minus the --session flag).
cat > "$FAKEBIN/herdr" <<'PY'
#!/usr/bin/env python3
import json, os, sys
state_path = os.environ["FAKE_HERDR_STATE"]
args = sys.argv[1:]
if "--session" in args:
    i = args.index("--session")
    del args[i:i + 2]
with open(os.environ["FAKE_HERDR_CALLS"], "a") as log:
    log.write(" ".join(args) + "\n")
with open(state_path) as f:
    st = json.load(f)
def out(obj):
    print(json.dumps(obj))
def save():
    with open(state_path, "w") as f:
        json.dump(st, f)
def opt(name):
    return args[args.index(name) + 1] if name in args else None
def tab_obj(t):
    return {"tab_id": t["tab_id"], "workspace_id": t["workspace_id"], "label": t["label"],
            "focused": st["focused_tab"] == t["tab_id"], "pane_count": 1, "agent_status": "unknown"}
cmd = args[:2]
if args[:1] == ["status"]:
    out({"client": {"protocol": 22, "version": "0.9.1"}, "server": {"running": True, "compatible": True}})
elif cmd == ["session", "list"]:
    out({"sessions": [{"name": os.environ["HERDR_SESSION"], "running": True, "socket_path": os.environ["FAKE_HERDR_SOCKET"]}]})
elif cmd == ["workspace", "list"]:
    out({"result": {"workspaces": [{"workspace_id": w, "label": w} for w in st["workspaces"]]}})
elif cmd == ["pane", "get"]:
    p = next((p for p in st["panes"] if p["pane_id"] == args[2]), None)
    if p is None:
        sys.exit(1)
    out({"result": {"pane": p}})
elif cmd == ["agent", "get"]:
    chat = st.get("agents", {}).get(args[2])
    if chat is None:
        print(json.dumps({"error": {"code": "agent_not_found", "message": "no agent"}}))
        sys.exit(1)
    out({"result": {"agent": {"agent": "claude", "agent_status": "unknown", "pane_id": args[2],
                              "agent_session": {"agent": "claude", "kind": "id", "source": "herdr:claude", "value": chat}}}})
elif cmd == ["pane", "list"]:
    out({"result": {"panes": [p for p in st["panes"] if p["workspace_id"] == opt("--workspace")]}})
elif cmd == ["pane", "run"]:
    st["runs"].append({"pane": args[2], "command": args[3]})
    save()
    if os.environ.get("FAKE_HERDR_EXEC") == "1":
        import subprocess
        subprocess.run(["bash", "-c", args[3]], env=dict(os.environ, HERDR_PANE_ID=args[2]),
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    out({"result": {"type": "ok"}})
elif cmd == ["tab", "get"]:
    t = next((t for t in st["tabs"] if t["tab_id"] == args[2]), None)
    if t is None:
        sys.exit(1)
    out({"result": {"tab": tab_obj(t)}})
elif cmd == ["tab", "list"]:
    out({"result": {"tabs": [tab_obj(t) for t in st["tabs"] if t["workspace_id"] == opt("--workspace")]}})
elif cmd == ["tab", "create"]:
    ws = opt("--workspace")
    st["seq"] += 1
    tab = {"tab_id": "%s:t%d" % (ws, st["seq"]), "workspace_id": ws, "label": opt("--label")}
    pane = {"pane_id": "%s:p%d" % (ws, st["seq"]), "tab_id": tab["tab_id"], "workspace_id": ws, "cwd": opt("--cwd")}
    st["tabs"].append(tab)
    st["panes"].append(pane)
    save()
    out({"result": {"tab": tab_obj(tab), "root_pane": pane}})
elif cmd == ["tab", "rename"]:
    t = next((t for t in st["tabs"] if t["tab_id"] == args[2]), None)
    if t is None:
        sys.exit(1)
    t["label"] = " ".join(args[3:])
    save()
    out({"result": {"tab": tab_obj(t)}})
elif cmd == ["tab", "focus"]:
    if not any(t["tab_id"] == args[2] for t in st["tabs"]):
        sys.exit(1)
    st["focused_tab"] = args[2]
    save()
    out({"result": {"type": "tab_info"}})
else:
    sys.stderr.write("fake herdr: unsupported %s\n" % args)
    sys.exit(2)
PY
chmod +x "$FAKEBIN/herdr"

# The main firstmate's own pane lives in workspace w1, tab w1:t1.
reset_herdr() {
  cat > "$STATE_JSON" <<'JSON'
{"seq": 1, "focused_tab": "w1:t1", "workspaces": ["w1"],
 "tabs": [{"tab_id": "w1:t1", "workspace_id": "w1", "label": "main"}],
 "panes": [{"pane_id": "w1:p1", "tab_id": "w1:t1", "workspace_id": "w1", "cwd": "/"}],
 "runs": []}
JSON
  : > "$CALLS"
}

herdr_state() { jq -r "$1" "$STATE_JSON"; }

HOME_DIR="$TMP_ROOT/fm-home"
WORK="$TMP_ROOT/work"
CLAUDE_STORE="$TMP_ROOT/claude-config"
mkdir -p "$HOME_DIR/data" "$HOME_DIR/config" "$HOME_DIR/state" "$WORK/saas/crm" "$WORK/mbg/xelta" "$CLAUDE_STORE"
printf '# roots\n%s\n' "$WORK" > "$HOME_DIR/config/topic-roots"

run_topic() {
  env -u TMUX -u TMUX_PANE PATH="$FAKEBIN:$PATH" \
    HERDR_ENV=1 HERDR_PANE_ID=w1:p1 HERDR_SESSION=fm-topic-fake HERDR_SOCKET_PATH="$SOCKET" \
    FAKE_HERDR_STATE="$STATE_JSON" FAKE_HERDR_CALLS="$CALLS" FAKE_HERDR_SOCKET="$SOCKET" \
    CLAUDE_CONFIG_DIR="$CLAUDE_STORE" FM_HOME="$HOME_DIR" "$TOPIC_BIN" "$@"
}

# --- directory policy -----------------------------------------------------

run_topic check-dir "$WORK/saas/crm" || fail "a project folder inside the workspace root is accepted"
pass "check-dir accepts a project folder inside a workspace root"

expect_refused_dir() {  # <dir> <expected-reason> <label>
  local err rc=0
  err=$(run_topic check-dir "$1" 2>&1) || rc=$?
  expect_code 1 "$rc" "$3"
  assert_contains "$err" "$2" "$3 names its reason"
}

mkdir -p "$TMP_ROOT/elsewhere"
expect_refused_dir "$TMP_ROOT/elsewhere" "is not inside a workspace root" "a folder outside the workspace roots is refused"
expect_refused_dir "$WORK" "is not inside a workspace root" "the workspace root itself is refused"
expect_refused_dir "$TMP_ROOT/missing" "is not an accessible directory" "a missing folder is refused"
mkdir -p "$WORK/shared/fm/bin" "$WORK/shared/fm/projects/app"
: > "$WORK/shared/fm/AGENTS.md"
: > "$WORK/shared/fm/bin/fm-session-start.sh"
expect_refused_dir "$WORK/shared/fm" "firstmate home" "a firstmate home is refused"
expect_refused_dir "$WORK/shared/fm/projects/app" "firstmate home" "a folder inside a firstmate home is refused"
mkdir -p "$WORK/mbg/firstmate/data"
printf 'mbg\n' > "$WORK/mbg/firstmate/.fm-secondmate-home"
expect_refused_dir "$WORK/mbg/firstmate/data" "firstmate home" "a folder inside a secondmate home is refused"
ln -s "$WORK/shared/fm" "$WORK/saas/fm-link"
expect_refused_dir "$WORK/saas/fm-link" "firstmate home" "a symlink into a firstmate home is refused"
pass "check-dir refuses folders outside the roots and firstmate homes"

reset_herdr
rc=0
err=$(run_topic open crm "$TMP_ROOT/elsewhere" 2>&1) || rc=$?
expect_code 1 "$rc" "open refuses a folder outside the workspace roots"
assert_contains "$err" "refusing to open topic 'crm'" "open names the refused topic"
assert_equals "" "$(cat "$CALLS")" "a refused folder makes no Herdr call"
pass "open refuses a bad folder before touching Herdr"

rc=0
err=$(CLAUDE_CONFIG_DIR="$CLAUDE_STORE" FM_HOME="$HOME_DIR" "$ROOT/bin/fm-claude-trust.sh" --topic-dir "$WORK/shared/fm" 2>&1) || rc=$?
expect_code 1 "$rc" "trust registration refuses a firstmate home as a topic folder"
assert_contains "$err" "firstmate home" "the trust refusal carries the folder policy's reason"
assert_absent "$CLAUDE_STORE/.claude.json" "a refused topic folder writes no trust"
pass "topic-folder trust registration follows the folder policy"

# --- create ---------------------------------------------------------------

reset_herdr
printf 'CRM: PR https://example.invalid/pr/7 waits for review.\n' > "$TMP_ROOT/crm-note.md"
out=$(run_topic open CRM "$WORK/saas/crm" --context "$TMP_ROOT/crm-note.md")
assert_contains "$out" "opened: crm tab w1:t2" "open reports the new tab"
assert_equals "topic:crm" "$(herdr_state '.tabs[] | select(.tab_id == "w1:t2") | .label')" "the tab carries the stable topic label"
assert_equals "w1" "$(herdr_state '.tabs[] | select(.tab_id == "w1:t2") | .workspace_id')" "the tab opens in the caller's own workspace"
assert_equals "$WORK/saas/crm" "$(herdr_state '.panes[] | select(.pane_id == "w1:p2") | .cwd')" "the tab starts in the topic folder"
assert_equals "w1:t2" "$(herdr_state .focused_tab)" "the new tab is focused"
TDIR="$HOME_DIR/data/topics/crm"
assert_equals "exec bash $TDIR/launch.sh" "$(herdr_state '.runs[0].command')" "the launcher is started in the new pane"
assert_equals "w1:p2" "$(herdr_state '.runs[0].pane')" "the launcher runs in the new tab's pane"
assert_grep "tab create --workspace w1 --cwd $WORK/saas/crm --label topic:crm --no-focus" "$CALLS" "creation never steals focus before the explicit focus"
for key in "topic=crm" "dir=$WORK/saas/crm" "session=fm-topic-fake" "workspace_id=w1" "tab_id=w1:t2" "pane_id=w1:p2" "label=topic:crm"; do
  assert_grep "$key" "$TDIR/topic.meta" "the topic record keeps $key"
done
assert_present "$TDIR/log.md" "the topic log exists"
assert_equals "CRM: PR https://example.invalid/pr/7 waits for review." "$(cat "$TDIR/context.md")" "the starting note is kept"
node -e '
const s = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
if (s.projects?.[process.argv[2]]?.hasTrustDialogAccepted !== true) process.exit(1);
' "$CLAUDE_STORE/.claude.json" "$WORK/saas/crm" || fail "Claude workspace trust is pre-registered for the topic folder"
pass "open creates a focused topic tab in the caller's workspace with its records"

# --- generated launcher ---------------------------------------------------

cat > "$FAKEBIN/fake-claude" <<'SH'
#!/usr/bin/env bash
{
  printf 'cwd=%s\n' "$PWD"
  printf 'fm_home=%s\n' "${FM_HOME:-unset}"
  printf 'child_session=%s\n' "${CLAUDE_CODE_CHILD_SESSION:-unset}"
  printf 'claude_config=%s\n' "${CLAUDE_CONFIG_DIR:-unset}"
  for a in "$@"; do printf 'arg=%s\n' "$a"; done
} > "$FAKE_CLAUDE_OUT"
SH
chmod +x "$FAKEBIN/fake-claude"
reset_herdr
rm -rf "$HOME_DIR/data/topics/xelta"
FM_TOPIC_CLAUDE_BIN="$FAKEBIN/fake-claude" run_topic open xelta "$WORK/mbg/xelta" >/dev/null
XDIR="$HOME_DIR/data/topics/xelta"
FAKE_CLAUDE_OUT="$TMP_ROOT/claude-args" FM_HOME=/leaked FM_ROOT=/leaked CLAUDE_CODE_CHILD_SESSION=1 bash "$XDIR/launch.sh"
args=$(cat "$TMP_ROOT/claude-args")
assert_contains "$args" "cwd=$WORK/mbg/xelta" "the agent starts in the topic folder"
assert_contains "$args" "fm_home=unset" "firstmate environment does not leak into the topic agent"
assert_contains "$args" "child_session=unset" "a parent Claude session's markers do not leak into the topic agent"
assert_contains "$args" "claude_config=$CLAUDE_STORE" "the agent uses the Claude store trust was registered in"
assert_contains "$args" $'arg=--name\narg=xelta' "the session is named for the topic"
assert_contains "$args" $'arg=--add-dir\narg='"$XDIR" "the agent can read its topic records"
assert_contains "$args" "You are the xelta topic chat" "the standing instructions are appended to the system prompt"
assert_contains "$args" "read your topic log at $XDIR/log.md" "without a starting note the first prompt points at the log"
assert_contains "$args" "Show the captain any unseen topic results first" "the first prompt shows unseen results first"
assert_contains "$args" $'arg=--settings\narg='"$XDIR/settings.json" "the agent runs with the topic's hook settings"
hook=$(jq -r '.hooks.UserPromptSubmit[0].hooks[0].command' "$XDIR/settings.json")
assert_contains "$hook" "fm-topic.sh unseen xelta --hook" "every prompt first runs the unseen-results hook"
rc=0
out=$(env -u FM_HOME bash -c "$hook") || rc=$?
expect_code 0 "$rc" "the hook succeeds with nothing unseen"
assert_equals "" "$out" "the hook is silent with nothing unseen"
assert_not_contains "$(cat "$XDIR/instructions.md")" "{{" "every template placeholder is rendered"
pass "the generated launcher starts the topic agent with its instructions"

# --- inbox handoff --------------------------------------------------------

handoff=$(grep -F 'bin/fm-inbox.sh note "[topic:xelta] <the request' "$XDIR/instructions.md") \
  || fail "the instructions give the inbox handoff command"
assert_equals "FM_HOME=$HOME_DIR $ROOT/bin/fm-inbox.sh note \"[topic:xelta] <the request in the captain's words, plus any context you gathered>\"" \
  "$handoff" "the handoff command targets the main home's inbox with the topic tag"
assert_contains "$(cat "$XDIR/instructions.md")" "FM_HOME=$HOME_DIR $ROOT/bin/fm-inbox.sh note \"[topic:xelta] Decision answer: " \
  "the tab returns a decision answer to the main home's inbox with the topic tag"
handoff=${handoff/<the request in the captain*gathered>/fix the render queue}
FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
  bash -c "$handoff" >/dev/null || fail "the handoff command runs"
note=$(cat "$HOME_DIR"/state/inbox/*.note)
assert_contains "$note" "[topic:xelta] fix the render queue" "the handed-off note carries the topic tag"
grep -q 'inbox:' "$HOME_DIR/state/.wake-queue" || fail "the handoff wakes the main firstmate"
pass "the topic agent's handoff command lands a tagged note in the main inbox"

# --- reuse ----------------------------------------------------------------

reset_herdr
run_topic open crm "$WORK/saas/crm" >/dev/null
tab=$(sed -n 's/^tab_id=//p' "$TDIR/topic.meta")
# Move focus away, then reopen: the same tab is focused and nothing is created.
python3 - "$STATE_JSON" <<'PY'
import json, sys
st = json.load(open(sys.argv[1])); st["focused_tab"] = "w1:t1"; json.dump(st, open(sys.argv[1], "w"))
PY
: > "$CALLS"
out=$(run_topic open crm "$WORK/saas/crm" --context "$TMP_ROOT/crm-note.md")
assert_contains "$out" "focused: crm tab $tab (existing)" "reopening reports the existing tab"
assert_contains "$out" "starting note is used only for a new tab" "a starting note on reuse is called out"
assert_no_grep "tab create" "$CALLS" "reopening creates no tab"
assert_no_grep "pane run" "$CALLS" "reopening starts no second agent"
assert_equals "$tab" "$(herdr_state .focused_tab)" "reopening focuses the existing tab"
pass "reopening a live topic focuses its existing tab"

rc=0
err=$(run_topic open crm "$WORK/mbg/xelta" 2>&1) || rc=$?
expect_code 1 "$rc" "reopening a live topic in another folder is refused"
assert_contains "$err" "already open in $WORK/saas/crm" "the refusal names where the topic is open"
pass "a live topic is never silently moved to another folder"

# The recorded tab was closed: the next open creates a fresh one.
python3 - "$STATE_JSON" "$tab" <<'PY'
import json, sys
st = json.load(open(sys.argv[1]))
st["tabs"] = [t for t in st["tabs"] if t["tab_id"] != sys.argv[2]]
st["focused_tab"] = "w1:t1"
json.dump(st, open(sys.argv[1], "w"))
PY
out=$(run_topic open crm "$WORK/saas/crm")
assert_contains "$out" "opened: crm" "a closed topic tab is recreated"
assert_not_equals "$tab" "$(sed -n 's/^tab_id=//p' "$TDIR/topic.meta")" "the record moves to the new tab"
pass "a topic whose tab was closed opens a fresh tab"

# --- label adoption and ambiguity -----------------------------------------

reset_herdr
rm -rf "$HOME_DIR/data/topics/xelta"
python3 - "$STATE_JSON" <<'PY'
import json, sys
st = json.load(open(sys.argv[1]))
st["tabs"].append({"tab_id": "w1:t9", "workspace_id": "w1", "label": "topic:xelta"})
st["panes"].append({"pane_id": "w1:p9", "tab_id": "w1:t9", "workspace_id": "w1", "cwd": "/x"})
json.dump(st, open(sys.argv[1], "w"))
PY
out=$(run_topic open xelta "$WORK/mbg/xelta")
assert_contains "$out" "focused: xelta tab w1:t9 (existing)" "an unrecorded tab with the topic label is reused"
assert_grep "pane_id=w1:p9" "$HOME_DIR/data/topics/xelta/topic.meta" "the adopted tab's pane is recorded"
assert_no_grep "tab create" "$CALLS" "adoption creates no tab"
python3 - "$STATE_JSON" <<'PY'
import json, sys
st = json.load(open(sys.argv[1]))
st["tabs"].append({"tab_id": "w1:t10", "workspace_id": "w1", "label": "topic:xelta"})
json.dump(st, open(sys.argv[1], "w"))
PY
rm -rf "$HOME_DIR/data/topics/xelta"
rc=0
err=$(run_topic open xelta "$WORK/mbg/xelta" 2>&1) || rc=$?
expect_code 1 "$rc" "two tabs with the topic label are refused"
assert_contains "$err" "has 2 tabs labeled 'topic:xelta'" "the ambiguity is named"
pass "label lookup reuses one match and refuses an ambiguous one"

# --- outside Herdr --------------------------------------------------------

reset_herdr
rc=0
err=$(env -u HERDR_ENV -u HERDR_PANE_ID PATH="$FAKEBIN:$PATH" FAKE_HERDR_STATE="$STATE_JSON" FAKE_HERDR_CALLS="$CALLS" \
  FM_HOME="$HOME_DIR" "$TOPIC_BIN" open crm "$WORK/saas/crm" 2>&1) || rc=$?
expect_code 1 "$rc" "open outside Herdr is refused"
assert_contains "$err" "need firstmate running inside a Herdr pane" "the refusal says topic tabs need Herdr"
assert_equals "" "$(cat "$CALLS")" "no Herdr call is made outside Herdr"
pass "open outside Herdr refuses with a clear message"

# --- log and list ---------------------------------------------------------

: > "$CALLS"
out=$(run_topic log crm "The CRM import fix is merged: https://example.invalid/pr/7")
assert_contains "$out" "logged: crm" "logging reports the entry"
assert_contains "$out" "not delivered: its tab is closed or its pane is gone" "a closed tab skips delivery and says why"
assert_no_grep "send-text" "$CALLS" "nothing is typed for a closed tab"
printf 'Second result\nwith two lines\n' | run_topic log crm - >/dev/null
log=$(cat "$TDIR/log.md")
assert_contains "$log" "The CRM import fix is merged: https://example.invalid/pr/7" "a logged result is appended"
assert_contains "$log" $'Second result\nwith two lines' "a stdin result is appended"
rc=0
run_topic log nothere "x" >/dev/null 2>&1 || rc=$?
expect_code 1 "$rc" "logging to an unknown topic is refused"
rc=0
run_topic log crm "   " >/dev/null 2>&1 || rc=$?
expect_code 1 "$rc" "an empty log entry is refused"
list=$(run_topic list)
assert_contains "$list" "crm"$'\t'"$WORK/saas/crm" "list names each topic and its folder"
pass "results append to the topic log and list shows topics"

# --- unseen results -------------------------------------------------------

out=$(run_topic unseen crm)
assert_contains "$out" "The CRM import fix is merged: https://example.invalid/pr/7" "unseen prints the first result"
assert_contains "$out" $'Second result\nwith two lines' "unseen prints the second result"
assert_not_contains "$out" "topic log" "unseen never prints the log title"
assert_equals "" "$(run_topic unseen crm)" "a shown result is never shown again"
rc=0
out=$(run_topic unseen crm --hook) || rc=$?
expect_code 0 "$rc" "the hook succeeds with nothing unseen"
assert_equals "" "$out" "the hook prints nothing with nothing unseen"
run_topic log crm "Third result" >/dev/null
out=$(run_topic unseen crm --hook)
assert_contains "$out" "Unseen crm topic results from the main firstmate" "the hook frames unseen results for the agent"
assert_contains "$out" "Third result" "the hook shows the new result"
assert_not_contains "$out" "Second result" "the hook shows only results not yet shown"
assert_equals "" "$(run_topic unseen crm --hook)" "the hook marks what it showed as seen"
rc=0
out=$(run_topic unseen nothere --hook) || rc=$?
expect_code 0 "$rc" "the hook never fails a prompt, even for an unknown topic"
assert_equals "" "$out" "the hook prints nothing for an unknown topic"
mkdir -p "$HOME_DIR/data/topics/legacy"
printf 'topic=legacy\n' > "$HOME_DIR/data/topics/legacy/topic.meta"
printf '# legacy topic log\n\n## 2026-10-13T07:40:51Z\n\nArea and team created.\n' > "$HOME_DIR/data/topics/legacy/log.md"
out=$(run_topic unseen legacy)
assert_contains "$out" "Area and team created." "a log from before seen tracking shows its results as unseen"
assert_not_contains "$out" "legacy topic log" "the legacy log's title is not shown"
pass "unseen shows each result exactly once and the hook stays silent and safe"

# --- delivery to a live tab without an agent ------------------------------

reset_herdr
run_topic open crm "$WORK/saas/crm" >/dev/null
: > "$CALLS"
out=$(run_topic log crm "Fourth result")
assert_contains "$out" "not delivered: no live agent is running in the tab" "a tab without a live agent is not typed into"
assert_no_grep "send-text" "$CALLS" "nothing is typed without a live agent"
out=$(run_topic open crm "$WORK/saas/crm")
assert_contains "$out" "focused: crm tab" "reopening focuses the existing tab"
assert_contains "$out" "not delivered: no live agent" "reopening a tab with unseen results rings it"
run_topic unseen crm >/dev/null
out=$(run_topic open crm "$WORK/saas/crm")
assert_not_contains "$out" "delivered" "reopening with nothing unseen rings nothing"
pass "delivery is skipped safely when no agent can receive it, and reopening rings for unseen results"

# --- task links -----------------------------------------------------------

assert_contains "$(run_topic link crm fm-crm-fix)" "linked: fm-crm-fix -> crm" "a task is linked to its topic"
run_topic link crm fm-crm-fix >/dev/null
assert_equals 1 "$(grep -cx fm-crm-fix "$TDIR/links")" "linking twice records the task once"
out=$(run_topic hint fm-crm-fix unrelated)
assert_contains "$out" 'TOPIC RESULT: fm-crm-fix carries a request from the crm topic tab' "a linked task names its topic"
assert_contains "$out" 'bin/fm-topic.sh log crm "<outcome>", adding --decision for a question the captain must answer and --done fm-crm-fix' "the hint names the exact log command"
assert_equals 1 "$(printf '%s\n' "$out" | grep -c 'TOPIC RESULT')" "an unlinked task prints no hint"
run_topic log crm --done fm-crm-fix "The CRM fix is merged." >/dev/null
assert_contains "$(cat "$TDIR/log.md")" "The CRM fix is merged." "a final result is logged"
assert_equals "" "$(run_topic hint fm-crm-fix)" "--done unlinks the finished task"
run_topic link crm mbg >/dev/null
run_topic unlink crm mbg >/dev/null
assert_equals "" "$(run_topic hint mbg)" "unlink removes a link"
rc=0
run_topic link crm 'bad id' >/dev/null 2>&1 || rc=$?
expect_code 1 "$rc" "an invalid task id is refused"
pass "task links drive topic result hints until the final result unlinks them"

rc=0
run_topic open 'bad/name' "$WORK/saas/crm" >/dev/null 2>&1 || rc=$?
expect_code 1 "$rc" "an invalid topic name is refused"
pass "invalid topic names are refused"

# --- chat recording, resume, and rebinding --------------------------------

# A token-free Claude stand-in: it registers its chat with the fake Herdr as
# Herdr's Claude integration does, runs the topic's SessionStart hook with the
# hook JSON Claude sends, and fails a resume of a chat listed as gone.
cat > "$FAKEBIN/fake-claude-chat" <<'SH'
#!/usr/bin/env bash
settings='' resume=''
prev=''
for a in "$@"; do
  case "$prev" in --settings) settings=$a ;; --resume) resume=$a ;; esac
  prev=$a
done
{ printf 'launch\n'; for a in "$@"; do printf 'arg=%s\n' "$a"; done; } >> "$FAKE_CLAUDE_OUT"
if [ -n "$resume" ] && [ "$resume" = "${FAKE_CLAUDE_GONE:-}" ]; then
  echo "No conversation found with session ID: $resume" >&2
  exit 1
fi
chat=${resume:-$FAKE_CLAUDE_NEW_CHAT}
python3 - "$FAKE_HERDR_STATE" "$HERDR_PANE_ID" "$chat" <<'PY'
import json, sys
st = json.load(open(sys.argv[1])); st.setdefault("agents", {})[sys.argv[2]] = sys.argv[3]; json.dump(st, open(sys.argv[1], "w"))
PY
hook=$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$settings")
jq -n --arg id "$chat" --arg cwd "$PWD" '{hook_event_name: "SessionStart", source: "startup", session_id: $id, cwd: $cwd}' | bash -c "$hook"
exit 0
SH
chmod +x "$FAKEBIN/fake-claude-chat"
CHAT1=11111111-1111-4111-8111-111111111111
CHAT2=22222222-2222-4222-8222-222222222222
CHAT3=33333333-3333-4333-8333-333333333333
CLAUDE_LOG="$TMP_ROOT/claude-launches"
run_chat() {
  FAKE_HERDR_EXEC=1 FM_TOPIC_CLAUDE_BIN="$FAKEBIN/fake-claude-chat" FAKE_CLAUDE_OUT="$CLAUDE_LOG" \
    FM_TOPIC_RESUME_WAIT=2 run_topic "$@"
}
meta_val() { sed -n "s/^$2=//p" "$HOME_DIR/data/topics/$1/topic.meta"; }
close_tab() {  # <tab>
  python3 - "$STATE_JSON" "$1" <<'PY'
import json, sys
st = json.load(open(sys.argv[1]))
st["tabs"] = [t for t in st["tabs"] if t["tab_id"] != sys.argv[2]]
st["panes"] = [p for p in st["panes"] if p["tab_id"] != sys.argv[2]]
json.dump(st, open(sys.argv[1], "w"))
PY
}

reset_herdr
rm -rf "$HOME_DIR/data/topics/crm"
: > "$CLAUDE_LOG"
out=$(FAKE_CLAUDE_NEW_CHAT=$CHAT1 run_chat open crm "$WORK/saas/crm" --context "$TMP_ROOT/crm-note.md")
assert_contains "$out" "new chat: no earlier crm chat is recorded" "a first open says it started a new chat"
assert_equals "$CHAT1" "$(meta_val crm agent_session)" "the chat that started in the tab is recorded"
assert_not_contains "$(cat "$CLAUDE_LOG")" "arg=--resume" "a first open does not resume anything"
pane1=$(meta_val crm pane_id)
# The SessionStart hook records a chat only from the recorded pane and folder.
printf '{"session_id":"%s","cwd":"%s"}' "$CHAT3" "$WORK/saas/crm" | HERDR_PANE_ID=w1:p77 FM_HOME="$HOME_DIR" "$TOPIC_BIN" started crm
printf '{"session_id":"%s","cwd":"%s"}' "$CHAT3" "$WORK/mbg/xelta" | HERDR_PANE_ID="$pane1" FM_HOME="$HOME_DIR" "$TOPIC_BIN" started crm
out=$(printf 'not json' | HERDR_PANE_ID="$pane1" FM_HOME="$HOME_DIR" "$TOPIC_BIN" started crm; echo "rc=$?")
assert_equals "rc=0" "$out" "the SessionStart hook is silent and never fails"
assert_equals "$CHAT1" "$(meta_val crm agent_session)" "a chat from another pane or folder is not recorded"
pass "the chat started in a topic tab is recorded from its own pane and folder"

# Refocusing reads the tab's chat from Herdr, for example after /clear.
python3 - "$STATE_JSON" "$pane1" "$CHAT2" <<'PY'
import json, sys
st = json.load(open(sys.argv[1])); st["agents"][sys.argv[2]] = sys.argv[3]; json.dump(st, open(sys.argv[1], "w"))
PY
out=$(run_chat open crm "$WORK/saas/crm")
assert_contains "$out" "focused: crm tab" "a live tab is refocused"
assert_equals "$CHAT2" "$(meta_val crm agent_session)" "refocusing records the chat Herdr reports for the tab"
pass "refocusing a tab records its current chat from Herdr"

# The tab was closed by mistake: reopening resumes the recorded chat.
close_tab "$(meta_val crm tab_id)"
: > "$CLAUDE_LOG"
run_topic log crm "Missed while closed" >/dev/null
out=$(run_chat open crm "$WORK/saas/crm")
assert_contains "$out" "opened: crm tab" "a closed tab is reopened"
assert_contains "$out" "resumed: the last crm chat $CHAT2" "reopening says it resumed the last chat"
launch=$(cat "$CLAUDE_LOG")
assert_contains "$launch" $'arg=--resume\narg='"$CHAT2" "the launcher resumes the recorded chat"
assert_contains "$launch" $'arg=--settings\narg='"$TDIR/settings.json" "the resumed chat keeps the topic hooks"
assert_contains "$launch" "reopened on this same chat" "the resumed chat gets a short catch-up prompt"
assert_equals 1 "$(grep -c '^launch$' "$CLAUDE_LOG")" "a successful resume starts no second chat"
assert_contains "$(run_topic unseen crm --hook)" "Missed while closed" "the result missed while closed reaches the resumed chat's hook"
assert_not_equals "$pane1" "$(meta_val crm pane_id)" "the record moves to the new pane"
pass "reopening a closed tab resumes its last chat with the hooks that catch it up"

# The recorded chat is gone: the launcher falls back to a new chat.
close_tab "$(meta_val crm tab_id)"
: > "$CLAUDE_LOG"
out=$(FAKE_CLAUDE_GONE=$CHAT2 FAKE_CLAUDE_NEW_CHAT=$CHAT3 run_chat open crm "$WORK/saas/crm" --context "$TMP_ROOT/crm-note.md")
assert_contains "$out" "new chat: the last crm chat $CHAT2 could not be resumed" "a failed resume is reported"
assert_equals 2 "$(grep -c '^launch$' "$CLAUDE_LOG")" "a failed resume launches one new chat"
fresh=$(awk 'n == 2; /^launch$/ { n++ }' "$CLAUDE_LOG")
assert_not_contains "$fresh" "arg=--resume" "the fallback chat is a new one"
assert_contains "$fresh" "CRM: PR https://example.invalid/pr/7 waits for review." "the fallback chat gets the starting note"
assert_equals "$CHAT3" "$(meta_val crm agent_session)" "the fallback chat is recorded"
pass "a chat that cannot be resumed falls back to a new chat with the starting note"

# A recorded chat from another folder is never resumed there.
close_tab "$(meta_val crm tab_id)"
rm -rf "$HOME_DIR/data/topics/xelta"
mkdir -p "$HOME_DIR/data/topics/xelta"
printf 'topic=xelta\ndir=%s\nagent_session=%s\n' "$WORK/saas/crm" "$CHAT1" > "$HOME_DIR/data/topics/xelta/topic.meta"
: > "$CLAUDE_LOG"
out=$(FAKE_CLAUDE_NEW_CHAT=$CHAT2 run_chat open xelta "$WORK/mbg/xelta")
assert_contains "$out" "new chat:" "a chat from another folder starts a new chat"
assert_not_contains "$(cat "$CLAUDE_LOG")" "arg=--resume" "a chat is never resumed in another folder"
pass "a chat is resumed only in the folder it ran in"

# Stale pane: the record names a pane that is gone while the tab is live.
reset_herdr
rm -rf "$HOME_DIR/data/topics/crm"
run_topic open crm "$WORK/saas/crm" >/dev/null
live_pane=$(meta_val crm pane_id)
sed -i 's/^pane_id=.*/pane_id=w1:p99/' "$TDIR/topic.meta"
out=$(run_topic log crm "Fifth result")
assert_contains "$out" "not delivered: no live agent" "log resolves the pane from the live tab instead of a stale pane id"
assert_equals "$live_pane" "$(meta_val crm pane_id)" "log rebinds the record to the live pane"
sed -i 's/^pane_id=.*/pane_id=w1:p99/' "$TDIR/topic.meta"
out=$(run_topic open crm "$WORK/saas/crm")
assert_contains "$out" "focused: crm tab" "a live tab with a stale pane id is refocused"
assert_equals "$live_pane" "$(meta_val crm pane_id)" "refocusing rebinds the record to the live pane"
pass "a stale pane id is replaced by the live tab's pane on open and log"

# Relabeled tab: recognized by its recorded pane, never by name alone.
tab=$(meta_val crm tab_id)
python3 - "$STATE_JSON" "$tab" <<'PY'
import json, sys
st = json.load(open(sys.argv[1]))
for t in st["tabs"]:
    if t["tab_id"] == sys.argv[2]: t["label"] = "crm"
json.dump(st, open(sys.argv[1], "w"))
PY
out=$(run_topic log crm "Sixth result")
assert_contains "$out" "not delivered: no live agent" "log recognizes a relabeled tab by its recorded pane"
assert_equals "topic:crm" "$(herdr_state ".tabs[] | select(.tab_id == \"$tab\") | .label")" "log restores the topic label"
python3 - "$STATE_JSON" "$tab" <<'PY'
import json, sys
st = json.load(open(sys.argv[1]))
for t in st["tabs"]:
    if t["tab_id"] == sys.argv[2]: t["label"] = "crm"
json.dump(st, open(sys.argv[1], "w"))
PY
: > "$CALLS"
out=$(run_topic open crm "$WORK/saas/crm")
assert_contains "$out" "focused: crm tab $tab (existing)" "open recognizes a relabeled tab by its recorded pane"
assert_contains "$out" "restored the tab label topic:crm" "open says it restored the label"
assert_equals "topic:crm" "$(herdr_state ".tabs[] | select(.tab_id == \"$tab\") | .label")" "open restores the topic label"
assert_no_grep "tab create" "$CALLS" "a recognized relabeled tab is not duplicated"
pass "a relabeled tab holding the recorded pane is recognized and relabeled"

# Recognized by its chat: the record's tab and pane ids are stale, but one
# relabeled tab runs the recorded chat.
python3 - "$STATE_JSON" "$tab" "$live_pane" "$CHAT1" <<'PY'
import json, sys
st = json.load(open(sys.argv[1]))
for t in st["tabs"]:
    if t["tab_id"] == sys.argv[2]: t["label"] = "crm work"
st["agents"] = {sys.argv[3]: sys.argv[4]}
json.dump(st, open(sys.argv[1], "w"))
PY
sed -i -e 's/^pane_id=.*/pane_id=w1:p99/' -e 's/^tab_id=.*/tab_id=w1:t99/' -e "s/^agent_session=.*/agent_session=$CHAT1/" "$TDIR/topic.meta"
out=$(run_topic open crm "$WORK/saas/crm")
assert_contains "$out" "focused: crm tab $tab (existing)" "open recognizes a relabeled tab by the recorded chat"
assert_equals "$live_pane" "$(meta_val crm pane_id)" "the record is rebound to the pane running the chat"
pass "a relabeled tab running the recorded chat is recognized"

# A tab merely named like the topic, holding neither the pane nor the chat,
# is not adopted.
reset_herdr
python3 - "$STATE_JSON" <<'PY'
import json, sys
st = json.load(open(sys.argv[1]))
st["tabs"].append({"tab_id": "w1:t8", "workspace_id": "w1", "label": "crm"})
st["panes"].append({"pane_id": "w1:p8", "tab_id": "w1:t8", "workspace_id": "w1", "cwd": "/x"})
st["seq"] = 8
json.dump(st, open(sys.argv[1], "w"))
PY
sed -i -e 's/^pane_id=.*/pane_id=w1:p99/' -e 's/^tab_id=.*/tab_id=w1:t99/' "$TDIR/topic.meta"
out=$(FM_TOPIC_RESUME_WAIT=0 run_topic open crm "$WORK/saas/crm")
assert_contains "$out" "opened: crm tab w1:t9" "a tab matching only by name is not adopted"
assert_equals "crm" "$(herdr_state '.tabs[] | select(.tab_id == "w1:t8") | .label')" "the unrelated tab keeps its name"
assert_contains "$out" "resuming: the last crm chat $CHAT1" "an unconfirmed resume is reported as still resuming"
pass "a tab is never recognized by its bare name alone"

# --- decisions asked in the topic tab ---------------------------------------

out=$(run_topic log crm --decision "Merge https://example.invalid/pr/9 now, or wait for the review?")
assert_contains "$out" "logged: crm" "a decision is logged"
hook=$(run_topic unseen crm --hook)
assert_contains "$hook" "ask the captain each one headed Decision needed" "the hook tells the tab to ask decisions"
assert_contains "$hook" " - Decision needed" "the decision entry is marked"
assert_contains "$hook" "Merge https://example.invalid/pr/9 now" "the decision text reaches the tab"
out=$(run_topic log crm --done fm-crm-fix --decision "Ship it?")
assert_contains "$(tail -n 3 "$TDIR/log.md")" "Decision needed" "--decision combines with --done in any order"
pass "a decision for the captain is marked so the topic tab asks it"

#!/usr/bin/env bash
# Behavior tests for the captain-wait phone reminder (bin/fm-captain-wait.sh,
# docs/configuration.md "Captain-wait phone reminder"): a new captain hold opens
# a waiting episode, the primary's turn end starts its clock, a captain reply
# ends it, and one watcher-cycle tick past the delay POSTs exactly one
# notification.
#
# Holds and hooks run as children of a fake harness (a bash symlink named
# "claude") whose pid is the home's session lock, from a git checkout that
# passes the primary-scope check, exactly as a primary's own commands and hooks
# run. Every POST goes to a local fake ntfy endpoint, never a real topic.
# shellcheck disable=SC2016 # single-quoted scripts expand inside their own shells
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { printf 'skip: jq absent\n'; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { printf 'skip: tasks-axi absent\n'; exit 0; }
command -v curl >/dev/null 2>&1 || { printf 'skip: curl absent\n'; exit 0; }
command -v python3 >/dev/null 2>&1 || { printf 'skip: python3 absent\n'; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-captain-wait)
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fakebin")
ln -s /bin/bash "$FAKEBIN/claude"
FAKE_CLAUDE="$FAKEBIN/claude"
TASKS_AXI_BIN=$(command -v tasks-axi)
SERVER_PIDS=()
cleanup() {
  local pid
  for pid in "${SERVER_PIDS[@]:-}"; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
  done
  fm_test_cleanup
}
trap cleanup EXIT
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_DATA_OVERRIDE CLAUDE_PROJECT_DIR

TOPIC='fm-test-secret-topic-7c1d'

# A primary checkout: git, AGENTS.md, and this repo's bin.
PRIMARY_ROOT="$TMP_ROOT/primary"
mkdir -p "$PRIMARY_ROOT"
git init -q "$PRIMARY_ROOT"
: > "$PRIMARY_ROOT/AGENTS.md"
ln -s "$ROOT/bin" "$PRIMARY_ROOT/bin"
WAIT="$PRIMARY_ROOT/bin/fm-captain-wait.sh"

# A local fake ntfy endpoint answering <code>, after [delay] seconds; it appends
# one JSON line per request (path, Title header, body) to <log> on arrival and
# prints its port.
start_endpoint() {  # <code> <log> [delay]
  local code=$1 log=$2 delay=${3:-0} portfile="$TMP_ROOT/port.$RANDOM$RANDOM" pid i
  python3 -I -c '
import http.server, json, sys, time
code, log, portfile, delay = int(sys.argv[1]), sys.argv[2], sys.argv[3], float(sys.argv[4])
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0)).decode()
        with open(log, "a") as f:
            f.write(json.dumps({"path": self.path, "title": self.headers.get("Title"), "body": body}) + "\n")
        time.sleep(delay)
        self.send_response(code)
        self.end_headers()
    def log_message(self, *a):
        pass
s = http.server.HTTPServer(("127.0.0.1", 0), H)
with open(portfile, "w") as f:
    f.write(str(s.server_port))
s.serve_forever()
' "$code" "$log" "$portfile" "$delay" >/dev/null 2>&1 &
  pid=$!
  SERVER_PIDS+=("$pid")
  for i in $(seq 1 50); do
    [ -s "$portfile" ] && break
    sleep 0.1
  done
  [ -s "$portfile" ] || fail "the fake ntfy endpoint did not start"
  cat "$portfile"
}

OK_LOG="$TMP_ROOT/ok-requests.jsonl"
: > "$OK_LOG"
OK_PORT=$(start_endpoint 200 "$OK_LOG")
BAD_LOG="$TMP_ROOT/bad-requests.jsonl"
: > "$BAD_LOG"
BAD_PORT=$(start_endpoint 500 "$BAD_LOG")
# Slower than the episode lock's wait limit, so a POST in flight overlaps a clear.
SLOW_LOG="$TMP_ROOT/slow-requests.jsonl"
: > "$SLOW_LOG"
SLOW_PORT=$(start_endpoint 200 "$SLOW_LOG" 6)
# A port nothing listens on: bind, read, release.
DEAD_PORT=$(python3 -I -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')

make_home() {  # <name> [<config text> | none]
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  fm_test_tasks_toml "$home/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  if [ "${2:-none}" != none ]; then
    printf '%s\n' "$2" > "$home/config/captain-ntfy"
  fi
  printf '%s\n' "$home"
}

config_for() {  # <port> [delay]
  printf 'url=http://127.0.0.1:%s/\ntopic=%s\ndelay=%s' "$1" "$TOPIC" "${2:-60}"
}

# Run a shell script as the lock-owning primary Claude session of <home>.
as_session() {  # <home> <script>
  FM_HOME="$1" FM_DATA_OVERRIDE="$1/data" FM_CONFIG_OVERRIDE="$1/config" \
    PRIMARY_ROOT="$PRIMARY_ROOT" REAL_TASKS_AXI="$TASKS_AXI_BIN" CLAUDECODE=1 \
    "$FAKE_CLAUDE" -c 'printf "%s\n" "$$" > "$FM_HOME/state/.lock"; '"$2"
}

# Captain hold commands, from the primary session.
hold() {  # <home> <id> [extra hold args...]
  local home=$1 id=$2 args=''
  shift 2
  [ "$#" -eq 0 ] || args=$(printf '%q ' "$@")
  HOLD_ARGS=$args ID="$id" as_session "$home" '
    eval "set -- $HOLD_ARGS"
    "$PRIMARY_ROOT/bin/fm-captain-hold.sh" hold "$ID" --title "Question $ID" --reason "pick one" "$@" >/dev/null' \
    || fail "could not hold $id"
}

# One tracked Claude hook registration, fed <payload>, from the session.
claude_cmd() { jq -r --arg e "$1" '.hooks[$e][].hooks[] | select(.command | contains("fm-captain-wait.sh")) | .command' "$ROOT/.claude/settings.json"; }
hook() {  # <home> <Stop|UserPromptSubmit> [prompt]
  local payload
  if [ "$2" = Stop ]; then
    payload=$(jq -cn '{hook_event_name: "Stop", last_assistant_message: "Which one?"}')
  else
    payload=$(jq -cn --arg p "${3:-}" '{hook_event_name: "UserPromptSubmit", prompt: $p}')
  fi
  CMD=$(claude_cmd "$2") PAYLOAD=$payload as_session "$1" '
    printf "%s" "$PAYLOAD" | env CLAUDE_PROJECT_DIR="$PRIMARY_ROOT" FM_ROOT_OVERRIDE="$PRIMARY_ROOT" \
      bash -c "cd \"$PRIMARY_ROOT\" && $CMD"' || fail "the $2 hook failed"
}

# One watcher-cycle tick, as bin/fm-watch.sh runs it.
tick() {  # <home>
  FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" FM_CONFIG_OVERRIDE="$1/config" \
    FM_DATA_OVERRIDE="$1/data" REAL_TASKS_AXI="$TASKS_AXI_BIN" "$WAIT" tick
}

field() { sed -n "s/^$2=//p" "$1/state/.captain-wait" 2>/dev/null; }
set_field() {  # <home> <key> <value>
  sed -i.bak "s/^$2=.*/$2=$3/" "$1/state/.captain-wait" && rm -f "$1/state/.captain-wait.bak"
}
requests() { grep -c . "$1" 2>/dev/null || true; }
needed() {
  ( . "$ROOT/bin/fm-supervision-lib.sh"; fm_supervision_needed "$1/state" ) && echo yes || echo no
}

test_config_absent_is_off_and_silent() {
  local home out
  home=$(make_home off)
  hold "$home" q-off
  hook "$home" Stop
  out=$(tick "$home" 2>&1) || fail "tick failed with no config"
  assert_equals "" "$out" "tick printed with no config"
  assert_absent "$home/state/.captain-wait" "a home with no config/captain-ntfy opened an episode"
  assert_absent "$home/state/.captain-wait.log" "a home with no config/captain-ntfy wrote a log"
  assert_equals no "$(needed "$home")" "a home with no config must not need supervision"
  pass "captain-wait: with no config/captain-ntfy nothing is recorded, sent, or logged"
}

test_hold_opens_episode_and_stop_starts_clock() {
  local home
  home=$(make_home start "$(config_for "$OK_PORT")")
  hold "$home" q-start
  assert_present "$home/state/.captain-wait" "a new captain hold must open an episode"
  assert_equals q-start "$(field "$home" holds)" "the episode must name its hold"
  assert_equals "" "$(field "$home" start)" "the clock must not start before the turn ends"
  assert_equals yes "$(needed "$home")" "an unsent episode must keep a watcher needed"
  hook "$home" Stop
  [ -n "$(field "$home" start)" ] || fail "the Stop hook must start the clock"
  assert_equals 600 "$(stat -c %a "$home/state/.captain-wait" 2>/dev/null || stat -f %Lp "$home/state/.captain-wait")" \
    "the episode record must be owner-only"
  pass "captain-wait: a new hold opens an episode and the turn end starts its clock"
}

test_sends_exactly_once_at_threshold() {
  local home before start req
  home=$(make_home once "$(config_for "$OK_PORT" 60)")
  before=$(requests "$OK_LOG")
  hold "$home" q-once
  hook "$home" Stop
  tick "$home"
  assert_equals "$before" "$(requests "$OK_LOG")" "no reminder may be sent before the delay"
  start=$(field "$home" start)
  set_field "$home" start $((start - 61))
  tick "$home"
  assert_equals $((before + 1)) "$(requests "$OK_LOG")" "one reminder must be sent past the delay"
  req=$(tail -n 1 "$OK_LOG")
  assert_equals "/$TOPIC" "$(jq -r .path <<<"$req")" "the reminder must POST to the configured topic"
  assert_equals "Firstmate is waiting for you" "$(jq -r .title <<<"$req")" "the reminder title"
  assert_equals "1 question is waiting for your answer." "$(jq -r .body <<<"$req")" "the reminder body"
  tick "$home"
  tick "$home"
  assert_equals $((before + 1)) "$(requests "$OK_LOG")" "the reminder must not repeat"
  assert_equals 1 "$(field "$home" sent)" "the episode must be marked sent"
  assert_equals no "$(needed "$home")" "a sent episode must not keep a watcher needed"
  pass "captain-wait: past the delay one tick sends exactly one reminder, and later ticks send nothing"
}

test_body_counts_open_questions() {
  local home start
  home=$(make_home count "$(config_for "$OK_PORT" 0)")
  hold "$home" q-a
  hold "$home" q-b
  assert_equals "q-a q-b" "$(field "$home" holds)" "a second hold must join the open episode"
  hook "$home" Stop
  start=$(field "$home" start)
  set_field "$home" start $((start - 1))
  tick "$home"
  assert_equals "2 questions are waiting for your answer." "$(tail -n 1 "$OK_LOG" | jq -r .body)" "the body must count open questions"
  pass "captain-wait: holds opened while waiting join the episode and the body counts them"
}

test_captain_prompt_clears_and_machine_prompt_does_not() {
  local home
  home=$(make_home reply "$(config_for "$OK_PORT")")
  hold "$home" q-reply
  hook "$home" Stop
  hook "$home" UserPromptSubmit '<task-notification>watcher woke</task-notification>'
  assert_present "$home/state/.captain-wait" "a harness-started turn is not a captain reply"
  hook "$home" UserPromptSubmit 'go with the first one'
  assert_absent "$home/state/.captain-wait" "a captain prompt must end the episode"
  assert_equals no "$(needed "$home")" "an ended episode must not keep a watcher needed"
  hold "$home" q-next
  assert_equals q-next "$(field "$home" holds)" "a new hold after the reply must start a new episode"
  pass "captain-wait: a captain prompt ends the episode, a machine-started turn does not, and a later hold starts anew"
}

test_inbox_note_clears() {
  local home
  home=$(make_home note "$(config_for "$OK_PORT")")
  hold "$home" q-note
  hook "$home" Stop
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-inbox.sh" note "[topic:demo] the first one" >/dev/null || fail "could not queue a note"
  assert_absent "$home/state/.captain-wait" "an inbox note must end the episode"
  pass "captain-wait: an inbox or topic-tab note ends the episode"
}

test_repeat_or_deferred_hold_opens_nothing() {
  local home
  home=$(make_home parked "$(config_for "$OK_PORT")")
  hold "$home" q-parked --until 2099-01-01
  assert_absent "$home/state/.captain-wait" "a deferred hold must not open an episode"
  hold "$home" q-again
  hook "$home" UserPromptSubmit 'later'
  hold "$home" q-again
  assert_absent "$home/state/.captain-wait" "repeating an active hold must not reopen an episode"
  pass "captain-wait: a deferred hold or a repeated active hold opens no episode"
}

test_answered_question_sends_nothing() {
  local home before start
  home=$(make_home answered "$(config_for "$OK_PORT" 0)")
  before=$(requests "$OK_LOG")
  hold "$home" q-done
  hook "$home" Stop
  printf 'the first one\n' > "$home/decision.txt"
  as_session "$home" '"$PRIMARY_ROOT/bin/fm-captain-hold.sh" answer q-done --decision-file "$FM_HOME/decision.txt" --release >/dev/null' \
    || fail "could not answer the hold"
  start=$(field "$home" start)
  set_field "$home" start $((start - 1))
  tick "$home"
  assert_equals "$before" "$(requests "$OK_LOG")" "an answered question must not be reminded"
  assert_absent "$home/state/.captain-wait" "an episode with no open question must be dropped"
  pass "captain-wait: a question answered before the delay sends nothing"
}

test_post_failure_is_harmless_and_bounded() {
  local home port start out
  for port in "$BAD_PORT" "$DEAD_PORT"; do
    home=$(make_home "fail-$port" "$(config_for "$port" 0)")
    hold "$home" q-fail
    hook "$home" Stop
    start=$(field "$home" start)
    set_field "$home" start $((start - 1))
    out=$(tick "$home" 2>&1) || fail "a failed POST must not fail the tick"
    assert_equals "" "$out" "a failed POST must print nothing"
    assert_grep "reminder POST failed" "$home/state/.captain-wait.log" "a failed POST must be logged"
    assert_equals 0 "$(field "$home" sent)" "one failure must leave a retry"
    set_field "$home" next 0
    tick "$home"
    set_field "$home" next 0
    tick "$home"
    assert_equals 1 "$(field "$home" sent)" "the reminder must give up after three failures"
    set_field "$home" next 0
    tick "$home"
    assert_equals 3 "$(field "$home" attempts)" "no attempt may follow giving up"
    assert_grep "given up" "$home/state/.captain-wait.log" "giving up must be logged"
    assert_no_grep "$TOPIC" "$home/state/.captain-wait.log" "the log must never hold the topic"
    assert_no_grep "$TOPIC" "$home/state/.captain-wait" "the episode must never hold the topic"
  done
  assert_equals 3 "$(requests "$BAD_LOG")" "a failing endpoint must see exactly three attempts"
  pass "captain-wait: a failing or unreachable endpoint is logged without the topic, retried twice, then given up"
}

# A clear, and a new hold, that land while a slow reminder POST is in flight.
test_clear_during_slow_post_stays_cleared() {
  local home start pid i
  home=$(make_home slow "$(config_for "$SLOW_PORT" 0)")
  hold "$home" q-slow
  hook "$home" Stop
  start=$(field "$home" start)
  set_field "$home" start $((start - 1))
  tick "$home" &
  pid=$!
  for i in $(seq 1 50); do
    [ "$(requests "$SLOW_LOG")" -ge 1 ] && break
    sleep 0.1
  done
  assert_equals 1 "$(requests "$SLOW_LOG")" "the reminder POST must be in flight"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" "$WAIT" clear
  assert_absent "$home/state/.captain-wait" "a clear during a POST must end the episode"
  wait "$pid" || fail "the slow tick failed"
  assert_absent "$home/state/.captain-wait" "a tick finishing its POST must not recreate a cleared episode"
  tick "$home"
  assert_equals 1 "$(requests "$SLOW_LOG")" "a cleared episode must record no further send"

  # A new episode opened during the POST is a different episode: the finishing
  # tick must not mark it sent or spend its attempts.
  hold "$home" q-slow-a
  hook "$home" Stop
  start=$(field "$home" start)
  set_field "$home" start $((start - 1))
  tick "$home" &
  pid=$!
  for i in $(seq 1 50); do
    [ "$(requests "$SLOW_LOG")" -ge 2 ] && break
    sleep 0.1
  done
  assert_equals 2 "$(requests "$SLOW_LOG")" "the second reminder POST must be in flight"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" "$WAIT" clear
  hold "$home" q-slow-b
  wait "$pid" || fail "the second slow tick failed"
  assert_equals q-slow-b "$(field "$home" holds)" "the new episode must survive the finishing tick"
  assert_equals 0 "$(field "$home" sent)" "the finishing tick must not mark a new episode sent"
  assert_equals 0 "$(field "$home" attempts)" "the finishing tick must not spend a new episode's attempts"
  pass "captain-wait: a clear during a slow reminder POST stays cleared, and a new episode keeps its own reminder"
}

test_env_file_settings() {
  local home before start
  home=$(make_home envfile "env-file=ntfy.env
delay=0")
  printf 'export NTFY_URL="http://127.0.0.1:%s"\nNTFY_TOPIC=%s\n' "$OK_PORT" "$TOPIC" > "$home/ntfy.env"
  before=$(requests "$OK_LOG")
  hold "$home" q-env
  hook "$home" Stop
  start=$(field "$home" start)
  set_field "$home" start $((start - 1))
  tick "$home"
  assert_equals $((before + 1)) "$(requests "$OK_LOG")" "the env-file settings must send the reminder"
  assert_equals "/$TOPIC" "$(tail -n 1 "$OK_LOG" | jq -r .path)" "the env-file topic must be used"
  pass "captain-wait: NTFY_URL and NTFY_TOPIC from a named env file configure the reminder"
}

test_secondmate_home_is_off() {
  local home
  home=$(make_home mate "$(config_for "$OK_PORT")")
  printf 'mate\n' > "$home/.fm-secondmate-home"
  hold "$home" q-mate 2>/dev/null
  assert_absent "$home/state/.captain-wait" "a secondmate home must never open an episode"
  pass "captain-wait: a secondmate home never opens an episode"
}

test_watcher_runs_the_tick() {
  assert_grep 'fm-captain-wait.sh" tick' "$ROOT/bin/fm-watch.sh" "the watcher cycle must run the reminder tick"
  pass "captain-wait: the watcher cycle runs the reminder tick"
}

test_config_absent_is_off_and_silent
test_hold_opens_episode_and_stop_starts_clock
test_sends_exactly_once_at_threshold
test_body_counts_open_questions
test_captain_prompt_clears_and_machine_prompt_does_not
test_inbox_note_clears
test_repeat_or_deferred_hold_opens_nothing
test_answered_question_sends_nothing
test_post_failure_is_harmless_and_bounded
test_clear_during_slow_post_stays_cleared
test_env_file_settings
test_secondmate_home_is_off
test_watcher_runs_the_tick

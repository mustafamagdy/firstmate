#!/usr/bin/env bash
# Credentialed Codex guard: a yielded checkpoint is not a safe turn-end proof.
# Named Herdr lab, real Stop hooks, late inbox replies and mate outcomes,
# generation/receipt ACKs, repeated unsafe finals, ordinary user input and quit.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_CODEX_LIVE_E2E codex herdr jq

HERDR_LAB_HELPER=${FM_HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
LAB_HOME_HELPER=${FM_LAB_HOME_HELPER:-$ROOT/bin/fm-lab-home.sh}
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name supervision-wake-gap)
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-codex-continuity.XXXXXX")
ARTIFACTS=${FM_CODEX_LIVE_ARTIFACT_DIR:-$LAB/evidence}
mkdir -p "$ARTIFACTS"
CODEX_VERSION=$(codex --version)
printf 'harness: %s\n' "$CODEX_VERSION"
HOME_DIR=
cleanup() {
  local rc=$?
  [ -z "$HOME_DIR" ] || "$LAB_HOME_HELPER" teardown "$HOME_DIR" || rc=1
  "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || rc=1
  rm -rf "$LAB"
  exit "$rc"
}
trap cleanup EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"
printf '%s\n' "$HERDR_LAB_SESSION" > "$ARTIFACTS/session"

wait_file() {
  local path=$1 count=0
  while [ "$count" -lt 480 ]; do
    [ ! -s "$path" ] || return 0
    sleep 0.5
    count=$((count + 1))
  done
  fail "$CODEX_VERSION: missing $path; evidence: $ARTIFACTS"
}

stage_home() {
  HOME_DIR="$LAB/$1"
  "$LAB_HOME_HELPER" create "$HOME_DIR" >/dev/null
  cp -R "$ROOT/bin" "$ROOT/docs" "$HOME_DIR/"
  mkdir -p "$HOME_DIR/.codex"
  # A primary fixture, not a project instruction edit or another worktree.
  : > "$HOME_DIR/AGENTS.md"
  git init -q "$HOME_DIR"
  jq '{hooks: {Stop: .hooks.Stop}}' "$ROOT/.codex/hooks.json" > "$HOME_DIR/.codex/hooks.json"
  printf 'project=probe\nharness=codex\nbackend=herdr\nwindow=lab\n' > "$HOME_DIR/state/probe.meta"
}

run_case() {
  local name=$1 mode=$2 failure=${3:-false} transcript pane count pid initial_pid
  stage_home "$name"
  if [ "$mode" = control ]; then
    jq '.hooks.Stop[0].hooks[0].command |= sub(" --codex"; "")' \
      "$HOME_DIR/.codex/hooks.json" > "$LAB/hooks"
    mv "$LAB/hooks" "$HOME_DIR/.codex/hooks.json"
  fi
  # Observe the actual tracked command and preserve native status and output.
  jq -r '.hooks.Stop[0].hooks[0].command' "$HOME_DIR/.codex/hooks.json" > "$HOME_DIR/stop-command"
  cat > "$HOME_DIR/stop-probe.sh" <<'PROBE'
#!/usr/bin/env bash
payload=$(cat)
printf '%s\n' "$payload" >> "$FM_HOME/stop-payloads.jsonl"
printf '%s' "$payload" | bash -c "$(cat "$FM_HOME/stop-command")"
rc=$?
printf '%s\n' "$rc" >> "$FM_HOME/stop-codes"
exit "$rc"
PROBE
  jq --arg command "bash $HOME_DIR/stop-probe.sh # fm-turnend-guard.sh" \
    '.hooks.Stop[0].hooks[0].command=$command' "$HOME_DIR/.codex/hooks.json" > "$LAB/hooks"
  mv "$LAB/hooks" "$HOME_DIR/.codex/hooks.json"
  transcript="$ARTIFACTS/$name.jsonl"
  printf '#!/usr/bin/env bash\nexport FM_HOME=%q FM_POLL=1 FM_SIGNAL_GRACE=0 FM_HEARTBEAT=999999 FM_CHECK_INTERVAL=999999\nexec >%q 2>&1\n' "$HOME_DIR" "$transcript" > "$HOME_DIR/primary.sh"
  cat >> "$HOME_DIR/primary.sh" <<'PRIMARY'
cd "$FM_HOME"
printf '%s\n' "$$" > "$FM_HOME/state/.lock"
exec codex exec --ephemeral --enable hooks --dangerously-bypass-hook-trust \
  --dangerously-bypass-approvals-and-sandbox -c 'model_reasoning_effort="low"' --json \
  'This is an isolated primary-supervision probe. Do not run startup. First run exactly bin/fm-watch-checkpoint.sh --seconds 15 using exec_command yield_time_ms=1000. When that tool yields a running session id, attempt to finish immediately with PROBE_IDLE_1 without polling. If a Stop hook refuses this first final, deliberately attempt a second final PROBE_IDLE_2 without running a new tool. After the second refusal, follow the existing foreground protocol: wait on that exact original tool session until it completes, handle wakes, then start one next foreground checkpoint at a time. A late topic note arrives only after the original watcher exits. Run bin/fm-wake-drain.sh first and follow its exact WAKE_ACK_REQUIRED generation and receipt instructions after handling every wake. For notes use bin/fm-inbox.sh drain, reply once per note with bin/fm-inbox.sh reply ID LATE_TOPIC_HANDLED, then acknowledge with bin/fm-inbox.sh drain --ack ID. After handling the first note, attempt one more final PROBE_IDLE_3. If refused, continue foreground checkpoints while supervision is needed. A second late note and mate outcome will arrive. When probe.status says done, copy its exact text into mate-relayed.txt, remove only state/probe.meta, handle both notes and ACK all remaining wakes. End only after all handoffs were handled. Do not touch files outside this isolated FM_HOME.'
PRIMARY
  "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" workspace create --cwd "$HOME_DIR" --label "$name" > "$LAB/workspace"
  pane=$(jq -r '.result.root_pane.pane_id' "$LAB/workspace")
  "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane run "$pane" bash "$HOME_DIR/primary.sh" >/dev/null
  wait_file "$HOME_DIR/state/.watch.lock/pid"
  initial_pid=$(cat "$HOME_DIR/state/.watch.lock/pid")
  wait_file "$HOME_DIR/stop-codes"
  if [ "$mode" = control ]; then
    [ "$(head -1 "$HOME_DIR/stop-codes")" = 0 ] || fail "$CODEX_VERSION: control did not allow live-checkpoint stop"
  else
    count=0
    while [ "$(wc -l < "$HOME_DIR/stop-codes")" -lt 2 ] && [ "$count" -lt 240 ]; do
      sleep 0.5
      count=$((count + 1))
    done
    [ "$count" -lt 240 ] || fail "$CODEX_VERSION: repeated false-safe final did not reach Stop"
    [ "$(head -2 "$HOME_DIR/stop-codes" | sort -u)" = 2 ] || fail "$CODEX_VERSION: initial or repeated unsafe final was allowed"
    jq -s -e '.[1].stop_hook_active == true' "$HOME_DIR/stop-payloads.jsonl" >/dev/null || fail "native repeated Stop was not active"
  fi
  if [ "$failure" = true ]; then
    # Only this exact lab watcher's PID is signalled.
    pid=$(cat "$HOME_DIR/state/.watch.lock/pid")
    [ "$pid" = "$initial_pid" ] || fail "failure fixture lost its initial watcher"
    kill -TERM "$pid"
  fi
  count=0
  while kill -0 "$initial_pid" 2>/dev/null && [ "$count" -lt 120 ]; do
    sleep 0.5
    count=$((count + 1))
  done
  ! kill -0 "$initial_pid" 2>/dev/null || fail "$CODEX_VERSION: initial checkpoint did not expire"
  FM_HOME="$HOME_DIR" "$HOME_DIR/bin/fm-inbox.sh" note --request-id late-topic \
    '[topic:probe] late request after initial watcher stopped' > "$ARTIFACTS/$name-note.txt"
  if [ "$mode" != control ]; then
    count=0
    while [ "$count" -lt 480 ]; do
      FM_HOME="$HOME_DIR" "$HOME_DIR/bin/fm-inbox.sh" receipts --all-pending --all-replies > "$ARTIFACTS/$name-first-receipts.json"
      if jq -e '.pending == [] and (.replies | length) == 1' "$ARTIFACTS/$name-first-receipts.json" >/dev/null \
        && [ "$(wc -l < "$HOME_DIR/stop-codes")" -ge 3 ]; then break; fi
      sleep 0.5
      count=$((count + 1))
    done
    [ "$count" -lt 480 ] || fail "$CODEX_VERSION: first late request or third Stop was not handled"
    [ "$(sed -n '3p' "$HOME_DIR/stop-codes")" = 2 ] || fail "handling turn ended blind before the next request"
    FM_HOME="$HOME_DIR" "$HOME_DIR/bin/fm-inbox.sh" note --request-id second-topic \
      '[topic:probe] second request after another false-safe final' > "$ARTIFACTS/$name-second-note.txt"
  fi
  printf 'done [at=%s]: LATE_MATE_OUTCOME\n' "$(date +%s)" > "$HOME_DIR/state/probe.status"
  if [ "$mode" = control ]; then
    sleep 5
    FM_HOME="$HOME_DIR" "$HOME_DIR/bin/fm-inbox.sh" receipts --all-pending > "$ARTIFACTS/$name-receipts.json"
    jq -e '.pending | length == 1 and .[0].reply == null and .[0].acknowledged == false' \
      "$ARTIFACTS/$name-receipts.json" >/dev/null || fail "control did not reproduce stranded topic"
    [ ! -f "$HOME_DIR/mate-relayed.txt" ] || fail "control unexpectedly relayed the outcome"
    pass "$CODEX_VERSION: live-PID control ended blind and stranded both late handoffs"
  else
    wait_file "$HOME_DIR/mate-relayed.txt"
    count=0
    while [ "$count" -lt 480 ]; do
      FM_HOME="$HOME_DIR" "$HOME_DIR/bin/fm-inbox.sh" receipts --all-pending --all-handled --all-replies > "$ARTIFACTS/$name-receipts.json"
      if jq -e '.pending == [] and (.handled | length) == 2 and (.replies | length) == 2' "$ARTIFACTS/$name-receipts.json" >/dev/null \
        && [ ! -s "$HOME_DIR/state/.wake-queue" ]; then break; fi
      sleep 0.5
      count=$((count + 1))
    done
    [ "$count" -lt 480 ] || fail "$CODEX_VERSION: missing exact replies or generation/receipt ACKs"
    grep -Fq LATE_MATE_OUTCOME "$HOME_DIR/mate-relayed.txt" || fail "mate outcome was not relayed"
    grep -Fq LATE_TOPIC_HANDLED "$ARTIFACTS/$name-receipts.json" || fail "topic reply body missing"
    sleep 3
    FM_HOME="$HOME_DIR" "$HOME_DIR/bin/fm-inbox.sh" receipts --all-replies > "$ARTIFACTS/$name-final-receipts.json"
    jq -e '(.replies | length) == 2' "$ARTIFACTS/$name-final-receipts.json" >/dev/null || fail "duplicate processing"
    pass "$CODEX_VERSION: repeated unsafe finals refused; two late topics and mate outcome handled once with receipt ACKs ($name)"
  fi
  cp "$HOME_DIR/stop-codes" "$ARTIFACTS/$name-stop-codes"
  cp "$HOME_DIR/stop-payloads.jsonl" "$ARTIFACTS/$name-stop-payloads.jsonl"
}

run_interactive_case() {
  local pane count watcher_pid
  stage_home interactive
  printf '#!/usr/bin/env bash\ncd %q\nexport FM_HOME=%q FM_POLL=1 FM_SIGNAL_GRACE=0 FM_HEARTBEAT=999999 FM_CHECK_INTERVAL=999999\n' "$HOME_DIR" "$HOME_DIR" > "$HOME_DIR/interactive.sh"
  cat >> "$HOME_DIR/interactive.sh" <<'PRIMARY'
codex --no-daemon --no-alt-screen --enable hooks --dangerously-bypass-hook-trust \
  --dangerously-bypass-approvals-and-sandbox -c 'model_reasoning_effort="low"' \
  'This is an isolated foreground-supervision probe. Run bin/fm-watch-checkpoint.sh --seconds 15 with exec_command yield_time_ms=1000. Wait on its exact yielded session until completion and continue one foreground checkpoint at a time while state/probe.meta exists. Do not run startup. For a new user message answer it normally, then resume this existing supervision protocol. Never treat a yielded session id as a post-turn wake.' < /dev/tty &
pid=$!
printf '%s\n' "$pid" > "$FM_HOME/state/.lock"
wait "$pid"
printf '%s\n' CODEX_EXPLICIT_EXIT
PRIMARY
  "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" workspace create --cwd "$HOME_DIR" --label interactive > "$LAB/workspace"
  pane=$(jq -r '.result.root_pane.pane_id' "$LAB/workspace")
  "$HERDR_LAB_HELPER" viewer start "$HERDR_LAB_SESSION" >/dev/null
  "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane run "$pane" bash "$HOME_DIR/interactive.sh" >/dev/null
  count=0
  while [ ! -s "$HOME_DIR/state/.watch.lock/pid" ] && [ "$count" -lt 360 ]; do
    "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane read "$pane" --lines 100 > "$ARTIFACTS/interactive-start.txt"
    if grep -Fq 'Trust this folder?' "$ARTIFACTS/interactive-start.txt"; then
      # Real directory consent for this vetted fixture only. Hook automation
      # is invocation-scoped; never forge a persisted hook trust decision.
      "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane send-keys "$pane" Enter
    fi
    sleep 0.5
    count=$((count + 1))
  done
  [ "$count" -lt 360 ] || fail "$CODEX_VERSION: interactive foreground watcher did not start"
  "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane send-text "$pane" 'Reply USER_INTERRUPT only, then resume supervision.'
  sleep 1
  "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane send-keys "$pane" Enter
  count=0
  while [ "$count" -lt 120 ]; do
    "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane read "$pane" --lines 150 > "$ARTIFACTS/interactive-response.txt"
    grep -Fq '• USER_INTERRUPT' "$ARTIFACTS/interactive-response.txt" && break
    sleep 0.5
    count=$((count + 1))
  done
  [ "$count" -lt 120 ] || fail "$CODEX_VERSION: ordinary Enter did not submit user input at a foreground tool boundary"
  "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane send-text "$pane" /quit
  sleep 1
  "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane send-keys "$pane" Enter
  count=0
  while [ "$count" -lt 80 ]; do
    "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane read "$pane" --lines 100 > "$ARTIFACTS/interactive-quit.txt"
    grep -Fq CODEX_EXPLICIT_EXIT "$ARTIFACTS/interactive-quit.txt" && break
    sleep 0.5
    count=$((count + 1))
  done
  [ "$count" -lt 80 ] || fail "$CODEX_VERSION: explicit /quit did not exit"
  count=0
  while [ "$count" -lt 40 ]; do
    watcher_pid=$(cat "$HOME_DIR/state/.watch.lock/pid" 2>/dev/null || true)
    if [ -z "$watcher_pid" ] || ! kill -0 "$watcher_pid" 2>/dev/null; then break; fi
    sleep 0.5
    count=$((count + 1))
  done
  [ "$count" -lt 40 ] || fail "$CODEX_VERSION: watcher survived explicit quit"
  pass "$CODEX_VERSION: ordinary Enter submits user input during foreground supervision; explicit /quit exits with watcher cleanup"
}

run_case control control
run_case fixed guarded
run_case failed-watcher guarded true
run_interactive_case
printf '# all fm-codex-continuity live checks passed (%s)\n' "$CODEX_VERSION"

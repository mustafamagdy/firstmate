#!/usr/bin/env bash
# fm-captain-wait.sh - the captain-wait phone reminder: when the captain owes
# firstmate an answer and has not replied within a configured delay (default 5
# minutes), POST one push notification to the captain's ntfy topic. The single
# owner of the waiting-episode record, its lifecycle, and the POST.
#
# SIGNAL. A waiting episode is opened only by a durable captain hold
# (bin/fm-captain-hold.sh `hold`) that starts a new hold lifecycle without
# --until; repeating an active hold or deferring one opens nothing, so a
# long-parked decision never pings again. Chat text is never parsed to guess
# whether a question was asked. The episode's clock starts when the primary
# session's turn ends (the Claude Stop hook) after the hold was opened, so the
# delay counts the captain's quiet time, not firstmate's own turn.
#
# END. The episode closes, unsent, when the captain submits any prompt to the
# primary session (the Claude UserPromptSubmit hook; operational input, an
# operational-input doorbell, and a harness-started <task-notification> turn
# are fleet machinery and do not count), when the captain queues an inbox note
# (bin/fm-inbox.sh `note`, which is also how topic tabs and the voice relay hand
# an answer back), or when every hold it was opened for is no longer open.
#
# SEND. bin/fm-watch.sh runs `tick` every poll cycle while config/captain-ntfy
# exists, so the check runs while the session is idle. An episode that is open
# and not yet sent counts as supervision need (bin/fm-supervision-lib.sh), which
# keeps a watcher armed for it. Once start + delay has passed, tick POSTs one
# notification with curl, titled "Firstmate is waiting for you" with a one-line
# body counting the open questions. A failed POST is retried at most twice, a
# minute apart, then given up; success or giving up marks the episode sent, so
# it never repeats. A new episode needs a captain reply first: a hold opened
# while an episode is open joins it.
#
# CONFIG. config/captain-ntfy, key=value lines, # comments allowed:
#   url=https://ntfy.sh        ntfy server base URL
#   topic=<topic>              the private topic (a secret)
#   env-file=<path>            alternative source of NTFY_URL and NTFY_TOPIC
#                              (KEY=value lines, optional export and quotes;
#                              read, never sourced); url/topic lines win
#   delay=300                  seconds before the reminder (default 300)
# No file means the feature is off and silent; a secondmate home is always off.
# The topic is never printed, logged, or passed on a command line: the URL
# reaches curl through its config on stdin.
#
# FILES. state/.captain-wait (owner-only) holds the open episode;
# state/.captain-wait.log is the home-local log of failures, never the topic.
#
# LOCKING. Every episode write and delete holds state/.captain-wait.lock. Each
# episode carries a random id; tick claims an attempt under the lock, counts
# holds and POSTs with the lock released, then records the result only if the
# same episode is still there, so a clear or a new episode is never undone.
#
# Usage:
#   fm-captain-wait.sh open <task-id>     record a new captain hold
#   fm-captain-wait.sh hook claude        Claude Stop or UserPromptSubmit payload on stdin
#   fm-captain-wait.sh clear              the captain answered through another channel
#   fm-captain-wait.sh tick               one watcher-cycle check
#   fm-captain-wait.sh needed             exit 0 when an unsent episode is open
# Every command except `needed` always exits 0 and prints nothing. `open` and
# `hook` act only in the lock-owning primary Claude Code session.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

EPISODE="$STATE/.captain-wait"
LOCK="$STATE/.captain-wait.lock"
LOG="$STATE/.captain-wait.log"
SETTINGS="$CONFIG/captain-ntfy"
TITLE='Firstmate is waiting for you'
DEFAULT_DELAY=300
MAX_ATTEMPTS=3
RETRY_SECS=60
# An episode whose turn never ended (no Stop hook on this harness) is dropped
# after this long, so it cannot keep a watcher armed forever.
UNSTARTED_MAX_SECS=43200

usage() {
  sed -n '/^# Usage:/,/^#   fm-captain-wait.sh needed/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"

# Off in a secondmate home (it reaches the captain through main) and without
# the config file.
enabled() {
  ! fm_root_is_secondmate_home "$FM_HOME" && [ -f "$SETTINGS" ] && [ -d "$STATE" ]
}

log() {  # <message>
  local lines
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$LOG" 2>/dev/null || return 0
  lines=$(wc -l < "$LOG" 2>/dev/null | tr -d ' ')
  case "$lines" in ''|*[!0-9]*) return 0 ;; esac
  if [ "$lines" -gt 300 ]; then
    tail -n 200 "$LOG" > "$LOG.tmp" 2>/dev/null && mv -f "$LOG.tmp" "$LOG" 2>/dev/null
    rm -f "$LOG.tmp" 2>/dev/null
  fi
  return 0
}

WAKE_LIB_LOADED=0
lock() {
  if [ "$WAKE_LIB_LOADED" -eq 0 ]; then
    # shellcheck source=bin/fm-wake-lib.sh
    . "$SCRIPT_DIR/fm-wake-lib.sh"
    WAKE_LIB_LOADED=1
  fi
  fm_lock_acquire_wait_max "$LOCK" 5
}

# The lock-owning primary session, on Claude Code: the only primary whose turn
# end starts the clock (the Stop hook below), so no other primary opens an
# episode that nothing would ever start.
primary_claude_session() {
  [ "${CLAUDECODE:-}" = 1 ] || return 1
  # shellcheck source=bin/fm-session-lock-lib.sh
  . "$SCRIPT_DIR/fm-session-lock-lib.sh"
  fm_primary_scope_matches "$FM_ROOT" "$STATE" && fm_session_lock_owned_by_self "$STATE"
}

unlock() { fm_lock_release "$LOCK" >/dev/null 2>&1 || true; }

# A random episode id: unique even for episodes opened in the same second.
new_episode_id() {
  local id
  id=$(od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
  case "$id" in ''|*[!0-9a-f]*) id="$(date +%s).$$.$RANDOM$RANDOM" ;; esac
  printf '%s\n' "$id"
}

# Episode fields: id, holds, opened, start, attempts, next, sent.
E_ID='' E_HOLDS='' E_OPENED='' E_START='' E_ATTEMPTS=0 E_NEXT=0 E_SENT=0
read_episode() {
  local key value
  E_ID='' E_HOLDS='' E_OPENED='' E_START='' E_ATTEMPTS=0 E_NEXT=0 E_SENT=0
  [ -f "$EPISODE" ] || return 1
  while IFS='=' read -r key value || [ -n "$key" ]; do
    case "$key" in
      id) E_ID=$value ;;
      holds) E_HOLDS=$value ;;
      opened) E_OPENED=$value ;;
      start) E_START=$value ;;
      attempts) E_ATTEMPTS=$value ;;
      next) E_NEXT=$value ;;
      sent) E_SENT=$value ;;
    esac
  done < "$EPISODE"
  case "$E_OPENED" in *[!0-9]*) E_OPENED='' ;; esac
  case "$E_START" in *[!0-9]*) E_START='' ;; esac
  case "$E_ATTEMPTS" in ''|*[!0-9]*) E_ATTEMPTS=0 ;; esac
  case "$E_NEXT" in ''|*[!0-9]*) E_NEXT=0 ;; esac
  [ "$E_SENT" = 1 ] || E_SENT=0
  return 0
}

write_episode() {
  local tmp
  tmp=$(umask 077 && mktemp "$EPISODE.tmp.XXXXXX" 2>/dev/null) || return 1
  if printf 'id=%s\nholds=%s\nopened=%s\nstart=%s\nattempts=%s\nnext=%s\nsent=%s\n' \
    "$E_ID" "$E_HOLDS" "$E_OPENED" "$E_START" "$E_ATTEMPTS" "$E_NEXT" "$E_SENT" > "$tmp" \
    && mv -f "$tmp" "$EPISODE"; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null
  return 1
}

drop_episode() { rm -f "$EPISODE" 2>/dev/null || true; }

cmd_open() {  # <task-id>
  local id=${1:-} now
  case "$id" in ''|*[!A-Za-z0-9._-]*) return 0 ;; esac
  enabled || return 0
  primary_claude_session || return 0
  lock || return 0
  now=$(date +%s)
  if read_episode; then
    case " $E_HOLDS " in *" $id "*) ;; *) E_HOLDS=${E_HOLDS:+$E_HOLDS }$id ;; esac
  else
    E_ID=$(new_episode_id) E_HOLDS=$id E_OPENED=$now
  fi
  write_episode || log "could not record a waiting question"
  unlock
}

cmd_clear() {
  [ -f "$EPISODE" ] || return 0
  lock || { log "could not end the waiting question: its lock stayed busy"; return 0; }
  drop_episode
  unlock
}

# A prompt the captain did not type: operational input, its record-backed
# doorbell, or a turn the harness started itself.
machine_prompt() {  # <text>
  case "${1#"${1%%[![:space:]]*}"}" in
    '<task-notification>'*) return 0 ;;
  esac
  printf '%s' "$1" | "$SCRIPT_DIR/fm-operational-input.sh" classify >/dev/null 2>&1 && return 0
  printf '%s' "$1" | FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    "$SCRIPT_DIR/fm-operational-input.sh" doorbell-kind >/dev/null 2>&1 && return 0
  return 1
}

cmd_hook() {  # <harness>
  local payload parsed event prompt
  payload=$(cat 2>/dev/null || true)
  [ "${1:-}" = claude ] || return 0
  [ -f "$EPISODE" ] || return 0
  [ -n "$payload" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  # shellcheck source=bin/fm-hook-host-lib.sh
  . "$SCRIPT_DIR/fm-hook-host-lib.sh"
  fm_hook_payload_is_foreign_host "$payload" && return 0
  parsed=$(printf '%s' "$payload" | jq -r '
    if type != "object" then empty else
      "\((.hook_event_name // "") | tostring)\n\((.prompt // "") | tostring)"
    end' 2>/dev/null) || return 0
  event=${parsed%%$'\n'*}
  prompt=${parsed#*$'\n'}
  case "$event" in Stop|UserPromptSubmit) ;; *) return 0 ;; esac
  primary_claude_session || return 0
  if [ "$event" = UserPromptSubmit ]; then
    machine_prompt "$prompt" && return 0
    cmd_clear
    return 0
  fi
  lock || return 0
  if read_episode && [ -z "$E_START" ] && [ "$E_SENT" = 0 ]; then
    E_START=$(date +%s)
    write_episode || log "could not start the waiting clock"
  fi
  unlock
}

# Settings, without ever echoing the topic.
S_URL='' S_TOPIC='' S_DELAY=$DEFAULT_DELAY
read_value() {  # <raw value> -> trimmed, unquoted
  local v=$1
  v=${v#"${v%%[![:space:]]*}"}
  v=${v%"${v##*[![:space:]]}"}
  case "$v" in
    \"*\") v=${v#\"}; v=${v%\"} ;;
    \'*\') v=${v#\'}; v=${v%\'} ;;
  esac
  printf '%s' "$v"
}

read_settings() {
  local key value env_file='' env_url='' env_topic='' delay=''
  S_URL='' S_TOPIC='' S_DELAY=$DEFAULT_DELAY
  while IFS='=' read -r key value || [ -n "$key" ]; do
    key=$(read_value "$key")
    case "$key" in
      url) S_URL=$(read_value "$value") ;;
      topic) S_TOPIC=$(read_value "$value") ;;
      env-file) env_file=$(read_value "$value") ;;
      delay) delay=$(read_value "$value") ;;
    esac
  done < "$SETTINGS"
  if [ -n "$env_file" ]; then
    case "$env_file" in
      \~/*) env_file="$HOME/${env_file#\~/}" ;;
      /*) ;;
      *) env_file="$FM_HOME/$env_file" ;;
    esac
    if [ -r "$env_file" ]; then
      while IFS='=' read -r key value || [ -n "$key" ]; do
        key=$(read_value "$key")
        key=${key#export }
        key=$(read_value "$key")
        case "$key" in
          NTFY_URL) env_url=$(read_value "$value") ;;
          NTFY_TOPIC) env_topic=$(read_value "$value") ;;
        esac
      done < "$env_file"
    else
      log "the ntfy env file named in config/captain-ntfy cannot be read"
    fi
    [ -n "$S_URL" ] || S_URL=$env_url
    [ -n "$S_TOPIC" ] || S_TOPIC=$env_topic
  fi
  case "$delay" in
    '') ;;
    *[!0-9]*) log "config/captain-ntfy delay is not a number of seconds; using $DEFAULT_DELAY" ;;
    *) S_DELAY=$((10#$delay)) ;;
  esac
  S_URL=${S_URL%/}
  [ -n "$S_URL" ] && [ -n "$S_TOPIC" ]
}

# 0 sent, 1 failed. The URL travels on curl's stdin config, never argv.
post() {  # <body>
  local code url
  command -v curl >/dev/null 2>&1 || { log "reminder not sent: curl is not installed"; return 1; }
  url="$S_URL/$S_TOPIC"
  case "$url" in *'"'*|*\\*|*$'\n'*) log "reminder not sent: the ntfy URL or topic has an invalid character"; return 1 ;; esac
  code=$(printf 'url = "%s"\n' "$url" | curl -K - -sS -o /dev/null -w '%{http_code}' \
    --connect-timeout 3 --max-time 8 -H "Title: $TITLE" --data-binary "$1" 2>/dev/null) || code=${code:-000}
  case "$code" in
    2[0-9][0-9]) return 0 ;;
  esac
  log "reminder POST failed (HTTP ${code:-000})"
  return 1
}

open_question_count() {
  local id count=0 rc
  for id in $E_HOLDS; do
    FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="${FM_ROOT_OVERRIDE:-}" \
      "$SCRIPT_DIR/fm-captain-hold.sh" open "$id" >/dev/null 2>&1
    rc=$?
    # An unreadable record may hide a live question, so it still counts.
    [ "$rc" -eq 1 ] || [ "$rc" -eq 3 ] || count=$((count + 1))
  done
  printf '%s\n' "$count"
}

cmd_tick() {
  local now count body id sent
  [ -f "$EPISODE" ] || return 0
  if ! enabled; then
    drop_episode
    return 0
  fi
  read_episode || return 0
  [ "$E_SENT" = 0 ] || return 0
  now=$(date +%s)
  if [ -z "$E_START" ]; then
    [ -z "$E_OPENED" ] || [ $((now - E_OPENED)) -lt "$UNSTARTED_MAX_SECS" ] || drop_episode
    return 0
  fi
  read_settings || {
    lock || return 0
    if read_episode; then
      E_SENT=1
      write_episode || drop_episode
    fi
    unlock
    log "reminder not sent: config/captain-ntfy names no ntfy URL and topic"
    return 0
  }
  [ "$now" -ge $((E_START + S_DELAY)) ] || return 0
  [ "$E_ATTEMPTS" -eq 0 ] || [ "$now" -ge "$E_NEXT" ] || return 0
  lock || return 0
  # Re-read under the lock: the captain may have answered meanwhile, or another
  # tick may have claimed this attempt.
  if ! read_episode || [ "$E_SENT" = 1 ] \
    || { [ "$E_ATTEMPTS" -gt 0 ] && [ "$now" -lt "$E_NEXT" ]; }; then
    unlock
    return 0
  fi
  # Claim the attempt, then do the slow work without the lock.
  [ -n "$E_ID" ] || E_ID=$(new_episode_id)
  E_ATTEMPTS=$((E_ATTEMPTS + 1))
  E_NEXT=$((now + RETRY_SECS))
  if ! write_episode; then
    unlock
    log "could not claim a reminder attempt"
    return 0
  fi
  unlock
  id=$E_ID
  count=$(open_question_count)
  if [ "$count" -eq 0 ]; then
    sent=none
  else
    if [ "$count" -eq 1 ]; then
      body='1 question is waiting for your answer.'
    else
      body="$count questions are waiting for your answer."
    fi
    if post "$body"; then
      sent=1
    elif [ "$E_ATTEMPTS" -ge "$MAX_ATTEMPTS" ]; then
      sent=1
      log "reminder given up after $E_ATTEMPTS failed attempts"
    else
      sent=0
    fi
  fi
  # Commit only to the same episode; a cleared or replaced one stays as it is.
  lock || { log "could not record the reminder result: its lock stayed busy"; return 0; }
  if read_episode && [ "$E_ID" = "$id" ]; then
    if [ "$sent" = none ]; then
      drop_episode
    elif [ "$sent" = 1 ]; then
      E_SENT=1
      write_episode || drop_episode
    fi
  fi
  unlock
}

cmd_needed() {
  read_episode || return 1
  [ "$E_SENT" = 0 ]
}

case "${1:-}" in
  open) shift; cmd_open "$@" ;;
  hook) shift; cmd_hook "$@" ;;
  clear) cmd_clear ;;
  tick) cmd_tick ;;
  needed) cmd_needed; exit $? ;;
  -h|--help) sed -n '2,/^set -u/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) usage ;;
esac
exit 0

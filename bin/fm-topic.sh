#!/usr/bin/env bash
# fm-topic.sh - topic tabs: one focused chat per captain topic, opened beside
# the main firstmate in its own Herdr workspace.
#
# A topic tab is an ordinary Claude Code session started in a project folder
# (for example ~/work/saas/crm). It is not a firstmate session: it never runs
# session start, never takes or meets this home's session lock, and never
# supervises, steers, or merges. Work the captain asks for there is handed to
# this home's inbox with `fm-inbox.sh note "[topic:<topic>] ..."`, and the main
# firstmate appends each result for that topic to the topic's log with `log`,
# which also rings the live tab so its agent shows the result to the captain.
# The topic-tabs skill owns when the main firstmate uses each subcommand.
#
# Usage:
#   fm-topic.sh open <topic> <dir> [--context <file>]
#   fm-topic.sh list
#   fm-topic.sh log <topic> [--done <task>] <text>...   |   ... -   (body from stdin)
#   fm-topic.sh unseen <topic> [--hook]
#   fm-topic.sh link <topic> <task>   |   unlink <topic> <task>
#   fm-topic.sh hint <task>...
#   fm-topic.sh check-dir <dir>
#
# open       Resolve the calling agent's own Herdr workspace from its pane
#            identity (HERDR_PANE_ID, HERDR_SOCKET_PATH, HERDR_SESSION, verified
#            live by bin/backends/herdr.sh's fm_backend_herdr_launcher_identity),
#            then focus the topic's existing tab, or create one there with cwd
#            <dir>, launch the topic agent in it, and focus it. The existing tab
#            is the recorded tab when it is still in that workspace with the
#            topic label, otherwise the single tab labeled `topic:<topic>` in
#            that workspace; two such tabs refuse as ambiguous. Reopening a live
#            topic with a different <dir> refuses rather than moving it.
#            --context <file> is the starting note shown as the agent's first
#            context; it is used only when a new tab is created. Reusing a live
#            tab that has unseen log entries rings it (see Delivery).
# list       Print one line per recorded topic: topic, dir, tab, created time.
# log        Append one dated entry to the topic's log, then ring the topic tab
#            (see Delivery). Logging succeeds whether or not the ring lands; a
#            second line reports `delivered:` or `not delivered: <why>`.
#            --done <task> also unlinks <task> from the topic after logging.
# unseen     Print the log entries the tab has not shown yet and mark them seen,
#            under a per-topic lock, so each entry is printed exactly once.
#            --hook frames them as context for the tab agent, prints nothing
#            when there are none, and always exits 0: the tab's Claude Code
#            UserPromptSubmit hook runs it before every prompt.
# link       Record that <task> (a task id or second mate id in this home)
#            carries a request from the topic; unlink removes the record.
# hint       For each given task id linked to a topic, print one TOPIC RESULT
#            line naming the exact `log` command for that topic.
#            bin/fm-wake-drain.sh runs it for every task whose new status it
#            presents, so a result finds its way back to the tab.
# check-dir  Exit 0 when <dir> may host a topic tab, else print why and exit 1.
#            bin/fm-claude-trust.sh --topic-dir uses this as its evidence.
#
# Delivery: the ring is one short constant doorbell line typed into the tab's
# recorded pane through bin/fm-backend.sh's Herdr submit path, never the result
# itself. It is typed only when that pane still belongs to the recorded tab, the
# tab still carries the topic label, Herdr reports a live agent in it, and its
# composer does not hold the captain's own half-typed text; otherwise nothing
# is typed. A busy agent queues the line until its turn ends. The doorbell is a
# prompt, so the UserPromptSubmit hook injects the unseen entries with it. An
# entry that was not rung, or whose ring was lost, stays unseen until the hook
# shows it with the captain's next message in the tab, or a reopened or
# recreated tab shows it first.
#
# Topic names are lowercase letters, digits, dot, dash, or underscore, starting
# with a letter or digit, at most 40 characters; uppercase input is lowercased.
#
# Directory policy (check-dir): <dir> must be an existing directory strictly
# inside one of the captain's workspace roots, and neither it nor any ancestor
# may be a firstmate home (an `.fm-secondmate-home` marker, or AGENTS.md beside
# bin/fm-session-start.sh) or this home or code root. The roots are the
# absolute paths in config/topic-roots, one per line (`#` comments and a
# leading `~/` allowed); without that file the only root is $HOME.
#
# Durable records live in the home's private data/topics/<topic>/:
#   topic.meta       key=value: topic, dir, session, workspace_id, tab_id,
#                    pane_id, label, created_at, updated_at
#   log.md           results appended by `log`, newest last, append-only
#   seen             byte offset into log.md up to which the tab has shown
#                    entries; absent means none was shown yet
#   links            task ids carrying a request from this topic, one per line
#   context.md       the starting note copied from --context, when given
#   instructions.md  the rendered standing instructions for the topic agent
#   settings.json    Claude Code settings with the UserPromptSubmit hook
#   launch.sh        the generated launcher typed into the new tab's shell
#
# Only Herdr is supported. Outside a Herdr pane, open refuses and says so;
# log, unseen, link, and hint need no Herdr pane.
# Claude Code is the topic agent. Its workspace trust is pre-registered through
# bin/fm-claude-trust.sh --topic-dir before launch, and it runs in the
# captain's own default permission mode, with no fleet permission flag, exactly
# like a session the captain started by hand.
#
# Environment:
#   FM_HOME                 operational home whose data/ and config/ are used.
#   HERDR_PANE_ID, HERDR_SOCKET_PATH, HERDR_SESSION
#                           the calling pane's Herdr identity (injected by Herdr).
#   FM_TOPIC_CLAUDE_BIN     claude executable the launcher runs (default claude).
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
FM_CODE_ROOT="$(cd "$SELF_DIR/.." && pwd -P)"
FM_HOME="${FM_HOME:-$FM_CODE_ROOT}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
TOPICS="$DATA/topics"
TEMPLATE="$FM_CODE_ROOT/.agents/skills/topic-tabs/assets/topic-agent.md"

die() { printf 'fm-topic: %s\n' "$*" >&2; exit 1; }

usage() {
  cat >&2 <<'USAGE'
usage: fm-topic.sh open <topic> <dir> [--context <file>]
       fm-topic.sh list
       fm-topic.sh log <topic> [--done <task>] <text>... | log <topic> [--done <task>] -
       fm-topic.sh unseen <topic> [--hook]
       fm-topic.sh link <topic> <task> | unlink <topic> <task>
       fm-topic.sh hint <task>...
       fm-topic.sh check-dir <dir>
USAGE
  exit 2
}

real_dir() { (cd -P -- "$1" 2>/dev/null && pwd -P); }

normalize_topic() {  # <topic>
  local topic
  topic=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  [[ "$topic" =~ ^[a-z0-9][a-z0-9._-]{0,39}$ ]] \
    || die "invalid topic name '$1': use letters, digits, dot, dash, or underscore, starting with a letter or digit, at most 40 characters"
  printf '%s' "$topic"
}

topic_label() { printf 'topic:%s' "$1"; }

# The configured workspace roots, resolved, one per line.
topic_roots() {
  local file="$CONFIG/topic-roots" line resolved
  if [ ! -f "$file" ]; then
    [ -n "${HOME:-}" ] || die "HOME is not set and no $file names a workspace root"
    real_dir "$HOME"
    return 0
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%%#*}
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    [ -n "$line" ] || continue
    case "$line" in
      \~/*) line="$HOME/${line#\~/}" ;;
      /*) ;;
      *) die "workspace root '$line' in $file is not an absolute path" ;;
    esac
    resolved=$(real_dir "$line") || continue
    printf '%s\n' "$resolved"
  done < "$file"
}

is_firstmate_home() {  # <dir>
  local d=$1
  [ -e "$d/.fm-secondmate-home" ] && return 0
  [ -f "$d/AGENTS.md" ] && [ -f "$d/bin/fm-session-start.sh" ] && return 0
  return 1
}

# check_dir <dir>: print the resolved directory on success; print the reason
# and return 1 otherwise.
check_dir() {
  local arg=$1 dir roots root inside=0 d home_real code_real
  dir=$(real_dir "$arg") || { echo "'$arg' is not an accessible directory" >&2; return 1; }
  roots=$(topic_roots)
  [ -n "$roots" ] || { echo "no workspace root in $CONFIG/topic-roots resolves to a directory" >&2; return 1; }
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    case "$dir" in
      "$root"/*) inside=1 ;;
    esac
  done <<< "$roots"
  if [ "$inside" -ne 1 ]; then
    echo "'$dir' is not inside a workspace root ($(printf '%s' "$roots" | paste -sd, -)); topic tabs open only in project folders there" >&2
    return 1
  fi
  home_real=$(real_dir "$FM_HOME") || home_real=
  code_real=$FM_CODE_ROOT
  d=$dir
  while :; do
    if [ "$d" = "$home_real" ] || [ "$d" = "$code_real" ] || is_firstmate_home "$d"; then
      echo "'$dir' is or is inside the firstmate home '$d'; a topic tab is an ordinary chat and never runs in a firstmate home" >&2
      return 1
    fi
    [ "$d" != / ] || break
    d=$(dirname -- "$d")
  done
  printf '%s\n' "$dir"
}

meta_get() {  # <meta-file> <key>
  [ -f "$1" ] || return 0
  sed -n "s/^$2=//p" "$1" | head -n 1
}

meta_write() {  # <meta-file> <key=value>...
  local file=$1 tmp
  shift
  tmp="$file.tmp.$$"
  printf '%s\n' "$@" > "$tmp"
  mv -f "$tmp" "$file"
}

now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# --- Herdr --------------------------------------------------------------------

# backend_load: source the backend dispatch and the Herdr adapter with its
# composer and process libraries, once.
backend_load() {
  [ -z "${TOPIC_BACKEND_LOADED:-}" ] || return 0
  # shellcheck source=bin/fm-backend.sh
  . "$FM_CODE_ROOT/bin/fm-backend.sh" || return 1
  fm_backend_source herdr || return 1
  TOPIC_BACKEND_LOADED=1
}

herdr_load() {
  [ "${HERDR_ENV:-}" = 1 ] && [ -n "${HERDR_PANE_ID:-}" ] \
    || die "topic tabs need firstmate running inside a Herdr pane; this session has no Herdr pane identity (other runtimes are not supported)"
  backend_load || die "could not load the Herdr backend adapter"
  fm_backend_herdr_version_check || exit 1
  SESSION=$(fm_backend_herdr_session)
  fm_backend_herdr_client_select "$SESSION"
  fm_backend_herdr_launcher_identity "$SESSION" \
    || die "could not resolve this firstmate's own Herdr workspace from its pane '$HERDR_PANE_ID'"
  WORKSPACE=$FM_BACKEND_HERDR_LAUNCHER_WORKSPACE_ID
}

hcli() { fm_backend_herdr_cli "$SESSION" "$@"; }

# find_tab <topic> <meta-file>: print the existing topic tab id in WORKSPACE,
# or nothing. Refuses on an ambiguous label match.
find_tab() {
  local topic=$1 meta=$2 label tab tabs matches count
  label=$(topic_label "$topic")
  tab=$(meta_get "$meta" tab_id)
  if [ -n "$tab" ] && [ "$(meta_get "$meta" session)" = "$SESSION" ]; then
    if hcli tab get "$tab" 2>/dev/null | jq -e --arg tab "$tab" --arg ws "$WORKSPACE" --arg label "$label" '
        .result.tab.tab_id == $tab and .result.tab.workspace_id == $ws and .result.tab.label == $label
      ' >/dev/null 2>&1; then
      printf '%s' "$tab"
      return 0
    fi
  fi
  tabs=$(hcli tab list --workspace "$WORKSPACE") || die "could not list Herdr tabs in workspace $WORKSPACE"
  matches=$(printf '%s' "$tabs" | jq -r --arg label "$label" '.result.tabs[]? | select(.label == $label) | .tab_id') \
    || die "could not parse the Herdr tab list for workspace $WORKSPACE"
  count=$(printf '%s' "$matches" | grep -c . || true)
  if [ "$count" -gt 1 ]; then
    die "workspace $WORKSPACE has $count tabs labeled '$label' ($(printf '%s' "$matches" | paste -sd' ' -)); close or rename the extra ones, then open the topic again"
  fi
  printf '%s' "$matches"
}

pane_of_tab() {  # <tab>
  fm_backend_herdr_pane_for_tab "$SESSION" "$WORKSPACE" "$1" 2>/dev/null || true
}

focus_tab() {  # <tab>
  hcli tab focus "$1" >/dev/null || die "could not focus Herdr tab $1"
}

# --- unseen results and delivery ---------------------------------------------

new_log() {  # <topic> <topic-dir>: create the log and mark its header as seen
  printf '# %s topic log\n' "$1" > "$2/log.md"
  file_size "$2/log.md" > "$2/seen"
}

file_size() { wc -c < "$1" | tr -d '[:space:]'; }

# A per-topic mkdir lock with a bounded wait; a holder that has exited is
# reclaimed.
topic_lock() {  # <topic-dir>
  local lock="$1/.lock" tries=0 holder
  while ! mkdir "$lock" 2>/dev/null; do
    holder=$(cat "$lock/pid" 2>/dev/null || true)
    if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then
      rm -rf -- "$lock"
      continue
    fi
    tries=$((tries + 1))
    [ "$tries" -lt 100 ] || return 1
    sleep 0.1
  done
  printf '%s\n' "$$" > "$lock/pid"
}

topic_unlock() { rm -rf -- "$1/.lock"; }

# The seen offset, or 0 when absent, invalid, or past a replaced log's end.
seen_offset() {  # <topic-dir> <log-size>
  local off
  off=$(cat "$1/seen" 2>/dev/null || true)
  case "$off" in ''|*[!0-9]*) off=0 ;; esac
  [ "$off" -le "$2" ] || off=0
  printf '%s' "$off"
}

has_unseen() {  # <topic-dir>
  local size off
  [ -f "$1/log.md" ] || return 1
  size=$(file_size "$1/log.md")
  off=$(seen_offset "$1" "$size")
  [ "$off" -lt "$size" ] || return 1
  [ "$off" -gt 0 ] || grep -q '^## ' "$1/log.md"
}

# take_unseen <topic-dir>: print the unseen entries and advance the seen
# offset past them, under the topic lock. From offset 0 (no record yet), the
# log's title is skipped and printing starts at the first entry heading.
take_unseen() {
  local tdir=$1 size off chunk
  [ -f "$tdir/log.md" ] || return 0
  topic_lock "$tdir" || die "the $tdir lock is held by another process"
  size=$(file_size "$tdir/log.md")
  off=$(seen_offset "$tdir" "$size")
  if [ "$off" -lt "$size" ]; then
    chunk=$(tail -c "+$((off + 1))" "$tdir/log.md" | head -c "$((size - off))")
    if [ "$off" -eq 0 ]; then
      chunk=$(printf '%s\n' "$chunk" | awk 'started || /^## / { started = 1; print }')
    fi
    printf '%s\n' "$size" > "$tdir/seen.tmp.$$" && mv -f "$tdir/seen.tmp.$$" "$tdir/seen"
    chunk=${chunk#"${chunk%%[![:space:]]*}"}
    [ -z "$chunk" ] || printf '%s\n' "$chunk"
  fi
  topic_unlock "$tdir"
}

doorbell_line() {  # <topic>
  printf ': New %s topic result from the main firstmate: show the captain your unseen topic results now.' "$1"
}

# deliver <topic> <topic-dir>: ring the recorded tab once (see Delivery in the
# header) and print `delivered: ...` or `not delivered: <why>`. Never fails.
deliver() {
  local topic=$1 tdir=$2 meta session tab pane out target verdict why=''
  meta="$tdir/topic.meta"
  session=$(meta_get "$meta" session)
  tab=$(meta_get "$meta" tab_id)
  pane=$(meta_get "$meta" pane_id)
  if [ -z "$session" ] || [ -z "$tab" ] || [ -z "$pane" ]; then
    why="no tab is recorded for it"
  elif ! command -v herdr >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    why="herdr or jq is not installed here"
  elif ! backend_load >/dev/null 2>&1; then
    why="the Herdr backend adapter could not be loaded"
  else
    fm_backend_herdr_client_select "$session" >/dev/null 2>&1 || true
    out=$(fm_backend_herdr_cli "$session" pane get "$pane" 2>/dev/null) || out=
    if ! printf '%s' "$out" | jq -e --arg tab "$tab" '.result.pane.tab_id == $tab' >/dev/null 2>&1; then
      why="its tab is closed or its pane is gone"
    elif ! fm_backend_herdr_cli "$session" tab get "$tab" 2>/dev/null \
        | jq -e --arg label "$(topic_label "$topic")" '.result.tab.label == $label' >/dev/null 2>&1; then
      why="tab $tab no longer carries the topic label"
    else
      target="$session:$pane"
      if [ "$(fm_backend_agent_state herdr "$target" 2>/dev/null || true)" != alive ]; then
        why="no live agent is running in the tab"
      elif [ "$(fm_backend_composer_state herdr "$target" 2>/dev/null || true)" = pending ]; then
        why="the captain has unsent text in the tab"
      elif ! verdict=$(fm_backend_send_text_submit herdr "$target" "$(doorbell_line "$topic")" 2 0.4 0.3 2>/dev/null) \
          || [ "$verdict" = send-failed ]; then
        why="typing into the tab failed"
      fi
    fi
  fi
  if [ -z "$why" ]; then
    printf 'delivered: %s tab %s\n' "$topic" "$tab"
  else
    printf 'not delivered: %s; the tab shows the result with the next message there or when the topic is opened again\n' "$why"
  fi
}

normalize_task() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$ ]] || die "invalid task id '$1'"
  printf '%s' "$1"
}

render_instructions() {  # <topic> <dir> <topic-dir> <out>
  local topic=$1 dir=$2 tdir=$3 out=$4
  [ -f "$TEMPLATE" ] || die "missing topic agent template $TEMPLATE"
  TOPIC="$topic" DIR="$dir" TDIR="$tdir" HOME_DIR="$(real_dir "$FM_HOME")" CODE="$FM_CODE_ROOT" \
    awk '{
      gsub(/\{\{TOPIC\}\}/, ENVIRON["TOPIC"]);
      gsub(/\{\{DIR\}\}/, ENVIRON["DIR"]);
      gsub(/\{\{TOPIC_DIR\}\}/, ENVIRON["TDIR"]);
      gsub(/\{\{MAIN_HOME\}\}/, ENVIRON["HOME_DIR"]);
      gsub(/\{\{CODE_ROOT\}\}/, ENVIRON["CODE"]);
      print
    }' "$TEMPLATE" > "$out"
}

write_launcher() {  # <topic> <dir> <topic-dir>
  local topic=$1 dir=$2 tdir=$3 prompt hook claude_bin config_line=
  claude_bin=${FM_TOPIC_CLAUDE_BIN:-claude}
  if [ -s "$tdir/context.md" ]; then
    prompt="This is the $topic topic tab. Starting note from the main firstmate:

$(cat "$tdir/context.md")

Show the captain any unseen topic results first, then give a short summary of where the $topic topic stands, then wait for their request."
  else
    prompt="This is the $topic topic tab. Show the captain any unseen topic results first, then read your topic log at $tdir/log.md, give a short summary of where the $topic topic stands, then wait for their request."
  fi
  printf '%s\n' "$prompt" > "$tdir/first-prompt.md"
  # Every prompt, the doorbell included, first runs `unseen --hook`, whose
  # output Claude Code adds to the agent's context.
  hook="FM_HOME=$(printf '%q' "$(real_dir "$FM_HOME")") $(printf '%q' "$SELF_DIR/fm-topic.sh") unseen $(printf '%q' "$topic") --hook"
  jq -n --arg command "$hook" \
    '{hooks: {UserPromptSubmit: [{hooks: [{type: "command", command: $command}]}]}}' \
    > "$tdir/settings.json" || die "could not write $tdir/settings.json"
  # The pane's environment comes from the Herdr server, not from this caller,
  # so the Claude store that trust was registered in is pinned explicitly.
  if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
    config_line="export CLAUDE_CONFIG_DIR=$(printf '%q' "$CLAUDE_CONFIG_DIR")"
  else
    config_line="unset CLAUDE_CONFIG_DIR"
  fi
  # The launcher's own expansions are written literally, to run in the pane.
  # shellcheck disable=SC2016
  {
    printf '#!/usr/bin/env bash\n'
    printf '# Generated by fm-topic.sh open; launches the %s topic agent.\n' "$topic"
    printf 'for v in $(compgen -e); do case $v in FM_*) unset "$v" ;; esac; done\n'
    # A pane can inherit a parent Claude session's identity markers from the
    # Herdr server's environment; left set, Claude treats the topic chat as a
    # child session and stops saving its transcript.
    printf 'unset CLAUDECODE CLAUDE_PID CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_EXECPATH CLAUDE_CODE_SESSION_ID CLAUDE_CODE_CHILD_SESSION CLAUDE_CODE_SESSION_ATTENDED CLAUDE_CODE_MESSAGING_SOCKET CLAUDE_CODE_MESSAGING_TOKEN\n'
    printf '%s\n' "$config_line"
    printf 'cd %q || exit 1\n' "$dir"
    printf 'exec %q --name %q --add-dir %q --settings %q --append-system-prompt "$(cat %q)" "$(cat %q)"\n' \
      "$claude_bin" "$topic" "$tdir" "$tdir/settings.json" "$tdir/instructions.md" "$tdir/first-prompt.md"
  } > "$tdir/launch.sh"
  chmod 700 "$tdir/launch.sh"
}

cmd_open() {
  local topic dir context='' tdir meta tab pane out recorded_dir created
  [ "$#" -ge 2 ] || usage
  topic=$(normalize_topic "$1")
  dir=$2
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --context) [ "$#" -ge 2 ] || usage; context=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -z "$context" ] || [ -r "$context" ] || die "context file '$context' is not readable"
  dir=$(check_dir "$dir") || die "refusing to open topic '$topic'"
  herdr_load

  tdir="$TOPICS/$topic"
  meta="$tdir/topic.meta"
  mkdir -p "$tdir"
  [ -f "$tdir/log.md" ] || new_log "$topic" "$tdir"

  tab=$(find_tab "$topic" "$meta")
  if [ -n "$tab" ]; then
    recorded_dir=$(meta_get "$meta" dir)
    if [ -n "$recorded_dir" ] && [ "$recorded_dir" != "$dir" ]; then
      die "topic '$topic' is already open in $recorded_dir (tab $tab); close that tab first to reopen it in $dir"
    fi
    focus_tab "$tab"
    pane=$(meta_get "$meta" pane_id)
    [ -n "$pane" ] || pane=$(pane_of_tab "$tab")
    created=$(meta_get "$meta" created_at)
    meta_write "$meta" "topic=$topic" "dir=$dir" "session=$SESSION" "workspace_id=$WORKSPACE" \
      "tab_id=$tab" "pane_id=$pane" "label=$(topic_label "$topic")" \
      "created_at=${created:-$(now_utc)}" "updated_at=$(now_utc)"
    printf 'focused: %s tab %s (existing)\n' "$topic" "$tab"
    [ -z "$context" ] || printf 'note: the starting note is used only for a new tab; this one was reused\n'
    if has_unseen "$tdir"; then deliver "$topic" "$tdir"; fi
    return 0
  fi

  if [ -n "$context" ]; then
    cp -- "$context" "$tdir/context.md.tmp.$$" && mv -f "$tdir/context.md.tmp.$$" "$tdir/context.md"
  else
    rm -f "$tdir/context.md"
  fi
  render_instructions "$topic" "$dir" "$tdir" "$tdir/instructions.md"
  write_launcher "$topic" "$dir" "$tdir"
  FM_HOME="$FM_HOME" "$SELF_DIR/fm-claude-trust.sh" --topic-dir "$dir" >/dev/null \
    || die "could not pre-register Claude workspace trust for '$dir'"

  out=$(hcli tab create --workspace "$WORKSPACE" --cwd "$dir" --label "$(topic_label "$topic")" --no-focus) \
    || die "could not create a Herdr tab for topic '$topic' in workspace $WORKSPACE"
  tab=$(printf '%s' "$out" | jq -r '.result.tab.tab_id // empty' 2>/dev/null)
  pane=$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id // empty' 2>/dev/null)
  [ -n "$tab" ] && [ -n "$pane" ] || die "could not read the new tab and pane ids from Herdr's tab create output"
  meta_write "$meta" "topic=$topic" "dir=$dir" "session=$SESSION" "workspace_id=$WORKSPACE" \
    "tab_id=$tab" "pane_id=$pane" "label=$(topic_label "$topic")" \
    "created_at=$(now_utc)" "updated_at=$(now_utc)"
  hcli pane run "$pane" "exec bash $(printf '%q' "$tdir/launch.sh")" >/dev/null \
    || die "created tab $tab but could not start the topic agent in pane $pane"
  focus_tab "$tab"
  printf 'opened: %s tab %s in %s\n' "$topic" "$tab" "$dir"
}

cmd_list() {
  local meta found=0
  [ -d "$TOPICS" ] || { echo "no topics"; return 0; }
  for meta in "$TOPICS"/*/topic.meta; do
    [ -f "$meta" ] || continue
    found=1
    printf '%s\t%s\t%s\t%s\n' "$(meta_get "$meta" topic)" "$(meta_get "$meta" dir)" \
      "$(meta_get "$meta" tab_id)" "$(meta_get "$meta" created_at)"
  done
  [ "$found" -eq 1 ] || echo "no topics"
}

cmd_log() {
  local topic tdir body done_task=''
  [ "$#" -ge 2 ] || usage
  topic=$(normalize_topic "$1")
  shift
  if [ "$1" = --done ]; then
    [ "$#" -ge 3 ] || usage
    done_task=$(normalize_task "$2")
    shift 2
  fi
  tdir="$TOPICS/$topic"
  [ -f "$tdir/topic.meta" ] || die "no topic '$topic' is recorded in $TOPICS; open it first"
  if [ "$1" = - ] && [ "$#" -eq 1 ]; then
    body=$(cat)
  else
    body="$*"
  fi
  [ -n "${body//[[:space:]]/}" ] || die "refusing an empty log entry"
  [ -f "$tdir/log.md" ] || new_log "$topic" "$tdir"
  printf '\n## %s\n\n%s\n' "$(now_utc)" "$body" >> "$tdir/log.md"
  printf 'logged: %s\n' "$topic"
  [ -z "$done_task" ] || unlink_task "$tdir" "$done_task"
  deliver "$topic" "$tdir"
}

cmd_unseen() {
  local topic tdir hook=0 entries
  [ "$#" -ge 1 ] || usage
  [ "$#" -lt 2 ] || { [ "$#" -eq 2 ] && [ "$2" = --hook ] || usage; hook=1; }
  if [ "$hook" -eq 1 ]; then
    # A hook must never block or fail the captain's prompt.
    topic=$(normalize_topic "$1" 2>/dev/null) || exit 0
    tdir="$TOPICS/$topic"
    entries=$( (take_unseen "$tdir") 2>/dev/null) || exit 0
    [ -n "$entries" ] || exit 0
    printf 'Unseen %s topic results from the main firstmate, newest last. Tell the captain these first, in plain words with any links, before anything else:\n\n%s\n' \
      "$topic" "$entries"
    exit 0
  fi
  topic=$(normalize_topic "$1")
  tdir="$TOPICS/$topic"
  [ -f "$tdir/topic.meta" ] || die "no topic '$topic' is recorded in $TOPICS; open it first"
  take_unseen "$tdir"
}

unlink_task() {  # <topic-dir> <task>
  local tdir=$1 task=$2
  [ -f "$tdir/links" ] || return 0
  grep -vxF -- "$task" "$tdir/links" > "$tdir/links.tmp.$$" || true
  mv -f "$tdir/links.tmp.$$" "$tdir/links"
}

cmd_link() {  # <link|unlink> <topic> <task>
  local action=$1 topic tdir task
  [ "$#" -eq 3 ] || usage
  topic=$(normalize_topic "$2")
  task=$(normalize_task "$3")
  tdir="$TOPICS/$topic"
  [ -f "$tdir/topic.meta" ] || die "no topic '$topic' is recorded in $TOPICS; open it first"
  if [ "$action" = link ]; then
    grep -qxF -- "$task" "$tdir/links" 2>/dev/null || printf '%s\n' "$task" >> "$tdir/links"
    printf 'linked: %s -> %s\n' "$task" "$topic"
  else
    unlink_task "$tdir" "$task"
    printf 'unlinked: %s from %s\n' "$task" "$topic"
  fi
}

cmd_hint() {
  local task links topic
  [ "$#" -ge 1 ] || usage
  [ -d "$TOPICS" ] || return 0
  for task in "$@"; do
    [[ "$task" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$ ]] || continue
    for links in "$TOPICS"/*/links; do
      grep -qxF -- "$task" "$links" 2>/dev/null || continue
      topic=${links%/links}
      topic=${topic##*/}
      printf 'TOPIC RESULT: %s carries a request from the %s topic tab; give that tab each captain-facing outcome too: bin/fm-topic.sh log %s "<outcome>", adding --done %s with the final one.\n' \
        "$task" "$topic" "$topic" "$task"
    done
  done
}

cmd_check_dir() {
  [ "$#" -eq 1 ] || usage
  check_dir "$1" >/dev/null
}

case "${1:-}" in
  open) shift; cmd_open "$@" ;;
  list) shift; cmd_list "$@" ;;
  log) shift; cmd_log "$@" ;;
  unseen) shift; cmd_unseen "$@" ;;
  link|unlink) cmd_link "$@" ;;
  hint) shift; cmd_hint "$@" ;;
  check-dir) shift; cmd_check_dir "$@" ;;
  -h|--help|help) usage ;;
  *) usage ;;
esac

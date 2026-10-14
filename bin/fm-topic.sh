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
#   fm-topic.sh log <topic> [--done <task>] [--decision] <text>...   |   ... -   (body from stdin)
#   fm-topic.sh unseen <topic> [--hook]
#   fm-topic.sh link <topic> <task>   |   unlink <topic> <task>
#   fm-topic.sh hint <task>...
#   fm-topic.sh check-dir <dir>
#   fm-topic.sh started <topic>        (Claude Code SessionStart hook)
#
# open       Resolve the calling agent's own Herdr workspace from its pane
#            identity (HERDR_PANE_ID, HERDR_SOCKET_PATH, HERDR_SESSION, verified
#            live by bin/backends/herdr.sh's fm_backend_herdr_launcher_identity),
#            then focus the topic's existing tab, or create one there with cwd
#            <dir>, launch the topic agent in it, and focus it. The existing tab
#            is found in that workspace, in this order: the recorded tab; the
#            single tab labeled `topic:<topic>` (two such tabs refuse as
#            ambiguous); or the single tab holding the recorded pane or a pane
#            running the recorded chat (see Session binding). Reopening a live
#            topic with a different <dir> refuses rather than moving it.
#            --context <file> is the starting note shown as the agent's first
#            context; it is used only when a new tab starts a new chat. Reusing
#            a live tab that has unseen log entries rings it (see Delivery).
#            A new tab resumes the topic's recorded chat when there is one for
#            the same <dir> (see Resume); a second output line says whether it
#            `resumed:`, fell back to a `new chat:`, or is still `resuming:`.
# list       Print one line per recorded topic: topic, dir, tab, created time.
# log        Append one dated entry to the topic's log, then ring the topic tab
#            (see Delivery). Logging succeeds whether or not the ring lands; a
#            second line reports `delivered:` or `not delivered: <why>`.
#            --done <task> also unlinks <task> from the topic after logging.
#            --decision marks the entry `Decision needed`: a question the tab
#            asks the captain and whose answer it sends back as a topic note.
# unseen     Print the log entries the tab has not shown yet and mark them seen,
#            under a per-topic lock, so each entry is printed exactly once.
#            --hook frames them as context for the tab agent, prints nothing
#            when there are none, and always exits 0: the tab's Claude Code
#            UserPromptSubmit hook runs it before every prompt.
# started    The tab's Claude Code SessionStart hook: reads the hook's JSON on
#            stdin and, when its pane (HERDR_PANE_ID) is the recorded pane and
#            its cwd is the topic folder, records the chat's session id and
#            marks that a chat started in that pane. Prints nothing, exits 0.
# link       Record that <task> (a task id or second mate id in this home)
#            carries a request from the topic; unlink removes the record.
# hint       For each given task id linked to a topic, print one TOPIC RESULT
#            line naming the exact `log` command for that topic.
#            bin/fm-wake-drain.sh runs it for every task whose new status it
#            presents, so a result finds its way back to the tab.
# check-dir  Exit 0 when <dir> may host a topic tab, else print why and exit 1.
#            bin/fm-claude-trust.sh --topic-dir uses this as its evidence.
#
# Delivery: the ring is one short constant doorbell line typed into the
# topic's pane in the recorded tab, resolved live from Herdr (see Session
# binding), through bin/fm-backend.sh's Herdr submit path, never the result
# itself. It is typed only when the recorded tab is still open, it carries the
# topic label or is recognized by its pane or chat, Herdr reports a live agent
# in that pane, and its composer does not hold the captain's own half-typed
# text; otherwise nothing is typed. A busy agent queues the line until its turn ends. The doorbell is a
# prompt, so the UserPromptSubmit hook injects the unseen entries with it. An
# entry that was not rung, or whose ring was lost, stays unseen until the hook
# shows it with the captain's next message in the tab, or a reopened or
# recreated tab shows it first.
#
# Session binding: open, log, and the SessionStart hook keep the record bound
# to the live tab. Whenever open or log binds to a tab, the topic's pane in it
# is re-read from Herdr - the recorded pane when it is still in that tab, else
# the pane running the recorded chat, else the tab's first pane - and replaces
# the recorded pane_id. The chat is the Claude Code session id Herdr reports
# for that pane (bin/backends/herdr.sh's fm_backend_herdr_pane_agent_session_ref,
# agent `claude`), recorded only when that pane's cwd is the topic folder.
# A tab whose label lost the `topic:<topic>` form is still the topic's tab when
# it holds the recorded pane or a pane running the recorded chat, never by its
# name alone; open and log then restore its label.
#
# Resume: when open creates a tab and a chat is recorded for the same folder,
# the launcher runs `claude --resume <id>` with the same instructions, hook
# settings, and a short first prompt, so the unseen-results hook catches the
# chat up on what it missed. If that Claude exits with an error before its
# SessionStart hook reported a chat in the pane - the chat is gone or cannot be
# resumed - the launcher records the failure and starts a new chat with the
# starting note exactly as a first open does. Open waits up to
# FM_TOPIC_RESUME_WAIT seconds for either outcome and reports it.
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
#   topic.meta       key=value: topic, dir, session (the Herdr session),
#                    workspace_id, tab_id, pane_id, label, agent_session (the
#                    tab's Claude Code session id), created_at, updated_at
#   log.md           results appended by `log`, newest last, append-only
#   seen             byte offset into log.md up to which the tab has shown
#                    entries; absent means none was shown yet
#   links            task ids carrying a request from this topic, one per line
#   context.md       the starting note copied from --context, when given
#   instructions.md  the rendered standing instructions for the topic agent
#   settings.json    Claude Code settings with the UserPromptSubmit and
#                    SessionStart hooks
#   launch.sh        the generated launcher typed into the new tab's shell
#   started          written by the SessionStart hook: the pane and session id
#                    of the chat that last started in the recorded pane
#   resume-failed    written by the launcher when a resume did not start
#
# Only Herdr is supported. Outside a Herdr pane, open refuses and says so;
# log, unseen, started, link, and hint need no Herdr pane.
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
#   FM_TOPIC_RESUME_WAIT    seconds open waits for a resume outcome (default 20).
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
       fm-topic.sh log <topic> [--done <task>] [--decision] <text>... | ... -
       fm-topic.sh unseen <topic> [--hook]
       fm-topic.sh link <topic> <task> | unlink <topic> <task>
       fm-topic.sh hint <task>...
       fm-topic.sh check-dir <dir>
       fm-topic.sh started <topic>
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

# meta_update <topic-dir> <key=value>...: set each key in topic.meta under the
# topic lock, keeping every other recorded key.
meta_update() {
  local tdir=$1 meta tmp kv
  shift
  meta="$tdir/topic.meta"
  tmp="$meta.tmp.$$"
  topic_lock "$tdir" || return 1
  if [ -f "$meta" ]; then cp -- "$meta" "$tmp"; else : > "$tmp"; fi
  for kv in "$@"; do
    grep -v "^${kv%%=*}=" "$tmp" > "$tmp.next" || true
    printf '%s\n' "$kv" >> "$tmp.next"
    mv -f "$tmp.next" "$tmp"
  done
  mv -f "$tmp" "$meta"
  topic_unlock "$tdir"
}

# A Claude Code session id, as Herdr and the SessionStart hook report it.
valid_chat_id() {
  [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
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

# load_panes: read WORKSPACE's panes into PANES_JSON (a JSON array).
load_panes() {
  local out
  out=$(hcli pane list --workspace "$WORKSPACE" 2>/dev/null) || return 1
  PANES_JSON=$(printf '%s' "$out" | jq -c '[.result.panes[]?]' 2>/dev/null) || return 1
  [ -n "$PANES_JSON" ]
}

# pane_chat <pane>: the Claude Code session id Herdr holds for <pane>, or
# nothing when it holds none or another agent's.
pane_chat() {
  local ref id
  ref=$(fm_backend_herdr_pane_agent_session_ref "$SESSION" "$1" 2>/dev/null) || return 0
  [ "${ref%%$'\t'*}" = claude ] || return 0
  id=${ref#*$'\t'}
  if valid_chat_id "$id"; then printf '%s' "$id"; fi
  return 0
}

# bind_pane <tab> <recorded-pane> <recorded-chat>: set TOPIC_PANE to the
# topic's pane in <tab> from PANES_JSON - the recorded pane when it is there,
# else the pane running the recorded chat, else the tab's first pane - and
# PANE_OWNED=1 only for the first two. Returns 1 when the tab has no pane.
# Call as a plain statement; it communicates through those globals.
bind_pane() {
  local tab=$1 rpane=$2 rchat=$3 panes p
  TOPIC_PANE=
  PANE_OWNED=0
  panes=$(printf '%s' "$PANES_JSON" | jq -r --arg t "$tab" '.[] | select(.tab_id == $t) | .pane_id' 2>/dev/null)
  [ -n "$panes" ] || return 1
  if [ -n "$rpane" ] && printf '%s\n' "$panes" | grep -qxF -- "$rpane"; then
    TOPIC_PANE=$rpane
    PANE_OWNED=1
    return 0
  fi
  if [ -n "$rchat" ]; then
    while IFS= read -r p; do
      if [ "$(pane_chat "$p")" = "$rchat" ]; then
        TOPIC_PANE=$p
        PANE_OWNED=1
        return 0
      fi
    done <<< "$panes"
  fi
  TOPIC_PANE=$(printf '%s\n' "$panes" | head -n 1)
}

# bound_chat <pane> <dir>: the chat Herdr reports for <pane> when that pane's
# cwd is <dir>, or nothing.
bound_chat() {
  local pane=$1 dir=$2
  printf '%s' "$PANES_JSON" | jq -e --arg p "$pane" --arg d "$dir" \
    'any(.[]; .pane_id == $p and (.cwd == $d or .foreground_cwd == $d))' >/dev/null 2>&1 || return 0
  pane_chat "$pane"
}

# restore_label <tab> <label>: give a recognized tab its topic label back.
restore_label() {
  hcli tab rename "$1" "$2" >/dev/null 2>&1
}

# find_tab <topic> <meta-file>: set FOUND_TAB to the topic's live tab in
# WORKSPACE (or empty), TOPIC_PANE to the topic's pane in it, and RELABELED=1
# when its label was restored (see Session binding in the header). Refuses on
# an ambiguous match. Call as a plain statement.
find_tab() {
  local topic=$1 meta=$2 label rtab rpane rchat tabs matches count own_tab t owned=''
  label=$(topic_label "$topic")
  FOUND_TAB=
  TOPIC_PANE=
  RELABELED=0
  rtab=$(meta_get "$meta" tab_id)
  rpane=$(meta_get "$meta" pane_id)
  rchat=$(meta_get "$meta" agent_session)
  valid_chat_id "$rchat" || rchat=
  # Tab and pane ids belong to one Herdr session; a chat id is Claude's own.
  if [ "$(meta_get "$meta" session)" != "$SESSION" ]; then rtab=; rpane=; fi
  tabs=$(hcli tab list --workspace "$WORKSPACE") || die "could not list Herdr tabs in workspace $WORKSPACE"
  printf '%s' "$tabs" | jq -e '.result.tabs' >/dev/null 2>&1 \
    || die "could not parse the Herdr tab list for workspace $WORKSPACE"
  load_panes || die "could not list Herdr panes in workspace $WORKSPACE"
  if [ -n "$rtab" ] && printf '%s' "$tabs" | jq -e --arg t "$rtab" 'any(.result.tabs[]; .tab_id == $t)' >/dev/null 2>&1; then
    if printf '%s' "$tabs" | jq -e --arg t "$rtab" --arg l "$label" 'any(.result.tabs[]; .tab_id == $t and .label == $l)' >/dev/null 2>&1; then
      FOUND_TAB=$rtab
    elif bind_pane "$rtab" "$rpane" "$rchat" && [ "$PANE_OWNED" = 1 ]; then
      FOUND_TAB=$rtab
    fi
  fi
  if [ -z "$FOUND_TAB" ]; then
    matches=$(printf '%s' "$tabs" | jq -r --arg label "$label" '.result.tabs[]? | select(.label == $label) | .tab_id')
    count=$(printf '%s' "$matches" | grep -c . || true)
    if [ "$count" -gt 1 ]; then
      die "workspace $WORKSPACE has $count tabs labeled '$label' ($(printf '%s' "$matches" | paste -sd' ' -)); close or rename the extra ones, then open the topic again"
    fi
    FOUND_TAB=$matches
  fi
  if [ -z "$FOUND_TAB" ] && { [ -n "$rpane" ] || [ -n "$rchat" ]; }; then
    own_tab=$(printf '%s' "$PANES_JSON" | jq -r --arg p "$HERDR_PANE_ID" '.[] | select(.pane_id == $p) | .tab_id' 2>/dev/null)
    while IFS= read -r t; do
      [ -n "$t" ] && [ "$t" != "$own_tab" ] || continue
      if bind_pane "$t" "$rpane" "$rchat" && [ "$PANE_OWNED" = 1 ]; then owned="$owned$t"$'\n'; fi
    done <<< "$(printf '%s' "$tabs" | jq -r '.result.tabs[]?.tab_id')"
    count=$(printf '%s' "$owned" | grep -c . || true)
    if [ "$count" -gt 1 ]; then
      die "workspace $WORKSPACE has $count tabs holding the $topic topic's pane or chat ($(printf '%s' "$owned" | paste -sd' ' -)); close the extra ones, then open the topic again"
    fi
    FOUND_TAB=$(printf '%s' "$owned" | head -n 1)
  fi
  [ -n "$FOUND_TAB" ] || return 0
  bind_pane "$FOUND_TAB" "$rpane" "$rchat" || true
  if ! printf '%s' "$tabs" | jq -e --arg t "$FOUND_TAB" --arg l "$label" 'any(.result.tabs[]; .tab_id == $t and .label == $l)' >/dev/null 2>&1; then
    if restore_label "$FOUND_TAB" "$label"; then RELABELED=1; fi
  fi
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

# deliver <topic> <topic-dir>: ring the topic's pane in the recorded tab once
# (see Delivery and Session binding in the header), rebinding the record to
# that live pane first, and print `delivered: ...` or `not delivered: <why>`.
# Never fails.
deliver() {
  local topic=$1 tdir=$2 meta tab rpane rchat dir label chat target verdict why=''
  meta="$tdir/topic.meta"
  SESSION=$(meta_get "$meta" session)
  WORKSPACE=$(meta_get "$meta" workspace_id)
  tab=$(meta_get "$meta" tab_id)
  rpane=$(meta_get "$meta" pane_id)
  rchat=$(meta_get "$meta" agent_session)
  valid_chat_id "$rchat" || rchat=
  dir=$(meta_get "$meta" dir)
  label=$(topic_label "$topic")
  if [ -z "$SESSION" ] || [ -z "$WORKSPACE" ] || [ -z "$tab" ]; then
    why="no tab is recorded for it"
  elif ! command -v herdr >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    why="herdr or jq is not installed here"
  elif ! backend_load >/dev/null 2>&1; then
    why="the Herdr backend adapter could not be loaded"
  else
    fm_backend_herdr_client_select "$SESSION" >/dev/null 2>&1 || true
    if ! hcli tab get "$tab" 2>/dev/null | jq -e --arg ws "$WORKSPACE" '.result.tab.workspace_id == $ws' >/dev/null 2>&1 \
        || ! load_panes || ! bind_pane "$tab" "$rpane" "$rchat"; then
      why="its tab is closed or its pane is gone"
    elif ! hcli tab get "$tab" 2>/dev/null | jq -e --arg label "$label" '.result.tab.label == $label' >/dev/null 2>&1 \
        && { [ "$PANE_OWNED" != 1 ] || ! restore_label "$tab" "$label"; }; then
      why="tab $tab no longer carries the topic label"
    else
      chat=$(bound_chat "$TOPIC_PANE" "$dir")
      meta_update "$tdir" "pane_id=$TOPIC_PANE" "agent_session=${chat:-$rchat}" "updated_at=$(now_utc)" >/dev/null 2>&1 || true
      target="$SESSION:$TOPIC_PANE"
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

# write_launcher <topic> <dir> <topic-dir> [<chat-id>]: write settings.json and
# launch.sh; with a chat id the launcher resumes that chat (see Resume).
write_launcher() {
  local topic=$1 dir=$2 tdir=$3 resume=${4:-} prompt hook started_hook claude_bin config_line='' agent_args fresh
  claude_bin=${FM_TOPIC_CLAUDE_BIN:-claude}
  if [ -s "$tdir/context.md" ]; then
    prompt="This is the $topic topic tab. Starting note from the main firstmate:

$(cat "$tdir/context.md")

Show the captain any unseen topic results first, then give a short summary of where the $topic topic stands, then wait for their request."
  else
    prompt="This is the $topic topic tab. Show the captain any unseen topic results first, then read your topic log at $tdir/log.md, give a short summary of where the $topic topic stands, then wait for their request."
  fi
  printf '%s\n' "$prompt" > "$tdir/first-prompt.md"
  printf '%s\n' "This $topic topic tab was closed and has been reopened on this same chat. Show the captain any unseen topic results first, then wait for their request." \
    > "$tdir/resume-prompt.md"
  # Every prompt, the doorbell included, first runs `unseen --hook`, whose
  # output Claude Code adds to the agent's context; every chat start runs
  # `started`, which records the chat for a later resume.
  hook="FM_HOME=$(printf '%q' "$(real_dir "$FM_HOME")") $(printf '%q' "$SELF_DIR/fm-topic.sh") unseen $(printf '%q' "$topic") --hook"
  started_hook="FM_HOME=$(printf '%q' "$(real_dir "$FM_HOME")") $(printf '%q' "$SELF_DIR/fm-topic.sh") started $(printf '%q' "$topic")"
  jq -n --arg command "$hook" --arg started "$started_hook" \
    '{hooks: {UserPromptSubmit: [{hooks: [{type: "command", command: $command}]}],
              SessionStart: [{hooks: [{type: "command", command: $started}]}]}}' \
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
  agent_args=$(printf '%q --name %q --add-dir %q --settings %q --append-system-prompt "$(cat %q)"' \
    "$claude_bin" "$topic" "$tdir" "$tdir/settings.json" "$tdir/instructions.md")
  # shellcheck disable=SC2016
  fresh=$(printf 'exec %s "$(cat %q)"' "$agent_args" "$tdir/first-prompt.md")
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
    if [ -n "$resume" ]; then
      # A resume that exits with an error before its SessionStart hook reported
      # a chat in this pane never started; fall back to a new chat.
      printf 'rm -f %q %q\n' "$tdir/started" "$tdir/resume-failed"
      printf '%s --resume %q "$(cat %q)"\n' "$agent_args" "$resume" "$tdir/resume-prompt.md"
      printf 'rc=$?\n'
      printf 'if [ "$rc" -eq 0 ] || [ -e %q ]; then exit "$rc"; fi\n' "$tdir/started"
      printf 'printf '"'"'%%s\\n'"'"' "$rc" > %q\n' "$tdir/resume-failed"
    fi
    printf '%s\n' "$fresh"
  } > "$tdir/launch.sh"
  chmod 700 "$tdir/launch.sh"
}

# await_resume <topic-dir> <pane>: print `resumed`, `failed`, or `pending`
# after waiting up to FM_TOPIC_RESUME_WAIT seconds for the launcher's outcome.
await_resume() {
  local tdir=$1 pane=$2 wait=${FM_TOPIC_RESUME_WAIT:-20} tries=0
  case "$wait" in ''|*[!0-9]*) wait=20 ;; esac
  while :; do
    if [ -e "$tdir/resume-failed" ]; then echo failed; return 0; fi
    if [ "$(cut -d' ' -f1 "$tdir/started" 2>/dev/null)" = "$pane" ]; then echo resumed; return 0; fi
    [ "$tries" -lt "$((wait * 4))" ] || break
    tries=$((tries + 1))
    sleep 0.25
  done
  echo pending
}

cmd_open() {
  local topic dir context='' tdir meta tab pane out recorded_dir created chat resume='' outcome
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
  recorded_dir=$(meta_get "$meta" dir)
  created=$(meta_get "$meta" created_at)
  chat=$(meta_get "$meta" agent_session)
  valid_chat_id "$chat" || chat=

  find_tab "$topic" "$meta"
  tab=$FOUND_TAB
  if [ -n "$tab" ]; then
    if [ -n "$recorded_dir" ] && [ "$recorded_dir" != "$dir" ]; then
      die "topic '$topic' is already open in $recorded_dir (tab $tab); close that tab first to reopen it in $dir"
    fi
    focus_tab "$tab"
    pane=$TOPIC_PANE
    [ -z "$pane" ] || chat=$(bound_chat "$pane" "$dir") || true
    [ -n "$chat" ] || { chat=$(meta_get "$meta" agent_session); valid_chat_id "$chat" || chat=; }
    meta_update "$tdir" "topic=$topic" "dir=$dir" "session=$SESSION" "workspace_id=$WORKSPACE" \
      "tab_id=$tab" "pane_id=$pane" "label=$(topic_label "$topic")" "agent_session=$chat" \
      "created_at=${created:-$(now_utc)}" "updated_at=$(now_utc)" \
      || die "could not update the $topic topic record"
    printf 'focused: %s tab %s (existing)\n' "$topic" "$tab"
    [ "$RELABELED" != 1 ] || printf 'note: restored the tab label %s\n' "$(topic_label "$topic")"
    [ -z "$context" ] || printf 'note: the starting note is used only for a new tab; this one was reused\n'
    if has_unseen "$tdir"; then deliver "$topic" "$tdir"; fi
    return 0
  fi

  if [ -n "$context" ]; then
    cp -- "$context" "$tdir/context.md.tmp.$$" && mv -f "$tdir/context.md.tmp.$$" "$tdir/context.md"
  else
    rm -f "$tdir/context.md"
  fi
  # A chat is resumed only in the folder it ran in.
  if [ -n "$chat" ] && [ "$recorded_dir" = "$dir" ]; then resume=$chat; fi
  render_instructions "$topic" "$dir" "$tdir" "$tdir/instructions.md"
  write_launcher "$topic" "$dir" "$tdir" "$resume"
  FM_HOME="$FM_HOME" "$SELF_DIR/fm-claude-trust.sh" --topic-dir "$dir" >/dev/null \
    || die "could not pre-register Claude workspace trust for '$dir'"

  out=$(hcli tab create --workspace "$WORKSPACE" --cwd "$dir" --label "$(topic_label "$topic")" --no-focus) \
    || die "could not create a Herdr tab for topic '$topic' in workspace $WORKSPACE"
  tab=$(printf '%s' "$out" | jq -r '.result.tab.tab_id // empty' 2>/dev/null)
  pane=$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id // empty' 2>/dev/null)
  [ -n "$tab" ] && [ -n "$pane" ] || die "could not read the new tab and pane ids from Herdr's tab create output"
  meta_update "$tdir" "topic=$topic" "dir=$dir" "session=$SESSION" "workspace_id=$WORKSPACE" \
    "tab_id=$tab" "pane_id=$pane" "label=$(topic_label "$topic")" "agent_session=$chat" \
    "created_at=$(now_utc)" "updated_at=$(now_utc)" \
    || die "could not update the $topic topic record"
  rm -f "$tdir/started" "$tdir/resume-failed"
  hcli pane run "$pane" "exec bash $(printf '%q' "$tdir/launch.sh")" >/dev/null \
    || die "created tab $tab but could not start the topic agent in pane $pane"
  focus_tab "$tab"
  printf 'opened: %s tab %s in %s\n' "$topic" "$tab" "$dir"
  if [ -z "$resume" ]; then
    printf 'new chat: no earlier %s chat is recorded for this folder\n' "$topic"
    return 0
  fi
  outcome=$(await_resume "$tdir" "$pane")
  case "$outcome" in
    resumed) printf 'resumed: the last %s chat %s, with its history\n' "$topic" "$resume" ;;
    failed) printf 'new chat: the last %s chat %s could not be resumed, so a new chat started with the starting note\n' "$topic" "$resume" ;;
    *) printf 'resuming: the last %s chat %s; its start was not confirmed within %ss\n' "$topic" "$resume" "${FM_TOPIC_RESUME_WAIT:-20}" ;;
  esac
}

# cmd_started: the tab's SessionStart hook (see `started` in the header).
cmd_started() {
  local topic tdir meta input id cwd
  [ "$#" -eq 1 ] || exit 0
  topic=$(normalize_topic "$1" 2>/dev/null) || exit 0
  tdir="$TOPICS/$topic"
  meta="$tdir/topic.meta"
  input=$(cat 2>/dev/null) || exit 0
  [ -f "$meta" ] && [ -n "${HERDR_PANE_ID:-}" ] || exit 0
  [ "$HERDR_PANE_ID" = "$(meta_get "$meta" pane_id)" ] || exit 0
  id=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null) || exit 0
  cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null) || exit 0
  valid_chat_id "$id" || exit 0
  [ -n "$cwd" ] && [ "$(real_dir "$cwd")" = "$(meta_get "$meta" dir)" ] || exit 0
  meta_update "$tdir" "agent_session=$id" >/dev/null 2>&1 || exit 0
  printf '%s %s\n' "$HERDR_PANE_ID" "$id" > "$tdir/started.tmp.$$" && mv -f "$tdir/started.tmp.$$" "$tdir/started"
  exit 0
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
  local topic tdir body done_task='' heading
  [ "$#" -ge 2 ] || usage
  topic=$(normalize_topic "$1")
  shift
  heading=$(now_utc)
  while [ "$#" -ge 2 ]; do
    case "$1" in
      --done) [ "$#" -ge 3 ] || usage; done_task=$(normalize_task "$2"); shift 2 ;;
      --decision) heading="$heading - Decision needed"; shift ;;
      *) break ;;
    esac
  done
  tdir="$TOPICS/$topic"
  [ -f "$tdir/topic.meta" ] || die "no topic '$topic' is recorded in $TOPICS; open it first"
  if [ "$1" = - ] && [ "$#" -eq 1 ]; then
    body=$(cat)
  else
    body="$*"
  fi
  [ -n "${body//[[:space:]]/}" ] || die "refusing an empty log entry"
  [ -f "$tdir/log.md" ] || new_log "$topic" "$tdir"
  printf '\n## %s\n\n%s\n' "$heading" "$body" >> "$tdir/log.md"
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
    printf 'Unseen %s topic results from the main firstmate, newest last. Tell the captain these first, in plain words with any links, before anything else; ask the captain each one headed Decision needed:\n\n%s\n' \
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
      printf 'TOPIC RESULT: %s carries a request from the %s topic tab; give that tab each captain-facing outcome too: bin/fm-topic.sh log %s "<outcome>", adding --decision for a question the captain must answer and --done %s with the final one.\n' \
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
  started) shift; (cmd_started "$@") >/dev/null 2>&1; exit 0 ;;
  -h|--help|help) usage ;;
  *) usage ;;
esac

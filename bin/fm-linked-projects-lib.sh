#!/usr/bin/env bash
# shellcheck disable=SC2034 # parsed fields are output globals for sourcing callers.
# Linked projects for local secondmate homes: the manifest parser and the
# containment checks that every seed and rollback step reruns before it touches
# a linked repository. Retirement never removes a linked repository.
#
# A local secondmate home may keep a project repository outside the home, in the
# standard workspace layout <link-root>/<project-dir>/code/<repo>, reached through
# a symlink at <home>/projects/<project>. The home declares its one link root and
# every linked target in the gitignored manifest <home>/config/linked-projects:
#
#   schema=fm-linked-projects.v1
#   link_root=<absolute resolved org directory, such as /home/me/work/mbg>
#   link.<project>=<absolute resolved repository path>
#
# <project> uses only [A-Za-z0-9._-] and is not . or ..; each project appears at
# most once. bin/fm-home-seed.sh is the only writer. A home without the manifest
# has no link root and behaves exactly as an unlinked home. A symlinked,
# NUL-bearing, or malformed manifest is refused rather than read.
#
# A linked target is accepted only when its fully resolved path is exactly
# <link-root>/<one dir>/code/<one dir>, and is not inside, equal to, or an
# ancestor of the firstmate code root, any firstmate home this home can reach
# (the active home, its local parent chain up to the main home, every local home
# registered under any of them, and the secondmate home itself), any other home's
# linked project target, or another project's target in the same home.
# Seed rollback removes only a resolved code/<repo> directory that seed itself
# cloned, plus the projects/<project> link; it never removes code/ itself, the
# project root, README.md, docs/, data/, or sibling repositories.
#
# Callers source bin/fm-secondmate-registry-lib.sh and
# bin/fm-secondmate-parent-lib.sh first; this file reads registries and parent
# bindings through their parsers.

FM_LP_SCHEMA=fm-linked-projects.v1
FM_LP_ROOT=
FM_LP_ENTRIES=
FM_LP_ERROR=
FM_LP_HOME_LIMIT=256

fm_lp_manifest_file() { printf '%s/config/linked-projects\n' "$1"; }

fm_lp_valid_project_name() {
  case "$1" in
    ''|.|..|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# Resolve every existing component of <path> physically and normalize the
# not-yet-existing tail, so a target that will be cloned later resolves to the
# same string it will have once it exists.
fm_lp_canonical() {
  local path=$1 probe tail='' prefix parent base out component old_ifs
  case "$path" in
    /*) probe=$path ;;
    *) probe="$(pwd -P)/$path" ;;
  esac
  while [ "$probe" != "/" ] && [ "${probe%/}" != "$probe" ]; do
    probe=${probe%/}
  done
  while [ ! -e "$probe" ] && [ "$probe" != "/" ]; do
    tail="$(basename "$probe")${tail:+/$tail}"
    probe=$(dirname "$probe")
  done
  if [ -d "$probe" ]; then
    prefix=$(cd "$probe" 2>/dev/null && pwd -P) || return 1
  else
    parent=$(dirname "$probe")
    base=$(basename "$probe")
    prefix=$(cd "$parent" 2>/dev/null && printf '%s/%s\n' "$(pwd -P)" "$base") || return 1
  fi
  out=${prefix%/}
  old_ifs=$IFS
  IFS=/
  for component in $tail; do
    case "$component" in
      ''|.) ;;
      ..) out=${out%/*} ;;
      *) out="$out/$component" ;;
    esac
  done
  IFS=$old_ifs
  [ -n "$out" ] || out=/
  printf '%s\n' "$out"
}

# Resolve where a symlink points without requiring its target to exist, so a
# dangling or retargeted link still reports the path it would redirect to.
fm_lp_link_target() {
  local link=$1 dest
  [ -L "$link" ] || return 1
  dest=$(readlink -- "$link") || return 1
  case "$dest" in
    /*) ;;
    *) dest="$(dirname "$link")/$dest" ;;
  esac
  fm_lp_canonical "$dest"
}

fm_lp_overlaps() {
  local a=$1 b=$2
  [ -n "$a" ] && [ -n "$b" ] || return 1
  [ "$a" = "$b" ] && return 0
  case "$b/" in "$a"/*) return 0 ;; esac
  case "$a/" in "$b"/*) return 0 ;; esac
  return 1
}

# Parse <home>'s manifest into FM_LP_ROOT and FM_LP_ENTRIES ("<project>\t<target>"
# lines). Returns 0 when parsed, 1 when absent, and 2 with FM_LP_ERROR when unsafe
# or malformed.
fm_lp_manifest_read() {
  local home=$1 file line key value project schema='' schema_count=0 root_count=0 seen
  FM_LP_ROOT=
  FM_LP_ENTRIES=
  FM_LP_ERROR=
  file=$(fm_lp_manifest_file "$home")
  if [ -L "$file" ]; then
    FM_LP_ERROR="linked-projects manifest must not be a symlink: $file"
    return 2
  fi
  [ -e "$file" ] || return 1
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    FM_LP_ERROR="linked-projects manifest is not a readable regular file: $file"
    return 2
  fi
  if [ "$(wc -c < "$file")" -ne "$(LC_ALL=C tr -d '\0' < "$file" | wc -c)" ]; then
    FM_LP_ERROR="linked-projects manifest contains NUL bytes: $file"
    return 2
  fi
  seen=
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*) continue ;;
      *=*) ;;
      *)
        FM_LP_ERROR="malformed linked-projects manifest line in $file: $line"
        return 2
        ;;
    esac
    key=${line%%=*}
    value=${line#*=}
    case "$key" in
      schema)
        schema_count=$((schema_count + 1))
        schema=$value
        ;;
      link_root)
        root_count=$((root_count + 1))
        FM_LP_ROOT=$value
        ;;
      link.*)
        project=${key#link.}
        if ! fm_lp_valid_project_name "$project"; then
          FM_LP_ERROR="invalid linked project name in $file: $project"
          return 2
        fi
        case "$value" in
          /*) ;;
          *)
            FM_LP_ERROR="linked project $project target is not absolute in $file: $value"
            return 2
            ;;
        esac
        case "$seen" in
          *"|$project|"*)
            FM_LP_ERROR="duplicate linked project $project in $file"
            return 2
            ;;
        esac
        seen="$seen|$project|"
        FM_LP_ENTRIES="$FM_LP_ENTRIES$project	$value
"
        ;;
      *)
        FM_LP_ERROR="unknown linked-projects manifest field in $file: $key"
        return 2
        ;;
    esac
  done < "$file"
  if [ "$schema_count" -ne 1 ] || [ "$schema" != "$FM_LP_SCHEMA" ]; then
    FM_LP_ERROR="linked-projects manifest has no single $FM_LP_SCHEMA schema line: $file"
    return 2
  fi
  if [ "$root_count" -ne 1 ]; then
    FM_LP_ERROR="linked-projects manifest must declare exactly one link_root: $file"
    return 2
  fi
  case "$FM_LP_ROOT" in
    /*) ;;
    *)
      FM_LP_ERROR="linked-projects link_root is not absolute in $file: $FM_LP_ROOT"
      return 2
      ;;
  esac
  return 0
}

# Print the manifest target recorded for <project> after a successful read.
fm_lp_entry_target() {
  local project=$1 name target
  while IFS='	' read -r name target; do
    [ -n "$name" ] || continue
    if [ "$name" = "$project" ]; then
      printf '%s\n' "$target"
      return 0
    fi
  done <<EOF
$FM_LP_ENTRIES
EOF
  return 1
}

# Write <home>'s manifest atomically from a link root and "<project>\t<target>"
# entry lines.
fm_lp_manifest_write() {
  local home=$1 root=$2 entries=$3 file tmp name target
  file=$(fm_lp_manifest_file "$home")
  if [ -L "$file" ]; then
    echo "error: linked-projects manifest must not be a symlink: $file" >&2
    return 1
  fi
  mkdir -p "$(dirname "$file")" || return 1
  tmp="$file.tmp.$$"
  {
    printf 'schema=%s\n' "$FM_LP_SCHEMA"
    printf 'link_root=%s\n' "$root"
    while IFS='	' read -r name target; do
      [ -n "$name" ] || continue
      printf 'link.%s=%s\n' "$name" "$target"
    done <<EOF
$entries
EOF
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$file"
}

# Validate a declared link root and print its resolved path.
fm_lp_link_root_resolve() {
  local root=$1 abs
  case "$root" in
    /*) ;;
    *) echo "error: link root must be an absolute path: $root" >&2; return 1 ;;
  esac
  if [ ! -d "$root" ]; then
    echo "error: link root does not exist or is not a directory: $root" >&2
    return 1
  fi
  abs=$(cd "$root" && pwd -P) || return 1
  if [ "$abs" = "/" ]; then
    echo "error: link root cannot be the filesystem root: $root" >&2
    return 1
  fi
  printf '%s\n' "$abs"
}

# Print every local firstmate home reachable from <active-home>: the home, its
# local parent chain up to the main home, and every local home registered under
# any of them, recursively. Unreadable registries contribute nothing.
fm_lp_known_homes() {
  local active=$1 home parent queue next line count=0 reg record seen
  home=$(fm_lp_canonical "$active") || return 1
  seen="
$home
"
  queue=$home
  # Walk up the durable local parent bindings to the main home.
  while [ "$count" -lt 32 ]; do
    record="$home/.fm-secondmate-parent"
    fm_secondmate_parent_record_parse "$record" 2>/dev/null || break
    [ "$FM_SECONDMATE_PARENT_ROUTE" = local ] || break
    parent=$(fm_lp_canonical "$FM_SECONDMATE_PARENT_HOME") || break
    case "$seen" in *"
$parent
"*) break ;; esac
    seen="$seen$parent
"
    queue="$queue
$parent"
    home=$parent
    count=$((count + 1))
  done
  # Then walk down every local registry reachable from those homes.
  count=0
  while [ -n "$queue" ] && [ "$count" -lt "$FM_LP_HOME_LIMIT" ]; do
    home=${queue%%
*}
    if [ "$home" = "$queue" ]; then queue=; else queue=${queue#*
}; fi
    [ -n "$home" ] || continue
    printf '%s\n' "$home"
    count=$((count + 1))
    reg="$home/data/secondmates.md"
    [ -f "$reg" ] && [ ! -L "$reg" ] || continue
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in "- "*) ;; *) continue ;; esac
      secondmate_registry_parse_line "$line" || continue
      [ "$SECONDMATE_REGISTRY_REMOTE" -eq 0 ] || continue
      case "$SECONDMATE_REGISTRY_HOME" in /*) ;; *) continue ;; esac
      next=$(fm_lp_canonical "$SECONDMATE_REGISTRY_HOME") || continue
      case "$seen" in *"
$next
"*) continue ;; esac
      seen="$seen$next
"
      queue="$queue${queue:+
}$next"
    done < "$reg"
  done
}

# Print "<label>\t<path>" for every path a linked target of <self-home> must not
# overlap: the firstmate code root, each reachable home and the self home, and
# every linked target of any other reachable home.
fm_lp_protected_paths() {
  local active=$1 fm_root=$2 self=$3 home entry dest name target
  printf 'the firstmate code root\t%s\n' "$(fm_lp_canonical "$fm_root")"
  printf 'the secondmate home itself\t%s\n' "$self"
  while IFS= read -r home; do
    [ -n "$home" ] || continue
    printf 'firstmate home\t%s\n' "$home"
    [ "$home" != "$self" ] || continue
    for entry in "$home/projects"/* "$home/projects"/.[!.]* "$home/projects"/..?*; do
      [ -L "$entry" ] || continue
      dest=$(fm_lp_link_target "$entry") || continue
      printf 'linked project of firstmate home %s\t%s\n' "$home" "$dest"
    done
    if fm_lp_manifest_read "$home" 2>/dev/null; then
      while IFS='	' read -r name target; do
        [ -n "$name" ] || continue
        printf 'linked project of firstmate home %s\t%s\n' "$home" "$(fm_lp_canonical "$target")"
      done <<EOF
$FM_LP_ENTRIES
EOF
    fi
  done <<EOF
$(fm_lp_known_homes "$active")
EOF
}

# Validate a linked target for <project> in <self-home> and print its resolved
# path. Arguments: <active-home> <firstmate-code-root> <self-home> <link-root>
# <project> <target>. Every refusal names the rule it enforces.
fm_lp_check_target() {
  local active=$1 fm_root=$2 self_in=$3 root_in=$4 project=$5 target_in=$6
  local self root target rel pdir mid repo label path protected name other
  case "$target_in" in
    /*) ;;
    *) echo "error: linked project $project target must be an absolute path: $target_in" >&2; return 1 ;;
  esac
  self=$(fm_lp_canonical "$self_in") || { echo "error: cannot resolve secondmate home $self_in" >&2; return 1; }
  root=$(fm_lp_link_root_resolve "$root_in") || return 1
  target=$(fm_lp_canonical "$target_in") || { echo "error: cannot resolve linked project $project target $target_in" >&2; return 1; }
  case "$target" in
    "$root"/*) rel=${target#"$root"/} ;;
    *)
      echo "error: linked project $project target $target is outside the link root $root" >&2
      return 1
      ;;
  esac
  pdir=${rel%%/*}
  mid=${rel#*/}
  repo=${mid#*/}
  mid=${mid%%/*}
  case "$rel" in
    */*/*/*|*//*|/*|*/) pdir= ;;
  esac
  if [ -z "$pdir" ] || [ "$mid" != code ] || [ -z "$repo" ] || [ "$rel" != "$pdir/code/$repo" ]; then
    echo "error: linked project $project target $target must have the shape $root/<project-dir>/code/<repo>" >&2
    return 1
  fi
  protected=$(fm_lp_protected_paths "$active" "$fm_root" "$self") || {
    echo "error: cannot determine the firstmate homes linked project $project must avoid" >&2
    return 1
  }
  while IFS='	' read -r label path; do
    [ -n "$path" ] || continue
    if fm_lp_overlaps "$target" "$path"; then
      echo "error: linked project $project target $target overlaps $label $path" >&2
      return 1
    fi
  done <<EOF
$protected
EOF
  if fm_lp_manifest_read "$self" 2>/dev/null; then
    while IFS='	' read -r name other; do
      [ -n "$name" ] || continue
      [ "$name" != "$project" ] || continue
      if fm_lp_overlaps "$target" "$(fm_lp_canonical "$other")"; then
        echo "error: linked project $project target $target is already linked as project $name in $self" >&2
        return 1
      fi
    done <<EOF
$FM_LP_ENTRIES
EOF
  fi
  printf '%s\n' "$target"
}

#!/usr/bin/env bash
# Propose a clone's forge binding from its origin remote, for project-add intake.
# Prints exactly one line to stdout:
#   forge=gerrit evidence=<the protocol fact that suggests it>
#   forge=azure-devops evidence=<the origin remote whose host is Azure DevOps>
#   forge=none
# and exits 0 either way; a missing clone or a directory that is not a git work
# tree exits 2 with an error on stderr.
#
# PROPOSAL ONLY. This never writes the registry and no use-time path calls it:
# the captain's confirmation at intake is what binds the forge, and
# data/projects.md holds that answer as `forge=gerrit` or `forge=azure-devops`,
# which bin/fm-project-mode.sh owns (docs/gerrit-forge-integration.md section 3).
# A confirmed record exists because detection can be wrong, so nothing re-derives
# the binding from the clone later.
#
# Evidence read, all from the clone's own git config and never from the network:
#   - an origin fetch or push URL on SSH port 29418, Gerrit's default SSH port;
#   - an origin push refspec targeting refs/for/, Gerrit's change-creating ref;
#   - an origin fetch or push URL whose host is Azure DevOps's own: dev.azure.com
#     or ssh.dev.azure.com, or a legacy <organization>.visualstudio.com or
#     vs-ssh.visualstudio.com, in URL or scp-like form. Azure DevOps runs only
#     on those hosts, so the host is the protocol fact here.
# Gerrit's facts are checked first. Anything else proposes none. A Gerrit server
# on a non-default port behind an HTTPS remote carries neither fact, which is
# why the captain is asked rather than told.
# Usage: fm-forge-detect.sh <clone-dir>
set -eu

DIR=${1:?usage: fm-forge-detect.sh <clone-dir>}
if [ ! -d "$DIR" ] || ! git -C "$DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "error: $DIR is not a git work tree" >&2
  exit 2
fi

urls=$( { git -C "$DIR" config --get-all remote.origin.url || true
  git -C "$DIR" config --get-all remote.origin.pushurl || true; } 2>/dev/null)
while IFS= read -r url; do
  [ -n "$url" ] || continue
  case "$url" in
    ssh://*)
      authority=${url#ssh://}
      authority=${authority%%/*}
      case "$authority" in
        *:29418)
          printf 'forge=gerrit evidence=origin remote %s uses SSH port 29418\n' "$url"
          exit 0
          ;;
      esac
      ;;
  esac
done <<EOF
$urls
EOF

refspecs=$(git -C "$DIR" config --get-all remote.origin.push 2>/dev/null || true)
while IFS= read -r refspec; do
  case "$refspec" in
    *:refs/for/*)
      printf 'forge=gerrit evidence=origin push refspec %s targets refs/for/\n' "$refspec"
      exit 0
      ;;
  esac
done <<EOF
$refspecs
EOF

# The host of a remote URL, lowercased: after any scheme and userinfo, before
# any port or path. An scp-like "user@host:path" remote has no scheme, and its
# host ends at the first ":".
remote_host() {  # <url>
  local rest=$1
  case "$rest" in
    *://*) rest=${rest#*://}; rest=${rest%%/*}; rest=${rest##*@}; rest=${rest%%:*} ;;
    *:*) rest=${rest%%:*}; rest=${rest##*@} ;;
    *) return 1 ;;
  esac
  printf '%s\n' "$rest" | tr '[:upper:]' '[:lower:]'
}

# A remote URL with any userinfo removed, so evidence never echoes a
# credential an HTTPS remote may carry (https://user:token@host/...).
remote_without_userinfo() {  # <url>
  local url=$1 scheme rest authority
  case "$url" in
    *://*)
      scheme=${url%%://*}
      rest=${url#*://}
      authority=${rest%%/*}
      case "$rest" in */*) rest=/${rest#*/} ;; *) rest= ;; esac
      printf '%s://%s%s\n' "$scheme" "${authority##*@}" "$rest"
      ;;
    *) printf '%s\n' "${url#*@}" ;;
  esac
}

while IFS= read -r url; do
  [ -n "$url" ] || continue
  host=$(remote_host "$url") || continue
  case "$host" in
    dev.azure.com|ssh.dev.azure.com|*.visualstudio.com)
      printf 'forge=azure-devops evidence=origin remote %s is hosted on Azure DevOps (%s)\n' \
        "$(remote_without_userinfo "$url")" "$host"
      exit 0
      ;;
  esac
done <<EOF
$urls
EOF

printf 'forge=none\n'

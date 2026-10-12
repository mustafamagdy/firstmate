#!/usr/bin/env bash
# bin/fm-forge-detect.sh proposes a clone's forge binding at project-add intake
# from protocol facts in its own git config, and never records anything.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity fmtest fmtest@example.invalid

TMP_ROOT=$(fm_test_tmproot fm-forge-detect-tests)
DETECT="$ROOT/bin/fm-forge-detect.sh"

new_clone() {  # <name>
  local dir="$TMP_ROOT/$1"
  git init -q "$dir"
  printf '%s\n' "$dir"
}

test_ssh_port_29418_proposes_gerrit() {
  local clone out
  clone=$(new_clone ssh-port)
  git -C "$clone" remote add origin ssh://someone@review.example:29418/group/apps/console
  out=$("$DETECT" "$clone") || fail "detection failed on a clone with an origin"
  case "$out" in
    'forge=gerrit evidence='*'29418'*) ;;
    *) fail "an origin on SSH port 29418 did not propose gerrit with its evidence: $out" ;;
  esac
  pass "an origin on SSH port 29418 proposes forge=gerrit and names the evidence"
}

test_refs_for_push_refspec_proposes_gerrit() {
  local clone out
  clone=$(new_clone refs-for)
  git -C "$clone" remote add origin https://review.example/group/apps/console
  git -C "$clone" config --add remote.origin.push 'HEAD:refs/for/master'
  out=$("$DETECT" "$clone") || fail "detection failed on a clone with a push refspec"
  case "$out" in
    'forge=gerrit evidence='*'refs/for/'*) ;;
    *) fail "a refs/for push refspec did not propose gerrit with its evidence: $out" ;;
  esac
  pass "a refs/for/ push refspec proposes forge=gerrit and names the evidence"
}

test_other_remotes_propose_none() {
  local clone out
  clone=$(new_clone github)
  git -C "$clone" remote add origin git@github.com:owner/repo.git
  out=$("$DETECT" "$clone") || fail "detection failed on a GitHub clone"
  [ "$out" = forge=none ] || fail "a GitHub origin proposed a forge: $out"

  clone=$(new_clone other-port)
  git -C "$clone" remote add origin ssh://git@gitlab.example:2222/group/project.git
  out=$("$DETECT" "$clone") || fail "detection failed on a non-Gerrit SSH port"
  [ "$out" = forge=none ] || fail "an SSH origin on another port proposed a forge: $out"

  # Port 29418 in the path is not the SSH port, so it is not evidence.
  clone=$(new_clone port-in-path)
  git -C "$clone" remote add origin ssh://git@host.example/29418/project.git
  out=$("$DETECT" "$clone") || fail "detection failed on a path containing 29418"
  [ "$out" = forge=none ] || fail "29418 in the path was read as the SSH port: $out"

  clone=$(new_clone no-origin)
  out=$("$DETECT" "$clone") || fail "detection failed on a clone with no origin"
  [ "$out" = forge=none ] || fail "a clone with no origin proposed a forge: $out"
  pass "a remote carrying neither Gerrit fact proposes forge=none"
}

test_detection_writes_nothing() {
  local clone before after
  clone=$(new_clone read-only)
  git -C "$clone" remote add origin ssh://someone@review.example:29418/proj
  before=$(git -C "$clone" config --list --local | LC_ALL=C sort)
  "$DETECT" "$clone" >/dev/null || fail "detection failed"
  after=$(git -C "$clone" config --list --local | LC_ALL=C sort)
  [ "$before" = "$after" ] || fail "detection changed the clone's git config"
  pass "detection reads the clone's config and changes nothing"
}

test_azure_devops_remotes_propose_azure_devops() {
  local clone out url host
  while IFS='|' read -r url host; do
    [ -n "$url" ] || continue
    clone=$(new_clone "azure-$host-$RANDOM")
    git -C "$clone" remote add origin "$url"
    out=$("$DETECT" "$clone") || fail "detection failed on an Azure DevOps clone"
    case "$out" in
      "forge=azure-devops evidence="*"($host)") ;;
      *) fail "an Azure DevOps origin $url did not propose azure-devops with its host: $out" ;;
    esac
  done <<'EOF'
https://match-best@dev.azure.com/match-best/xelta-v2/_git/api|dev.azure.com
git@ssh.dev.azure.com:v3/match-best/xelta-v2/api|ssh.dev.azure.com
ssh://git@ssh.dev.azure.com/v3/match-best/xelta-v2/api|ssh.dev.azure.com
https://Contoso.VisualStudio.com/Proj/_git/repo|contoso.visualstudio.com
contoso@vs-ssh.visualstudio.com:v3/contoso/Proj/repo|vs-ssh.visualstudio.com
EOF

  # A credential embedded in an HTTPS remote never reaches the evidence line.
  clone=$(new_clone azure-credential)
  git -C "$clone" remote add origin https://user:s3cr3t-token@dev.azure.com/org/proj/_git/repo
  out=$("$DETECT" "$clone") || fail "detection failed on a credentialed Azure DevOps remote"
  assert_not_contains "$out" s3cr3t-token "the evidence line echoed a remote credential"
  assert_contains "$out" 'https://dev.azure.com/org/proj/_git/repo' "the evidence line did not name the remote"

  # A look-alike host is not Azure DevOps.
  clone=$(new_clone azure-lookalike)
  git -C "$clone" remote add origin https://dev.azure.com.example/org/proj/_git/repo
  out=$("$DETECT" "$clone") || fail "detection failed on a look-alike host"
  [ "$out" = forge=none ] || fail "a look-alike host proposed a forge: $out"
  pass "an Azure DevOps origin proposes forge=azure-devops and never echoes a credential"
}

test_not_a_clone_is_an_error() {
  local out rc
  mkdir -p "$TMP_ROOT/plain-dir"
  out=$("$DETECT" "$TMP_ROOT/plain-dir" 2>&1)
  rc=$?
  [ "$rc" -eq 2 ] || fail "a plain directory did not exit 2 (got $rc)"
  assert_contains "$out" "not a git work tree" "the error did not say why"
  pass "a directory that is not a git work tree is refused with exit 2"
}

test_ssh_port_29418_proposes_gerrit
test_refs_for_push_refspec_proposes_gerrit
test_other_remotes_propose_none
test_azure_devops_remotes_propose_azure_devops
test_detection_writes_nothing
test_not_a_clone_is_an_error
echo "# all fm-forge-detect tests passed"

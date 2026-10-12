#!/usr/bin/env bash
# tests/fm-secondmate-linked-projects.test.sh - linked projects for local
# secondmate homes: seeding a projects/<project> link to a repository in the
# <link-root>/<project-dir>/code/[<group>/]<repo> workspace layout (new clone and
# adopt, grouped and ungrouped), every containment refusal, rollback removing
# only a cloned repository directory, symlink retargeting between seed and
# rollback, retirement leaving every linked repository in place, consumers that
# work through the link, the product context in generated briefs, and unchanged
# behavior for a home with no link root.
set -u

# shellcheck source=tests/secondmate-helpers.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/secondmate-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-secondmate-linked-projects)
export FM_BACKEND=tmux
fm_git_identity

W=
MAIN=
ORG=
FAKE=
LOG=

# A fresh world: a main home with registered direct-PR (alpha, beta) and
# no-mistakes (gamma) projects, and an org directory in the standard layout.
new_world() {
  W="$TMP_ROOT/$1"
  MAIN="$W/main home"
  ORG="$W/work/mbg"
  mkdir -p "$MAIN/projects" "$MAIN/data" "$MAIN/state" "$ORG"
  local p
  for p in alpha beta gamma; do
    fm_git_init_commit "$MAIN/projects/$p"
    fm_git_add_origin "$MAIN/projects/$p" "$W/remotes/$p.git"
  done
  cat > "$MAIN/data/projects.md" <<'EOF'
- alpha [direct-PR] - alpha project (added 2026-10-01)
- beta [direct-PR] - beta project (added 2026-10-01)
- gamma - gamma project (added 2026-10-01)
EOF
  FAKE=$(make_fake_tmux "$W/fake")
  make_recording_no_mistakes "$W/fake" >/dev/null
  LOG="$W/fake/tmux.log"
  : > "$W/no-mistakes.log"
}

# <project-dir>: README.md, docs/, data/, and a sibling repo under code/.
make_org_project() {
  local dir="$ORG/$1"
  mkdir -p "$dir/docs" "$dir/data" "$dir/code"
  printf '# %s\n' "$1" > "$dir/README.md"
  printf 'design notes\n' > "$dir/docs/notes.md"
  printf 'working data\n' > "$dir/data/records.csv"
  fm_git_init_commit "$dir/code/sibling"
}

assert_org_project_intact() {  # <project-dir> <context>
  local dir="$ORG/$1"
  assert_present "$dir/README.md" "$2 removed the project README.md"
  assert_present "$dir/docs/notes.md" "$2 removed the project docs/"
  assert_present "$dir/data/records.csv" "$2 removed the project data/"
  assert_present "$dir/code" "$2 removed the project code/ folder"
  assert_present "$dir/code/sibling/.git" "$2 removed a sibling repo under code/"
}

seed() {
  PATH="$FAKE:$PATH" FM_HOME="$MAIN" FM_SECONDMATE_CHARTER='linked domain' \
    FM_FAKE_NO_MISTAKES_LOG="$W/no-mistakes.log" "$ROOT/bin/fm-home-seed.sh" "$@"
}

retire() {  # <id> [--force]
  PATH="$FAKE:$PATH" FM_HOME="$MAIN" FM_FAKE_TMUX_LOG="$LOG" FM_FAKE_TMUX_CAPTURE="$W/fake/pane.txt" \
    "$ROOT/bin/fm-teardown.sh" "$@"
}

register_meta() {  # <id> <home>
  fm_write_secondmate_meta "$MAIN/state/$1.meta" "$2" "firstmate:fm-$1" alpha
}

# --- seeding ----------------------------------------------------------------

test_seed_links_new_clone_and_consumers_work_through_it() {
  local sub target out
  new_world seed-new
  make_org_project alpha-proj
  sub="$W/sub"
  target="$ORG/alpha-proj/code/alpha"
  out=$(seed design "$sub" --link-root "$ORG" "alpha=$target" beta 2>&1) || fail "linked seed failed: $out"
  [ -L "$sub/projects/alpha" ] || fail "linked seed did not create the projects/alpha link"
  [ "$(cd "$sub/projects/alpha" && pwd -P)" = "$(cd "$target" && pwd -P)" ] || fail "projects/alpha does not resolve to the linked target"
  [ "$(git -C "$target" remote get-url origin)" = "$(git -C "$MAIN/projects/alpha" remote get-url origin)" ] \
    || fail "linked clone did not keep the project's origin"
  [ -d "$sub/projects/beta/.git" ] && [ ! -L "$sub/projects/beta" ] || fail "an unlinked project was not cloned into the home"
  assert_grep "link_root=$(cd "$ORG" && pwd -P)" "$sub/config/linked-projects" "manifest did not record the link root"
  assert_grep "link.alpha=$(cd "$target" && pwd -P)" "$sub/config/linked-projects" "manifest did not record the linked target"
  assert_no_grep 'link.beta' "$sub/config/linked-projects" "manifest recorded an unlinked project"
  assert_grep '- alpha [direct-PR] - alpha project' "$sub/data/projects.md" "linked project registry entry changed"
  assert_grep 'projects: alpha, beta' "$MAIN/data/secondmates.md" "route did not list the linked project"
  assert_org_project_intact alpha-proj "linked seed"
  FM_HOME="$MAIN" "$ROOT/bin/fm-home-seed.sh" validate >/dev/null || fail "registry validation failed for a linked home"

  # Fleet sync acts on the linked repository itself, not the enclosing home.
  out=$(FM_HOME="$sub" "$ROOT/bin/fm-fleet-sync.sh" alpha 2>&1)
  assert_not_contains "$out" "not a clone root" "fleet sync refused the linked project: $out"
  assert_not_contains "$out" "not a git repo" "fleet sync did not see the linked repository: $out"
  # The pool-slot classifier matches a worktree of the linked repo through the link.
  git -C "$target" worktree add --quiet --detach "$W/pool/slot-1/alpha" HEAD
  printf '{}\n' > "$W/pool/treehouse-state.json"
  bash -c '. "$1"; fm_treehouse_pool_slot "$2" "$3"' _ "$ROOT/bin/fm-wake-lib.sh" "$sub/projects/alpha" "$W/pool/slot-1/alpha" \
    || fail "pool-slot classification did not follow the projects/alpha link"
  git -C "$target" worktree remove --force "$W/pool/slot-1/alpha"
  pass "seed links a new clone in code/<repo>; validate, fleet sync, and pool slots work through the link"
}

test_seed_adopts_existing_target_only_with_matching_origin() {
  local sub target err
  new_world seed-adopt
  make_org_project alpha-proj
  target="$ORG/alpha-proj/code/alpha"
  git clone --quiet "$(git -C "$MAIN/projects/alpha" remote get-url origin)" "$target"
  printf 'local scratch\n' > "$target/.git/fm-adopt-marker"
  sub="$W/sub"
  seed design "$sub" --link-root "$ORG" "alpha=$target" >/dev/null 2>&1 || fail "seed did not adopt a matching existing target"
  assert_present "$target/.git/fm-adopt-marker" "adoption replaced the existing repository"
  [ -L "$sub/projects/alpha" ] || fail "adoption did not create the link"

  new_world seed-adopt-mismatch
  make_org_project alpha-proj
  target="$ORG/alpha-proj/code/alpha"
  fm_git_init_commit "$target"
  git -C "$target" remote add origin "file://$W/elsewhere.git"
  sub="$W/sub"
  err="$W/seed.err"
  if seed design "$sub" --link-root "$ORG" "alpha=$target" >/dev/null 2>"$err"; then
    fail "seed adopted a target whose origin does not match"
  fi
  assert_grep 'has origin' "$err" "origin mismatch refusal did not name the origin"
  assert_present "$target/.git" "origin mismatch refusal removed the existing repository"
  assert_absent "$sub" "origin mismatch refusal left the created home behind"
  assert_org_project_intact alpha-proj "origin mismatch refusal"
  pass "seed adopts an existing target only when its origin matches and never removes it"
}

# One product whose repositories are grouped under code/<group>/ next to an
# ungrouped one: a grouped clone, a grouped adopt, and an ungrouped clone.
test_seed_links_grouped_and_ungrouped_repos_of_one_product() {
  local sub clone adopted plain out
  new_world seed-grouped
  make_org_project xelta
  mkdir -p "$ORG/xelta/code/enterprise" "$ORG/xelta/code/v1-b2b"
  fm_git_init_commit "$ORG/xelta/code/enterprise/sibling"
  clone="$ORG/xelta/code/enterprise/alpha"
  adopted="$ORG/xelta/code/v1-b2b/beta"
  plain="$ORG/xelta/code/gamma"
  git clone --quiet "$(git -C "$MAIN/projects/beta" remote get-url origin)" "$adopted"
  printf 'local scratch\n' > "$adopted/.git/fm-adopt-marker"
  sub="$W/sub"
  out=$(seed design "$sub" --link-root "$ORG" "alpha=$clone" "beta=$adopted" "gamma=$plain" 2>&1) \
    || fail "grouped linked seed failed: $out"
  [ "$(cd "$sub/projects/alpha" && pwd -P)" = "$(cd "$clone" && pwd -P)" ] || fail "projects/alpha does not resolve to the grouped clone"
  [ "$(git -C "$clone" remote get-url origin)" = "$(git -C "$MAIN/projects/alpha" remote get-url origin)" ] \
    || fail "grouped clone did not keep the project's origin"
  [ "$(cd "$sub/projects/beta" && pwd -P)" = "$(cd "$adopted" && pwd -P)" ] || fail "projects/beta does not resolve to the grouped adopted repo"
  assert_present "$adopted/.git/fm-adopt-marker" "grouped adoption replaced the existing repository"
  [ "$(cd "$sub/projects/gamma" && pwd -P)" = "$(cd "$plain" && pwd -P)" ] || fail "projects/gamma does not resolve to the ungrouped clone"
  assert_grep "link.alpha=$(cd "$clone" && pwd -P)" "$sub/config/linked-projects" "manifest did not record the grouped clone"
  assert_grep "link.beta=$(cd "$adopted" && pwd -P)" "$sub/config/linked-projects" "manifest did not record the grouped adopt"
  assert_grep "link.gamma=$(cd "$plain" && pwd -P)" "$sub/config/linked-projects" "manifest did not record the ungrouped clone"
  assert_present "$ORG/xelta/code/enterprise/sibling/.git" "grouped seed disturbed a sibling in the group"
  assert_org_project_intact xelta "grouped seed"
  FM_HOME="$MAIN" "$ROOT/bin/fm-home-seed.sh" validate >/dev/null || fail "registry validation failed for a grouped linked home"
  pass "seed links grouped clones, grouped adopts, and ungrouped repos of one product in one home"
}

test_seed_refuses_group_and_repo_overlap() {
  local other
  new_world group-overlap
  make_org_project xelta
  mkdir -p "$ORG/xelta/code/enterprise"
  # In one home: a repository in the group, then the group itself as a repository.
  expect_seed_refusal "a group directory linked next to a repository inside it" "already linked as project alpha" \
    --link-root "$ORG" "alpha=$ORG/xelta/code/enterprise/alpha" "beta=$ORG/xelta/code/enterprise"
  assert_absent "$ORG/xelta/code/enterprise/alpha" "a refused overlapping seed left its clone"
  assert_present "$ORG/xelta/code/enterprise" "a refused overlapping seed removed the group directory"
  # Across homes, in both directions.
  other="$W/other-sub"
  seed other "$other" --link-root "$ORG" "alpha=$ORG/xelta/code/enterprise/alpha" >/dev/null 2>&1 \
    || fail "could not seed the grouped linked secondmate"
  expect_seed_refusal "a group directory whose repository another home links" "linked project of firstmate home" \
    --link-root "$ORG" "beta=$ORG/xelta/code/enterprise"
  mkdir -p "$ORG/xelta/code/platform"
  seed other "$other" --link-root "$ORG" "beta=$ORG/xelta/code/platform" >/dev/null 2>&1 \
    && fail "seed linked a plain group directory as a repository"
  rm -rf "$W/third-sub"
  git clone --quiet "$(git -C "$MAIN/projects/beta" remote get-url origin)" "$ORG/xelta/code/platform-repo"
  seed third "$W/third-sub" --link-root "$ORG" "beta=$ORG/xelta/code/platform-repo" >/dev/null 2>&1 \
    || fail "could not seed the home that links a repository as code/<repo>"
  expect_seed_refusal "a grouped target inside another home's linked repository" "linked project of firstmate home" \
    --link-root "$ORG" "gamma=$ORG/xelta/code/platform-repo/gamma"
  assert_org_project_intact xelta "group overlap refusals"
  pass "seed refuses a group directory and a repository inside it being linked together, in one home or across homes"
}

# Seed once and expect a refusal naming <pattern>, with the target untouched.
expect_seed_refusal() {  # <label> <pattern> <seed args...>
  local label=$1 pattern=$2 err="$W/refusal.err" sub="$W/refused-sub"
  shift 2
  rm -rf "$sub"
  if seed refused "$sub" "$@" >/dev/null 2>"$err"; then
    fail "seed accepted $label"
  fi
  grep -F -- "$pattern" "$err" >/dev/null || fail "$label refusal did not say '$pattern': $(cat "$err")"
  assert_absent "$sub" "$label refusal left the created home behind"
  if [ -f "$MAIN/data/secondmates.md" ]; then
    assert_no_grep '- refused ' "$MAIN/data/secondmates.md" "$label refusal registered the route"
  fi
}

test_seed_refuses_every_containment_violation() {
  local other other_target code_root
  new_world refusals
  make_org_project alpha-proj

  expect_seed_refusal "a linked project without a link root" "need a link root" \
    "alpha=$ORG/alpha-proj/code/alpha"
  expect_seed_refusal "a relative repository path" "must be absolute" \
    --link-root "$ORG" "alpha=work/mbg/alpha-proj/code/alpha"
  mkdir -p "$W/outside/p/code"
  expect_seed_refusal "a target outside the link root" "outside the link root" \
    --link-root "$ORG" "alpha=$W/outside/p/code/alpha"
  expect_seed_refusal "a target without a code/ folder" "must have the shape" \
    --link-root "$ORG" "alpha=$ORG/alpha-proj/alpha"
  expect_seed_refusal "a target that is the code/ folder" "must have the shape" \
    --link-root "$ORG" "alpha=$ORG/alpha-proj/code"
  expect_seed_refusal "a target two group levels below code/" "must have the shape" \
    --link-root "$ORG" "alpha=$ORG/alpha-proj/code/g1/g2/alpha"
  expect_seed_refusal "a target nested below code/<group>/<repo>" "must have the shape" \
    --link-root "$ORG" "alpha=$ORG/alpha-proj/code/g1/alpha/deeper"
  expect_seed_refusal "a target inside an existing repository under code/" "a group directory must not be a repository" \
    --link-root "$ORG" "alpha=$ORG/alpha-proj/code/sibling/alpha"
  expect_seed_refusal "a missing group directory" "needs the existing code folder" \
    --link-root "$ORG" "alpha=$ORG/alpha-proj/code/new-group/alpha"
  assert_absent "$ORG/alpha-proj/code/new-group" "seed created a group directory"
  expect_seed_refusal "the project root itself" "must have the shape" \
    --link-root "$ORG" "alpha=$ORG/alpha-proj"
  expect_seed_refusal "a target escaping through .." "outside the link root" \
    --link-root "$ORG" "alpha=$ORG/alpha-proj/code/../../../escape/code/alpha"
  ln -s "$W/outside/p" "$ORG/sneaky"
  expect_seed_refusal "a target reached through a symlinked project dir" "outside the link root" \
    --link-root "$ORG" "alpha=$ORG/sneaky/code/alpha"
  expect_seed_refusal "a missing code/ folder" "needs the existing code folder" \
    --link-root "$ORG" "alpha=$ORG/new-proj/code/alpha"
  assert_absent "$ORG/new-proj" "seed created a project root for a missing code/ folder"

  # Another registered secondmate home equal to, containing, or inside the target.
  mkdir -p "$ORG/o/code" "$ORG/q/code/r" "$ORG/s/code"
  mark_firstmate_home "$ORG/o/code/other-home"
  mark_firstmate_home "$ORG/q/code/r/nested-home"
  mark_firstmate_home "$ORG/s"
  cat > "$MAIN/data/secondmates.md" <<EOF
- other - other domain (home: $ORG/o/code/other-home; scope: other; projects: beta; added 2026-10-01)
- nested - nested domain (home: $ORG/q/code/r/nested-home; scope: nested; projects: beta; added 2026-10-01)
- inproj - project domain (home: $ORG/s; scope: inproj; projects: beta; added 2026-10-01)
EOF
  expect_seed_refusal "another secondmate home as the target" "overlaps firstmate home" \
    --link-root "$ORG" "alpha=$ORG/o/code/other-home"
  expect_seed_refusal "a target that contains another secondmate home" "overlaps firstmate home" \
    --link-root "$ORG" "alpha=$ORG/q/code/r"
  expect_seed_refusal "a target inside another secondmate home" "overlaps firstmate home" \
    --link-root "$ORG" "alpha=$ORG/s/code/t"
  rm -f "$MAIN/data/secondmates.md"

  # Another secondmate's linked target, and the main home's own linked project.
  other="$W/other-sub"
  other_target="$ORG/alpha-proj/code/alpha"
  seed other "$other" --link-root "$ORG" "alpha=$other_target" >/dev/null 2>&1 || fail "could not seed the other linked secondmate"
  expect_seed_refusal "another secondmate's linked target" "linked project of firstmate home" \
    --link-root "$ORG" "alpha=$other_target"
  make_org_project beta-proj
  git clone --quiet "$(git -C "$MAIN/projects/beta" remote get-url origin)" "$ORG/beta-proj/code/beta"
  mv "$MAIN/projects/beta" "$W/beta-source"
  ln -s "$ORG/beta-proj/code/beta" "$MAIN/projects/beta"
  expect_seed_refusal "the main home's own linked project" "linked project of firstmate home" \
    --link-root "$ORG" "beta=$ORG/beta-proj/code/beta"
  rm -f "$MAIN/projects/beta"
  mv "$W/beta-source" "$MAIN/projects/beta"

  # A home that already declares a different link root keeps it.
  mkdir -p "$W/other-org"
  if seed other "$other" --link-root "$W/other-org" "alpha=$other_target" >/dev/null 2>"$W/root-change.err"; then
    fail "seed changed an existing home's link root"
  fi
  assert_grep 'already declares link root' "$W/root-change.err" "link-root change refusal was not explained"
  assert_grep "link_root=$(cd "$ORG" && pwd -P)" "$other/config/linked-projects" "refused link-root change rewrote the manifest"
  assert_present "$other_target/.git" "refused link-root change removed the other home's linked repository"

  # The main home itself, and the firstmate code root, placed in the layout.
  make_org_project fm
  mv "$MAIN" "$ORG/fm/code/main-home"
  MAIN="$ORG/fm/code/main-home"
  expect_seed_refusal "the active (main) home as the target" "overlaps firstmate home" \
    --link-root "$ORG" "beta=$ORG/fm/code/main-home"
  code_root="$ORG/fm/code/fm-root"
  git clone --quiet "$ROOT" "$code_root"
  if PATH="$FAKE:$PATH" FM_HOME="$MAIN" FM_ROOT_OVERRIDE="$code_root" FM_SECONDMATE_CHARTER='linked domain' \
    "$ROOT/bin/fm-home-seed.sh" refused "$W/refused-sub" --link-root "$ORG" "beta=$code_root" >/dev/null 2>"$W/root.err"; then
    fail "seed accepted the firstmate code root as a linked target"
  fi
  assert_grep 'overlaps the firstmate code root' "$W/root.err" "code-root refusal did not name the code root"
  assert_present "$code_root/AGENTS.md" "code-root refusal touched the firstmate code root"

  assert_org_project_intact alpha-proj "containment refusals"
  pass "seed refuses targets outside the root, off-shape, missing code/ or group, or overlapping any home, code root, or linked target"
}

# --- rollback -----------------------------------------------------------------

test_rollback_removes_only_the_cloned_code_repo() {
  local sub new_target adopted
  new_world rollback
  make_org_project alpha-proj
  make_org_project gamma-proj
  new_target="$ORG/gamma-proj/code/gamma"
  adopted="$ORG/alpha-proj/code/alpha"
  git clone --quiet "$(git -C "$MAIN/projects/alpha" remote get-url origin)" "$adopted"
  sub="$W/sub"
  mark_firstmate_home "$sub"
  # gamma is no-mistakes, so its fresh linked clone is initialized; fail that step.
  if FM_FAKE_NO_MISTAKES_FAIL_PROJECT=gamma seed design "$sub" --link-root "$ORG" \
    "alpha=$adopted" "gamma=$new_target" >/dev/null 2>"$W/rollback.err"; then
    fail "seed succeeded although no-mistakes initialization failed"
  fi
  assert_grep "$(cd "$ORG" && pwd -P)/gamma-proj/code/gamma" "$W/no-mistakes.log" "no-mistakes did not run in the linked clone"
  assert_absent "$new_target" "rollback left the cloned linked repository"
  assert_present "$adopted/.git" "rollback removed an adopted linked repository"
  [ ! -L "$sub/projects/alpha" ] && [ ! -L "$sub/projects/gamma" ] || fail "rollback left a created link"
  assert_absent "$sub/config/linked-projects" "rollback left the manifest it created"
  assert_present "$sub/AGENTS.md" "rollback removed the preexisting home"
  assert_org_project_intact alpha-proj "rollback"
  assert_org_project_intact gamma-proj "rollback"
  pass "rollback removes only the cloned code/<repo> and its link; adopted repos and project folders survive"
}

test_rollback_keeps_the_group_and_its_siblings() {
  local sub new_target
  new_world rollback-grouped
  make_org_project xelta
  mkdir -p "$ORG/xelta/code/enterprise"
  fm_git_init_commit "$ORG/xelta/code/enterprise/sibling"
  new_target="$ORG/xelta/code/enterprise/gamma"
  sub="$W/sub"
  mark_firstmate_home "$sub"
  if FM_FAKE_NO_MISTAKES_FAIL_PROJECT=gamma seed design "$sub" --link-root "$ORG" "gamma=$new_target" >/dev/null 2>"$W/rollback.err"; then
    fail "seed succeeded although no-mistakes initialization failed"
  fi
  assert_absent "$new_target" "rollback left the grouped cloned repository"
  [ ! -L "$sub/projects/gamma" ] || fail "rollback left the grouped link"
  assert_present "$ORG/xelta/code/enterprise" "rollback removed the group directory"
  assert_present "$ORG/xelta/code/enterprise/sibling/.git" "rollback removed a sibling repository in the group"
  assert_org_project_intact xelta "grouped rollback"
  pass "rollback removes only the grouped clone and its link; the group directory and its siblings survive"
}

test_rollback_refuses_a_retargeted_link() {
  local sub target fakebin
  new_world rollback-retarget
  make_org_project gamma-proj
  target="$ORG/gamma-proj/code/gamma"
  sub="$W/sub"
  mark_firstmate_home "$sub"
  # A no-mistakes stand-in that retargets the link to the sibling repo, then fails.
  fakebin="$W/retarget-bin"
  mkdir -p "$fakebin"
  cat > "$fakebin/no-mistakes" <<SH
#!/usr/bin/env bash
ln -sfn "$ORG/gamma-proj/code/sibling" "$sub/projects/gamma"
exit 1
SH
  chmod +x "$fakebin/no-mistakes"
  if PATH="$fakebin:$FAKE:$PATH" FM_HOME="$MAIN" FM_SECONDMATE_CHARTER='linked domain' \
    "$ROOT/bin/fm-home-seed.sh" design "$sub" --link-root "$ORG" "gamma=$target" >/dev/null 2>"$W/retarget.err"; then
    fail "seed succeeded although no-mistakes initialization failed"
  fi
  assert_grep 'now points to' "$W/retarget.err" "rollback did not report the retargeted link"
  assert_present "$target/.git" "rollback removed a cloned target whose link was retargeted"
  assert_org_project_intact gamma-proj "retargeted rollback"
  pass "rollback refuses to remove a cloned target once its link was retargeted"
}

# --- retirement ---------------------------------------------------------------

seed_retirable() {  # -> SUB, TARGET, ADOPTED
  new_world "$1"
  make_org_project alpha-proj
  make_org_project beta-proj
  TARGET="$ORG/alpha-proj/code/alpha"
  ADOPTED="$ORG/beta-proj/code/beta"
  git clone --quiet "$(git -C "$MAIN/projects/beta" remote get-url origin)" "$ADOPTED"
  SUB="$W/sub"
  seed design "$SUB" --link-root "$ORG" "alpha=$TARGET" "beta=$ADOPTED" >/dev/null 2>&1 || fail "could not seed the retirable home"
  register_meta design "$SUB"
}

# The clean, fully pushed $TARGET holds gitignored local files that no git
# check can see; retirement must leave them and every other linked repository.
add_gitignored_files() {
  printf '.env\ndata/\n' >> "$TARGET/.git/info/exclude"
  printf 'SECRET=1\n' > "$TARGET/.env"
  mkdir -p "$TARGET/data"
  printf 'local\n' > "$TARGET/data/local.db"
  [ -z "$(git -C "$TARGET" status --porcelain --untracked-files=all)" ] || fail "the gitignored fixture made $TARGET dirty"
}

assert_retired_keeping_linked_repos() {  # <context>
  assert_absent "$SUB" "$1 left the secondmate home"
  assert_no_grep '- design ' "$MAIN/data/secondmates.md" "$1 left the registry route"
  assert_present "$TARGET/.git" "$1 removed the clean, fully pushed linked repository"
  assert_present "$TARGET/.env" "$1 removed a gitignored file in a linked repository"
  assert_present "$TARGET/data/local.db" "$1 removed gitignored data in a linked repository"
  assert_present "$ADOPTED/.git" "$1 removed the adopted linked repository"
  assert_org_project_intact alpha-proj "$1"
  assert_org_project_intact beta-proj "$1"
  assert_present "$MAIN/projects/alpha/.git" "$1 disturbed the main home's project"
}

test_retirement_keeps_every_linked_repo() {
  local out
  seed_retirable retire-keep
  add_gitignored_files
  printf 'wip\n' > "$ADOPTED/wip.txt"
  ln -sfn "$ORG/alpha-proj/code/sibling" "$SUB/projects/alpha"
  out=$(retire design 2>&1) || fail "retirement of a linked home failed: $out"
  assert_retired_keeping_linked_repos "retirement"
  assert_present "$ADOPTED/wip.txt" "retirement removed uncommitted work in a linked repository"
  pass "retirement removes only the home and its links; clean, dirty, and retargeted linked repositories survive"
}

test_forced_retirement_keeps_every_linked_repo() {
  local out
  seed_retirable retire-force
  add_gitignored_files
  printf 'more\n' >> "$ADOPTED/README.md"
  git -C "$ADOPTED" commit -qam 'local only'
  cp "$SUB/config/linked-projects" "$W/good-manifest"
  sed "s|^link.alpha=.*|link.alpha=$(cd "$ORG" && pwd -P)/alpha-proj/code/sibling|" "$W/good-manifest" > "$SUB/config/linked-projects"
  ln -sfn "$ORG/alpha-proj/code/sibling" "$SUB/projects/alpha"
  out=$(retire design --force 2>&1) || fail "forced retirement failed: $out"
  assert_retired_keeping_linked_repos "forced retirement"
  [ -n "$(git -C "$ADOPTED" log --oneline HEAD --not --remotes)" ] || fail "forced retirement lost an unpushed commit in a linked repository"
  pass "forced retirement removes only the home and its links; every linked repository survives"
}

test_brief_names_the_product_of_a_linked_project() {
  local sub brief root
  new_world brief-product
  make_org_project xelta
  make_org_project other
  mkdir -p "$ORG/xelta/code/enterprise"
  sub="$W/sub"
  seed design "$sub" --link-root "$ORG" "alpha=$ORG/xelta/code/enterprise/alpha" "gamma=$ORG/xelta/code/gamma" beta >/dev/null 2>&1 \
    || fail "could not seed the product home"
  root=$(cd "$ORG" && pwd -P)
  FM_HOME="$sub" "$ROOT/bin/fm-brief.sh" ship-alpha alpha --mode direct-PR >/dev/null || fail "ship brief for a linked project failed"
  brief="$sub/data/ship-alpha/brief.md"
  assert_grep '# Product context (read-only)' "$brief" "ship brief for a linked project has no product section"
  assert_grep 'repository of the product `xelta`' "$brief" "product section did not name the product"
  assert_grep "Product root: \`$root/xelta\`" "$brief" "product section did not name the product root"
  assert_grep "\`gamma\` at \`$root/xelta/code/gamma\`" "$brief" "product section did not list the sibling project"
  assert_no_grep '`beta`' "$brief" "product section listed an unlinked project"
  FM_HOME="$sub" "$ROOT/bin/fm-brief.sh" scout-gamma gamma --scout >/dev/null || fail "scout brief for a linked project failed"
  assert_grep "\`alpha\` at \`$root/xelta/code/enterprise/alpha\`" "$sub/data/scout-gamma/brief.md" "scout product section did not list the grouped sibling"
  FM_HOME="$sub" "$ROOT/bin/fm-brief.sh" ship-beta beta --mode direct-PR >/dev/null || fail "ship brief for an unlinked project failed"
  assert_no_grep 'Product context' "$sub/data/ship-beta/brief.md" "an unlinked project's brief has a product section"
  pass "ship and scout briefs name a linked project's product, root, and sibling projects; an unlinked project gets none"
}

test_home_without_link_root_is_unchanged() {
  local sub err
  new_world no-link-root
  sub="$W/sub"
  seed design "$sub" alpha >/dev/null 2>&1 || fail "plain seed failed"
  assert_absent "$sub/config/linked-projects" "a plain seed wrote a linked-projects manifest"
  [ -d "$sub/projects/alpha/.git" ] && [ ! -L "$sub/projects/alpha" ] || fail "a plain seed did not clone into the home"
  # A plain project whose destination is a symlink is still refused as before.
  mkdir -p "$W/elsewhere"
  ln -s "$W/elsewhere" "$sub/projects/beta"
  err="$W/plain-link.err"
  if seed design "$sub" beta >/dev/null 2>"$err"; then
    fail "a plain seed accepted a symlinked project destination"
  fi
  assert_grep 'must resolve inside the secondmate projects directory' "$err" "plain symlink refusal changed"
  rm -f "$sub/projects/beta"
  register_meta design "$sub"
  retire design >/dev/null 2>&1 || fail "plain retirement failed"
  assert_absent "$sub" "plain retirement left the home"
  pass "a home with no link root seeds, refuses, and retires exactly as before"
}

test_seed_links_new_clone_and_consumers_work_through_it
test_seed_adopts_existing_target_only_with_matching_origin
test_seed_links_grouped_and_ungrouped_repos_of_one_product
test_seed_refuses_every_containment_violation
test_seed_refuses_group_and_repo_overlap
test_rollback_removes_only_the_cloned_code_repo
test_rollback_keeps_the_group_and_its_siblings
test_rollback_refuses_a_retargeted_link
test_retirement_keeps_every_linked_repo
test_forced_retirement_keeps_every_linked_repo
test_brief_names_the_product_of_a_linked_project
test_home_without_link_root_is_unchanged

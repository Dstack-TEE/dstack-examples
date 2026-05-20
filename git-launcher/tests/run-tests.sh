#!/usr/bin/env bash
# shellcheck disable=SC2317  # test_* functions are dispatched indirectly via run_case "$@"
# shellcheck disable=SC2016  # we intentionally grep for literal GitHub Actions ${{ ... }} expressions
# Integration tests for bin/git-launcher.
#
# Builds a throwaway local git repo so the tests do not hit the network,
# pins the launcher to specific commits in that repo, and asserts that the
# launcher checks out the right commit, refuses bad inputs, and propagates
# the child env file.
#
# Requires: bash, git, mktemp.

set -u

THIS=$(readlink -f "$0" 2>/dev/null || realpath "$0")
TEST_DIR=$(dirname "$THIS")
ROOT=$(dirname "$TEST_DIR")
REPO_ROOT=$(dirname "$ROOT")
LAUNCHER=$ROOT/bin/git-launcher

[[ -x $LAUNCHER ]] || { echo "launcher not executable: $LAUNCHER" >&2; exit 2; }

TMPROOT=$(mktemp -d -t git-launcher-tests-XXXXXX)
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0
FAIL=0
FAILED_NAMES=()

run_case() {
  local name=$1; shift
  local out=$TMPROOT/${name//[^A-Za-z0-9_-]/_}.out
  local err=$TMPROOT/${name//[^A-Za-z0-9_-]/_}.err
  if ( "$@" ) >"$out" 2>"$err"; then
    printf '  PASS  %s\n' "$name"
    PASS=$((PASS + 1))
  else
    printf '  FAIL  %s\n' "$name"
    printf '        ── stdout ──\n'
    sed 's/^/        /' "$out"
    printf '        ── stderr ──\n'
    sed 's/^/        /' "$err"
    FAIL=$((FAIL + 1))
    FAILED_NAMES+=("$name")
  fi
}

# Build a fixture git repo with four commits:
#   c0: initial empty
#   c1: adds sub/run.sh and greeting.txt              <-- advanced-mode PIN
#   c2: adds tip.txt                                  <-- "future" advance
#   c3: adds sub/entrypoint.sh and sub/alt-entry.sh   <-- default-mode PIN
setup_fixture_repo() {
  local repo=$1
  mkdir -p "$repo"
  git -C "$repo" init -q -b main
  git -C "$repo" config user.email test@example.invalid
  git -C "$repo" config user.name "Test Fixture"
  git -C "$repo" commit -q --allow-empty -m "c0 initial"

  mkdir -p "$repo/sub"
  cat > "$repo/sub/run.sh" <<'SH'
#!/usr/bin/env bash
set -u
: "${MARKER_FILE:?MARKER_FILE not set}"
{
  printf 'cwd=%s\n' "$PWD"
  printf 'head=%s\n' "$(git rev-parse HEAD)"
  printf 'greeting=%s\n' "$(cat ../greeting.txt 2>/dev/null || echo MISSING)"
  printf 'child_env_extra=%s\n' "${CHILD_ENV_EXTRA-UNSET}"
} > "$MARKER_FILE"
SH
  chmod +x "$repo/sub/run.sh"
  echo "hello" > "$repo/greeting.txt"
  git -C "$repo" add sub/run.sh greeting.txt
  git -C "$repo" commit -q -m "c1 add run.sh and greeting"

  echo "tip" > "$repo/tip.txt"
  git -C "$repo" add tip.txt
  git -C "$repo" commit -q -m "c2 add tip.txt"

  # entrypoint.sh is intentionally NOT marked executable; the launcher must
  # run it through 'bash <script>' rather than rely on the exec bit.
  cat > "$repo/sub/entrypoint.sh" <<'SH'
#!/usr/bin/env bash
set -u
: "${MARKER_FILE:?MARKER_FILE not set}"
{
  printf 'mode=default\n'
  printf 'entry=entrypoint.sh\n'
  printf 'cwd=%s\n' "$PWD"
  printf 'head=%s\n' "$(git rev-parse HEAD)"
  printf 'child_env_extra=%s\n' "${CHILD_ENV_EXTRA-UNSET}"
} > "$MARKER_FILE"
SH
  # A second script under a non-default name, used to exercise ENTRYPOINT_SCRIPT.
  cat > "$repo/sub/alt-entry.sh" <<'SH'
#!/usr/bin/env bash
set -u
: "${MARKER_FILE:?MARKER_FILE not set}"
{
  printf 'mode=default\n'
  printf 'entry=alt-entry.sh\n'
  printf 'head=%s\n' "$(git rev-parse HEAD)"
} > "$MARKER_FILE"
SH
  git -C "$repo" add sub/entrypoint.sh sub/alt-entry.sh
  git -C "$repo" commit -q -m "c3 add entrypoint.sh and alt-entry.sh"
}

FIXTURE=$TMPROOT/fixture-repo
setup_fixture_repo "$FIXTURE"

PIN_SHA=$(git -C "$FIXTURE" rev-parse HEAD~2)        # c1, advanced-mode pin
TIP_SHA=$(git -C "$FIXTURE" rev-parse HEAD~1)        # c2
DEFAULT_SHA=$(git -C "$FIXTURE" rev-parse HEAD)      # c3, default-mode pin
# 40 zeros: syntactically a valid SHA, semantically not in this repo.
BOGUS_SHA=0000000000000000000000000000000000000000

# ──────────────────────────────────────────────────────────────────────────
# Test cases
# ──────────────────────────────────────────────────────────────────────────

test_happy_pinning() {
  local work=$TMPROOT/work-happy
  local marker=$TMPROOT/marker-happy.txt
  local conf=$TMPROOT/conf-happy.env
  cat > "$conf" <<EOF
REPO_URL=$FIXTURE
COMMIT_SHA=$PIN_SHA
WORK_DIR=$work
REPO_SUBDIR=sub
INSTALL_CMD=true
RUN_CMD="MARKER_FILE='$marker' ./run.sh"
EOF
  "$LAUNCHER" "$conf" || return 1
  [[ -f $marker ]] || { echo "marker file not created" >&2; return 1; }
  grep -q "head=$PIN_SHA" "$marker" || { echo "head not pinned to $PIN_SHA" >&2; cat "$marker" >&2; return 1; }
  grep -q "greeting=hello" "$marker" || { echo "expected greeting=hello" >&2; cat "$marker" >&2; return 1; }
  # tip.txt was added in c2 — it must not be present when pinned to c1.
  [[ ! -e $work/tip.txt ]] || { echo "tip.txt leaked through pinning" >&2; return 1; }
  return 0
}

test_rerun_advance_pin() {
  local work=$TMPROOT/work-advance
  local marker=$TMPROOT/marker-advance.txt
  local conf1=$TMPROOT/conf-advance-1.env
  local conf2=$TMPROOT/conf-advance-2.env

  cat > "$conf1" <<EOF
REPO_URL=$FIXTURE
COMMIT_SHA=$PIN_SHA
WORK_DIR=$work
REPO_SUBDIR=sub
INSTALL_CMD=
RUN_CMD="MARKER_FILE='$marker' ./run.sh"
EOF
  "$LAUNCHER" "$conf1" || return 1
  grep -q "head=$PIN_SHA" "$marker" || { echo "first pin failed" >&2; return 1; }

  cat > "$conf2" <<EOF
REPO_URL=$FIXTURE
COMMIT_SHA=$TIP_SHA
WORK_DIR=$work
REPO_SUBDIR=sub
INSTALL_CMD=
RUN_CMD="MARKER_FILE='$marker' ./run.sh"
EOF
  "$LAUNCHER" "$conf2" || return 1
  grep -q "head=$TIP_SHA" "$marker" || { echo "advance pin to $TIP_SHA failed" >&2; cat "$marker" >&2; return 1; }
  [[ -e $work/tip.txt ]] || { echo "tip.txt missing after advance" >&2; return 1; }
  return 0
}

test_bogus_sha_fails() {
  local work=$TMPROOT/work-bogus
  local conf=$TMPROOT/conf-bogus.env
  cat > "$conf" <<EOF
REPO_URL=$FIXTURE
COMMIT_SHA=$BOGUS_SHA
WORK_DIR=$work
INSTALL_CMD=
RUN_CMD=echo should-not-run
EOF
  if "$LAUNCHER" "$conf"; then
    echo "launcher succeeded with bogus SHA — should have failed" >&2
    return 1
  fi
  return 0
}

test_branch_name_rejected() {
  local conf=$TMPROOT/conf-branch.env
  cat > "$conf" <<EOF
REPO_URL=$FIXTURE
COMMIT_SHA=main
WORK_DIR=$TMPROOT/work-branch
INSTALL_CMD=
RUN_CMD=echo nope
EOF
  if "$LAUNCHER" "$conf"; then
    echo "launcher accepted 'main' as COMMIT_SHA" >&2
    return 1
  fi
  return 0
}

test_tag_name_rejected() {
  # Create a tag in the fixture and confirm the launcher refuses it as a SHA.
  git -C "$FIXTURE" tag -f v0 "$PIN_SHA" >/dev/null
  local conf=$TMPROOT/conf-tag.env
  cat > "$conf" <<EOF
REPO_URL=$FIXTURE
COMMIT_SHA=v0
WORK_DIR=$TMPROOT/work-tag
INSTALL_CMD=
RUN_CMD=echo nope
EOF
  if "$LAUNCHER" "$conf"; then
    echo "launcher accepted tag 'v0' as COMMIT_SHA" >&2
    return 1
  fi
  return 0
}

test_short_sha_rejected() {
  local short=${PIN_SHA:0:12}
  local conf=$TMPROOT/conf-short.env
  cat > "$conf" <<EOF
REPO_URL=$FIXTURE
COMMIT_SHA=$short
WORK_DIR=$TMPROOT/work-short
INSTALL_CMD=
RUN_CMD=echo nope
EOF
  if "$LAUNCHER" "$conf"; then
    echo "launcher accepted short SHA $short" >&2
    return 1
  fi
  return 0
}

test_missing_required_field() {
  local conf=$TMPROOT/conf-missing.env
  # COMMIT_SHA is intentionally absent
  cat > "$conf" <<EOF
REPO_URL=$FIXTURE
WORK_DIR=$TMPROOT/work-missing
INSTALL_CMD=
RUN_CMD=echo nope
EOF
  if "$LAUNCHER" "$conf"; then
    echo "launcher accepted config with missing COMMIT_SHA" >&2
    return 1
  fi
  return 0
}

test_unknown_key_rejected() {
  local conf=$TMPROOT/conf-unknown.env
  cat > "$conf" <<EOF
REPO_URL=$FIXTURE
COMMIT_SHA=$PIN_SHA
WORK_DIR=$TMPROOT/work-unknown
INSTALL_CMD=
RUN_CMD=echo nope
FOO_BAR=42
EOF
  if "$LAUNCHER" "$conf"; then
    echo "launcher accepted unknown key FOO_BAR" >&2
    return 1
  fi
  return 0
}

test_repo_subdir_escape_rejected() {
  local conf=$TMPROOT/conf-escape.env
  cat > "$conf" <<EOF
REPO_URL=$FIXTURE
COMMIT_SHA=$PIN_SHA
WORK_DIR=$TMPROOT/work-escape
REPO_SUBDIR=../etc
INSTALL_CMD=
RUN_CMD=echo nope
EOF
  if "$LAUNCHER" "$conf"; then
    echo "launcher accepted REPO_SUBDIR containing '..'" >&2
    return 1
  fi
  return 0
}

test_origin_mismatch_rejected() {
  # Pre-seed WORK_DIR with a clone whose origin URL doesn't match REPO_URL.
  local other_repo=$TMPROOT/other-repo
  mkdir -p "$other_repo"
  git -C "$other_repo" init -q -b main
  git -C "$other_repo" config user.email a@b.c
  git -C "$other_repo" config user.name X
  git -C "$other_repo" commit -q --allow-empty -m c0

  local work=$TMPROOT/work-mismatch
  mkdir -p "$work"
  git clone -q "$other_repo" "$work"

  local conf=$TMPROOT/conf-mismatch.env
  cat > "$conf" <<EOF
REPO_URL=$FIXTURE
COMMIT_SHA=$PIN_SHA
WORK_DIR=$work
INSTALL_CMD=
RUN_CMD=echo nope
EOF
  if "$LAUNCHER" "$conf"; then
    echo "launcher accepted WORK_DIR whose origin differs from REPO_URL" >&2
    return 1
  fi
  return 0
}

test_non_git_non_empty_work_dir_rejected() {
  local work=$TMPROOT/work-non-git
  mkdir -p "$work"
  echo stale > "$work/stale.txt"

  local conf=$TMPROOT/conf-non-git.env
  cat > "$conf" <<EOF
REPO_URL=$FIXTURE
COMMIT_SHA=$PIN_SHA
WORK_DIR=$work
INSTALL_CMD=
RUN_CMD=echo nope
EOF
  if "$LAUNCHER" "$conf"; then
    echo "launcher accepted non-empty WORK_DIR that is not a git checkout" >&2
    return 1
  fi
  return 0
}

test_child_env_file() {
  local work=$TMPROOT/work-env
  local marker=$TMPROOT/marker-env.txt
  local envfile=$TMPROOT/workload.env
  local conf=$TMPROOT/conf-env.env
  cat > "$envfile" <<EOF
# a comment
CHILD_ENV_EXTRA=passed-through
EOF
  cat > "$conf" <<EOF
REPO_URL=$FIXTURE
COMMIT_SHA=$PIN_SHA
WORK_DIR=$work
REPO_SUBDIR=sub
CHILD_ENV_FILE=$envfile
INSTALL_CMD=
RUN_CMD="MARKER_FILE='$marker' ./run.sh"
EOF
  "$LAUNCHER" "$conf" || return 1
  grep -q "child_env_extra=passed-through" "$marker" || { echo "CHILD_ENV_FILE not applied" >&2; cat "$marker" >&2; return 1; }
  return 0
}

test_install_runs_before_run() {
  # Use INSTALL_CMD to drop a marker; RUN_CMD asserts the file is there.
  local work=$TMPROOT/work-install
  local installed=$TMPROOT/installed.flag
  local conf=$TMPROOT/conf-install.env
  cat > "$conf" <<EOF
REPO_URL=$FIXTURE
COMMIT_SHA=$PIN_SHA
WORK_DIR=$work
REPO_SUBDIR=sub
INSTALL_CMD="touch '$installed'"
RUN_CMD="test -f '$installed'"
EOF
  "$LAUNCHER" "$conf" || return 1
  [[ -f $installed ]] || return 1
  return 0
}

test_default_mode_happy() {
  local work=$TMPROOT/work-default
  local marker=$TMPROOT/marker-default.txt
  local conf=$TMPROOT/conf-default.env
  # No INSTALL_CMD, no RUN_CMD, no ENTRYPOINT_SCRIPT: default mode picks the
  # built-in 'entrypoint.sh' under REPO_SUBDIR.
  cat > "$conf" <<EOF
REPO_URL=$FIXTURE
COMMIT_SHA=$DEFAULT_SHA
WORK_DIR=$work
REPO_SUBDIR=sub
EOF
  MARKER_FILE=$marker "$LAUNCHER" "$conf" || return 1
  [[ -f $marker ]] || { echo "marker not created" >&2; return 1; }
  grep -q "mode=default" "$marker" || { echo "default-mode entrypoint.sh did not run" >&2; cat "$marker" >&2; return 1; }
  grep -q "entry=entrypoint.sh" "$marker" || { echo "wrong entry script ran" >&2; cat "$marker" >&2; return 1; }
  grep -q "head=$DEFAULT_SHA" "$marker" || { echo "head not pinned to $DEFAULT_SHA" >&2; cat "$marker" >&2; return 1; }
  return 0
}

test_default_mode_missing_script_fails() {
  # PIN_SHA (c1) has run.sh but no entrypoint.sh. In default mode the launcher
  # must refuse to start rather than fall back to anything.
  local conf=$TMPROOT/conf-default-missing.env
  cat > "$conf" <<EOF
REPO_URL=$FIXTURE
COMMIT_SHA=$PIN_SHA
WORK_DIR=$TMPROOT/work-default-missing
REPO_SUBDIR=sub
EOF
  if "$LAUNCHER" "$conf"; then
    echo "launcher should have failed with entrypoint.sh missing" >&2
    return 1
  fi
  return 0
}

test_entrypoint_script_override() {
  # ENTRYPOINT_SCRIPT lets a workload repo with a non-default entry name
  # opt into default mode without renaming its script.
  local work=$TMPROOT/work-altentry
  local marker=$TMPROOT/marker-altentry.txt
  local conf=$TMPROOT/conf-altentry.env
  cat > "$conf" <<EOF
REPO_URL=$FIXTURE
COMMIT_SHA=$DEFAULT_SHA
WORK_DIR=$work
REPO_SUBDIR=sub
ENTRYPOINT_SCRIPT=alt-entry.sh
EOF
  MARKER_FILE=$marker "$LAUNCHER" "$conf" || return 1
  grep -q "entry=alt-entry.sh" "$marker" || { echo "ENTRYPOINT_SCRIPT override did not run alt-entry.sh" >&2; cat "$marker" >&2; return 1; }
  grep -q "head=$DEFAULT_SHA" "$marker" || { echo "head not pinned to $DEFAULT_SHA" >&2; cat "$marker" >&2; return 1; }
  return 0
}

test_entrypoint_script_escape_rejected() {
  # ENTRYPOINT_SCRIPT must be a relative path inside the repo; reject '..'.
  local conf=$TMPROOT/conf-altentry-escape.env
  cat > "$conf" <<EOF
REPO_URL=$FIXTURE
COMMIT_SHA=$DEFAULT_SHA
WORK_DIR=$TMPROOT/work-altentry-escape
REPO_SUBDIR=sub
ENTRYPOINT_SCRIPT=../../etc/passwd
EOF
  if "$LAUNCHER" "$conf"; then
    echo "launcher accepted ENTRYPOINT_SCRIPT containing '..'" >&2
    return 1
  fi
  return 0
}

test_install_cmd_without_run_cmd_fails() {
  # INSTALL_CMD only makes sense alongside RUN_CMD; setting one without the
  # other is a misconfiguration and must fail closed.
  local conf=$TMPROOT/conf-install-only.env
  cat > "$conf" <<EOF
REPO_URL=$FIXTURE
COMMIT_SHA=$DEFAULT_SHA
WORK_DIR=$TMPROOT/work-install-only
REPO_SUBDIR=sub
INSTALL_CMD=true
EOF
  if "$LAUNCHER" "$conf"; then
    echo "launcher accepted INSTALL_CMD without RUN_CMD" >&2
    return 1
  fi
  return 0
}

test_help_flag() {
  "$LAUNCHER" --help >/dev/null
}

test_release_workflow_attests_image_digest() {
  local workflow=$REPO_ROOT/.github/workflows/git-launcher-release.yml
  [[ -f $workflow ]] || { echo "missing release workflow: $workflow" >&2; return 1; }

  grep -q "attestations: write" "$workflow" || { echo "workflow missing attestations permission" >&2; return 1; }
  grep -q "id-token: write" "$workflow" || { echo "workflow missing OIDC permission" >&2; return 1; }
  grep -q "actions/attest-build-provenance@v1" "$workflow" || { echo "workflow does not generate GitHub artifact attestation" >&2; return 1; }
  grep -q 'subject-digest: ${{ steps.build-and-push.outputs.digest }}' "$workflow" || { echo "attestation is not bound to build-push digest" >&2; return 1; }
  grep -q "push-to-registry: true" "$workflow" || { echo "attestation is not pushed to registry" >&2; return 1; }
  grep -q 'search.sigstore.dev/?hash=${{ steps.build-and-push.outputs.digest }}' "$workflow" || { echo "release does not annotate Sigstore digest link" >&2; return 1; }
  grep -q 'docker.io/${{ vars.DOCKERHUB_ORG }}/git-launcher' "$workflow" || { echo "image not published under dstack DOCKERHUB_ORG namespace" >&2; return 1; }
  grep -q "git-launcher-v" "$workflow" || { echo "workflow not gated on git-launcher-v* tag prefix" >&2; return 1; }

  local test_line build_line
  test_line=$(grep -n "Run launcher tests" "$workflow" | cut -d: -f1 | head -1)
  build_line=$(grep -n "Build and push Docker image" "$workflow" | cut -d: -f1 | head -1)
  [[ -n $test_line && -n $build_line ]] || { echo "workflow missing test or build step" >&2; return 1; }
  (( test_line < build_line )) || { echo "launcher tests must run before image build" >&2; return 1; }
}

test_dockerfile_runtime_is_minimal_launcher() {
  local dockerfile=$ROOT/docker/Dockerfile
  [[ -f $dockerfile ]] || { echo "missing docker/Dockerfile" >&2; return 1; }

  grep -Eq "^FROM ubuntu:24\.04@sha256:[0-9a-f]{64}\$" "$dockerfile" || { echo "Dockerfile must pin the Ubuntu 24.04 base by digest (FROM ubuntu:24.04@sha256:<64hex>)" >&2; return 1; }
  grep -q "bash" "$dockerfile" || { echo "Dockerfile missing bash dependency" >&2; return 1; }
  grep -q "git" "$dockerfile" || { echo "Dockerfile missing git dependency" >&2; return 1; }
  grep -q "COPY bin/git-launcher /usr/local/bin/git-launcher" "$dockerfile" || { echo "Dockerfile does not copy only the launcher script" >&2; return 1; }
  grep -q 'ENTRYPOINT \["git-launcher"\]' "$dockerfile" || { echo "Dockerfile entrypoint is not git-launcher" >&2; return 1; }
}

test_verify_doc_present_and_linked() {
  local verify=$ROOT/VERIFY.md
  local readme=$ROOT/README.md
  [[ -f $verify ]] || { echo "missing VERIFY.md at $verify" >&2; return 1; }
  grep -q 'VERIFY.md' "$readme" || { echo "README does not link VERIFY.md" >&2; return 1; }
}

# ──────────────────────────────────────────────────────────────────────────
# Run all cases
# ──────────────────────────────────────────────────────────────────────────

echo "git-launcher tests"
echo "  launcher: $LAUNCHER"
echo "  tmproot:  $TMPROOT"
echo

run_case "happy_pinning_runs_pinned_commit"      test_happy_pinning
run_case "rerun_advances_pin"                    test_rerun_advance_pin
run_case "bogus_sha_fails"                       test_bogus_sha_fails
run_case "branch_name_rejected"                  test_branch_name_rejected
run_case "tag_name_rejected"                     test_tag_name_rejected
run_case "short_sha_rejected"                    test_short_sha_rejected
run_case "missing_required_field"                test_missing_required_field
run_case "unknown_key_rejected"                  test_unknown_key_rejected
run_case "repo_subdir_escape_rejected"           test_repo_subdir_escape_rejected
run_case "origin_mismatch_rejected"              test_origin_mismatch_rejected
run_case "non_git_non_empty_work_dir_rejected"   test_non_git_non_empty_work_dir_rejected
run_case "child_env_file_passes_through"         test_child_env_file
run_case "install_runs_before_run"               test_install_runs_before_run
run_case "default_mode_happy"                    test_default_mode_happy
run_case "default_mode_missing_script_fails"     test_default_mode_missing_script_fails
run_case "entrypoint_script_override"            test_entrypoint_script_override
run_case "entrypoint_script_escape_rejected"     test_entrypoint_script_escape_rejected
run_case "install_cmd_without_run_cmd_fails"     test_install_cmd_without_run_cmd_fails
run_case "help_flag"                             test_help_flag
run_case "release_workflow_attests_image_digest" test_release_workflow_attests_image_digest
run_case "dockerfile_runtime_is_minimal_launcher" test_dockerfile_runtime_is_minimal_launcher
run_case "verify_doc_present_and_linked"          test_verify_doc_present_and_linked

echo
printf 'Passed: %d   Failed: %d\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  printf 'Failed cases: %s\n' "${FAILED_NAMES[*]}"
  exit 1
fi
exit 0

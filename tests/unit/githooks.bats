#!/usr/bin/env bats

bats_require_minimum_version 1.5.0
load test_helper

ZERO_SHA1="0000000000000000000000000000000000000000"
ZERO_SHA256="0000000000000000000000000000000000000000000000000000000000000000"
SAMPLE_SHA="1111111111111111111111111111111111111111"
REMOTE_SHA="2222222222222222222222222222222222222222"

setup() {
  setup_test_env
}

teardown() {
  teardown_test_env
}

mock_quality_tools() {
  local shellcheck_exit="${1:-0}"
  local shfmt_exit="${2:-0}"
  local bats_exit="${3:-0}"

  create_mock shellcheck "printf 'shellcheck %s\n' \"\$*\" >> \"$MOCK_LOG\"; exit $shellcheck_exit"
  create_mock shfmt "printf 'shfmt %s\n' \"\$*\" >> \"$MOCK_LOG\"; exit $shfmt_exit"
  create_mock bats "printf 'bats %s\n' \"\$*\" >> \"$MOCK_LOG\"; exit $bats_exit"
}

@test "pre-push hook exists and is executable" {
  [ -x "$REPO_ROOT/.githooks/pre-push" ]
}

@test "pre-push skips checks for delete-only pushes" {
  mock_quality_tools 1 1 1

  run bash -c 'printf "%s\n%s\n" \
    "(delete) '"$ZERO_SHA1"' refs/heads/old-branch '"$REMOTE_SHA"'" \
    "(delete) '"$ZERO_SHA256"' refs/tags/old-tag '"$REMOTE_SHA"'" \
    | "$REPO_ROOT/.githooks/pre-push" origin https://example.invalid/repo.git'

  [ "$status" -eq 0 ]
  [[ "$output" == *"Skipping pre-push checks"* ]]
  [ ! -s "$MOCK_LOG" ]
}

@test "pre-push fails fast with install instructions when required tools are missing" {
  local bare_bin="$TEST_TMP/bare_bin"
  mkdir -p "$bare_bin"
  ln -s "$(command -v bash)" "$bare_bin/bash"
  ln -s "$(command -v git)" "$bare_bin/git"
  ln -s "$(command -v dirname)" "$bare_bin/dirname"

  run env PATH="$bare_bin" bash -c 'printf "%s\n" \
    "refs/heads/master '"$SAMPLE_SHA"' refs/heads/master '"$REMOTE_SHA"'" \
    | "$REPO_ROOT/.githooks/pre-push" origin https://example.invalid/repo.git'

  [ "$status" -eq 1 ]
  [[ "$output" == *"Missing required pre-push tool(s): shellcheck shfmt bats"* ]]
  [[ "$output" == *"brew install shellcheck shfmt bats-core"* ]]
  [[ "$output" == *"sudo apt-get install -y shellcheck shfmt bats"* ]]
}

@test "pre-push runs shellcheck, shfmt, and bats on normal pushes" {
  mock_quality_tools 0 0 0

  run bash -c 'printf "%s\n" \
    "refs/heads/master '"$SAMPLE_SHA"' refs/heads/master '"$REMOTE_SHA"'" \
    | "$REPO_ROOT/.githooks/pre-push" origin https://example.invalid/repo.git'

  [ "$status" -eq 0 ]
  grep -q '^shellcheck -S warning .*\.githooks/pre-push$' "$MOCK_LOG"
  grep -q '^shfmt -i 2 -ci -d .*\.githooks/pre-push$' "$MOCK_LOG"
  grep -q '^bats tests/unit/$' "$MOCK_LOG"
}

@test "pre-push runs checks on mixed delete and update pushes" {
  mock_quality_tools 0 0 0

  run bash -c 'printf "%s\n%s\n" \
    "(delete) '"$ZERO_SHA1"' refs/heads/old-branch '"$REMOTE_SHA"'" \
    "refs/heads/master '"$SAMPLE_SHA"' refs/heads/master '"$REMOTE_SHA"'" \
    | "$REPO_ROOT/.githooks/pre-push" origin https://example.invalid/repo.git'

  [ "$status" -eq 0 ]
  grep -q '^bats tests/unit/$' "$MOCK_LOG"
}

@test "pre-push aborts push when shellcheck fails" {
  mock_quality_tools 1 0 0

  run bash -c 'printf "%s\n" \
    "refs/heads/master '"$SAMPLE_SHA"' refs/heads/master '"$REMOTE_SHA"'" \
    | "$REPO_ROOT/.githooks/pre-push" origin https://example.invalid/repo.git'

  [ "$status" -eq 1 ]
  grep -q '^shellcheck ' "$MOCK_LOG"
  ! grep -q '^bats ' "$MOCK_LOG"
}

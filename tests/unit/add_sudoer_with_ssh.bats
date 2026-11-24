#!/usr/bin/env bats

bats_require_minimum_version 1.5.0
load test_helper

setup() {
  setup_test_env
  mock_uid 0 root

  # Stub system commands for isolated testing
  create_mock adduser '
echo "adduser $*" >>"$MOCK_LOG"
if [[ "${1:-}" == "--help" ]]; then
  echo "  --comment COMMENT"
  exit 0
fi
mkdir -p "$TEST_TMP/home_${!#}"
'
  create_mock usermod 'echo "usermod $*" >>"$MOCK_LOG"'
  create_mock passwd 'echo "passwd $*" >>"$MOCK_LOG"'
  create_mock getent '
if [[ "$1" == "group" && "$2" == "sudo" ]]; then
  echo "sudo:x:27:"
  exit 0
fi
if [[ "$1" == "passwd" ]]; then
  echo "$2:x:1001:1001::${TEST_TMP}/home_$2:/bin/bash"
  exit 0
fi
exit 2
'
  create_mock chown 'echo "chown $*" >>"$MOCK_LOG"'
}

teardown() {
  teardown_test_env
}

@test "add_sudoer_with_ssh rejects invalid usernames including injection payloads" {
  run bash "$REPO_ROOT/add_sudoer_with_ssh.sh" -u 'bad;id' --ssh-key 'ssh-ed25519 AAAA' --disabled-password --no-lock-root
  [ "$status" -eq 1 ]
  [[ "$output" == *"Invalid username"* ]]
}

@test "add_sudoer_with_ssh rejects root as target username" {
  run bash "$REPO_ROOT/add_sudoer_with_ssh.sh" -u root --ssh-key 'ssh-ed25519 AAAA' --disabled-password --no-lock-root
  [ "$status" -eq 1 ]
  [[ "$output" == *"root"* ]]
}

@test "add_sudoer_with_ssh rejects invalid SSH public keys before creating user" {
  run bash "$REPO_ROOT/add_sudoer_with_ssh.sh" -u deploy --ssh-key 'not-a-valid-key' --disabled-password --no-lock-root
  [ "$status" -eq 1 ]
  [[ "$output" == *"Invalid SSH public key"* ]]
  [ ! -s "$MOCK_LOG" ]
}

@test "add_sudoer_with_ssh creates user with validated key and skips root lock with --no-lock-root" {
  local key_file="$TEST_TMP/id_ed25519"
  ssh-keygen -q -t ed25519 -N "" -f "$key_file"

  run bash "$REPO_ROOT/add_sudoer_with_ssh.sh" \
    -u deploy \
    --ssh-key-file "${key_file}.pub" \
    --disabled-password \
    --no-lock-root

  [ "$status" -eq 0 ]
  [ -f "$TEST_TMP/home_deploy/.ssh/authorized_keys" ]
  grep -qF "adduser --comment  --disabled-password deploy" "$MOCK_LOG"
  grep -qF "usermod -aG sudo deploy" "$MOCK_LOG"
  run ! grep -qF "passwd -l root" "$MOCK_LOG"
}

@test "add_sudoer_with_ssh locks root only when --lock-root is passed" {
  local key_file="$TEST_TMP/id_ed25519"
  ssh-keygen -q -t ed25519 -N "" -f "$key_file"

  # Simulate an unlocked root entry in /etc/shadow regardless of host/container state
  create_mock awk '
if [[ "$*" == *"/etc/shadow"* ]]; then
  echo "unlocked_root_hash"
  exit 0
fi
exec /usr/bin/awk "$@"
'

  run bash "$REPO_ROOT/add_sudoer_with_ssh.sh" \
    -u deploy \
    --ssh-key-file "${key_file}.pub" \
    --disabled-password \
    --lock-root

  [ "$status" -eq 0 ]
  grep -qF "passwd -l root" "$MOCK_LOG"
}

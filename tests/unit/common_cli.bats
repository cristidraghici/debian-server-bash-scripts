#!/usr/bin/env bats

bats_require_minimum_version 1.5.0
load test_helper

setup() {
  setup_test_env
}

teardown() {
  teardown_test_env
}

SCRIPTS=(
  add_sudoer_with_ssh.sh
  enable_php_extension.sh
  harden_server.sh
  install_antigen.sh
  install_composer.sh
  install_nvm.sh
  install_virtualmin.sh
  install_wp_cli.sh
  install_wp.sh
  update_php_hosts.sh
)

@test "all scripts support --help with exit 0" {
  for script in "${SCRIPTS[@]}"; do
    run bash "$REPO_ROOT/$script" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage:"* ]]
  done
}

@test "all scripts reject unknown flags with exit 1" {
  for script in "${SCRIPTS[@]}"; do
    run bash "$REPO_ROOT/$script" --definitely-invalid-flag
    [ "$status" -eq 1 ]
    [[ "$output" == *"Unknown option"* ]]
  done
}

@test "system scripts reject non-root execution with exit 1" {
  mock_uid 1000
  for script in add_sudoer_with_ssh.sh enable_php_extension.sh harden_server.sh install_virtualmin.sh update_php_hosts.sh; do
    run bash "$REPO_ROOT/$script"
    [ "$status" -eq 1 ]
    [[ "$output" == *"must be run as root"* ]]
  done
}

@test "user scripts reject root execution without --root" {
  mock_uid 0 root
  for script in install_antigen.sh install_composer.sh install_nvm.sh install_wp_cli.sh install_wp.sh; do
    run bash "$REPO_ROOT/$script"
    [ "$status" -eq 1 ]
    [[ "$output" == *"--root"* ]]
    [[ "$output" == *"bash -s -- --root"* ]]
  done
}

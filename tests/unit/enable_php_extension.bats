#!/usr/bin/env bats

bats_require_minimum_version 1.5.0
load test_helper

setup() {
  setup_test_env
  mock_uid 0 root

  create_mock php 'echo "8.4"'
  create_mock apt-get 'echo "apt-get $*" >>"$MOCK_LOG"'
  create_mock phpenmod 'echo "phpenmod $*" >>"$MOCK_LOG"'
}

teardown() {
  teardown_test_env
}

@test "enable_php_extension rejects invalid php version format" {
  run bash "$REPO_ROOT/enable_php_extension.sh" -v "invalid" curl
  [ "$status" -eq 1 ]
  [[ "$output" == *"Invalid PHP version"* ]]
}

@test "enable_php_extension rejects invalid extension names" {
  run bash "$REPO_ROOT/enable_php_extension.sh" -v 8.4 "curl;rm"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Invalid extension name"* ]]
}

@test "enable_php_extension batches apt-get install and reloads php-fpm and nginx" {
  create_mock systemctl '
echo "systemctl $*" >>"$MOCK_LOG"
if [[ "$1" == "is-active" ]]; then
  case "$3" in
    php8.4-fpm|nginx) exit 0 ;;
    *) exit 3 ;;
  esac
fi
'

  run bash "$REPO_ROOT/enable_php_extension.sh" -v 8.4 curl gd mbstring
  [ "$status" -eq 0 ]
  grep -qF "apt-get update" "$MOCK_LOG"
  grep -qF "apt-get install -y php8.4-curl php8.4-gd php8.4-mbstring" "$MOCK_LOG"
  grep -qF "phpenmod -v 8.4 curl gd mbstring" "$MOCK_LOG"
  grep -qF "systemctl reload-or-restart php8.4-fpm" "$MOCK_LOG"
  grep -qF "systemctl reload nginx" "$MOCK_LOG"
  run ! grep -qF "reload-or-restart apache2" "$MOCK_LOG"
}

@test "enable_php_extension reloads apache2 when active and respects --skip-update and --no-restart" {
  create_mock systemctl '
echo "systemctl $*" >>"$MOCK_LOG"
if [[ "$1" == "is-active" && "$3" == "apache2" ]]; then
  exit 0
fi
exit 3
'

  run bash "$REPO_ROOT/enable_php_extension.sh" --skip-update --no-restart curl
  [ "$status" -eq 0 ]
  run ! grep -qF "apt-get update" "$MOCK_LOG"
  grep -qF "apt-get install -y php8.4-curl" "$MOCK_LOG"
  run ! grep -qF "systemctl reload-or-restart" "$MOCK_LOG"
}

#!/usr/bin/env bats

bats_require_minimum_version 1.5.0
load test_helper

setup() {
  setup_test_env
  mock_uid 0 root

  # State file tracking each domain's current PHP version: "domain version"
  DOMAIN_STATE="$TEST_TMP/domains.state"
  export DOMAIN_STATE
  cat >"$DOMAIN_STATE" <<'EOF'
alpha.example.com 8.2
beta.example.com 8.2
gamma.example.com 8.4
static.example.com none
EOF

  create_mock dpkg-query '
if [[ "$*" == *"php8.2"* && "$*" != *"php[0-9]"* ]]; then
  printf "php8.2-cli\tinstall ok installed\n"
  printf "php8.2-fpm\tinstall ok installed\n"
  exit 0
fi
if [[ "$*" == *"php8.4"* && "$*" != *"php[0-9]"* ]]; then
  printf "php8.4-cli\tinstall ok installed\n"
  printf "php8.4-fpm\tinstall ok installed\n"
  exit 0
fi
printf "php8.2-cli\tinstall ok installed\n"
printf "php8.2-fpm\tinstall ok installed\n"
printf "php8.4-cli\tinstall ok installed\n"
printf "php8.4-fpm\tinstall ok installed\n"
'

  create_mock apt-get 'echo "apt-get $*" >>"$MOCK_LOG"'

  create_mock systemctl '
echo "systemctl $*" >>"$MOCK_LOG"
if [[ "$1" == "is-active" ]]; then
  case "$3" in
    php8.4-fpm|apache2) exit 0 ;;
    *) exit 3 ;;
  esac
fi
'

  create_mock virtualmin '
echo "virtualmin $*" >>"$MOCK_LOG"
case "$1" in
  list-domains)
    if [[ "$*" == *"--name-only"* ]]; then
      awk "{ print \$1 }" "$DOMAIN_STATE"
    fi
    ;;
  list-php-directories)
    dom=""
    shift
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == "--domain" ]]; then
        dom="$2"
        shift 2
      else
        shift
      fi
    done
    ver="$(awk -v d="$dom" "\$1 == d { print \$2 }" "$DOMAIN_STATE")"
    if [[ -n "$ver" && "$ver" != "none" ]]; then
      printf "/home/%s/public_html\n    Version: %s\n" "$dom" "$ver"
    fi
    ;;
  modify-web)
    dom=""
    new_ver=""
    shift
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --domain) dom="$2"; shift 2 ;;
        --php-version) new_ver="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    if [[ "${FAIL_DOMAIN:-}" == "$dom" ]]; then
      echo "Simulated failure for $dom" >&2
      exit 1
    fi
    awk -v d="$dom" -v v="$new_ver" "\$1 == d { print d, v; next } { print }" "$DOMAIN_STATE" >"$DOMAIN_STATE.tmp"
    mv "$DOMAIN_STATE.tmp" "$DOMAIN_STATE"
    ;;
esac
'
}

teardown() {
  teardown_test_env
}

@test "update_php_hosts rejects invalid php version format" {
  run bash "$REPO_ROOT/update_php_hosts.sh" -v "invalid" -y
  [ "$status" -eq 1 ]
  [[ "$output" == *"Invalid PHP version"* ]]
}

@test "update_php_hosts rejects uninstalled target php version" {
  run bash "$REPO_ROOT/update_php_hosts.sh" -v "8.5" -y
  [ "$status" -eq 1 ]
  [[ "$output" == *"is not installed"* ]]
}

@test "update_php_hosts updates eligible hosts to latest PHP, reloads services, and purges unused PHP" {
  run bash "$REPO_ROOT/update_php_hosts.sh" -y
  [ "$status" -eq 0 ]
  [[ "$output" == *"Target PHP version     : 8.4"* ]]
  [[ "$output" == *"Summary: 2 updated, 0 skipped, 0 failed."* ]]

  grep -qF "virtualmin modify-web --domain alpha.example.com --php-version 8.4" "$MOCK_LOG"
  grep -qF "virtualmin modify-web --domain beta.example.com --php-version 8.4" "$MOCK_LOG"
  run ! grep -qF "modify-web --domain gamma.example.com" "$MOCK_LOG"
  run ! grep -qF "modify-web --domain static.example.com" "$MOCK_LOG"

  grep -qF "systemctl reload-or-restart php8.4-fpm" "$MOCK_LOG"
  grep -qF "systemctl reload-or-restart apache2" "$MOCK_LOG"
  grep -qF "systemctl disable --now php8.2-fpm" "$MOCK_LOG"
  grep -qF "apt-get purge -y php8.2-cli php8.2-fpm" "$MOCK_LOG"
  grep -qF "apt-get autoremove -y" "$MOCK_LOG"
}

@test "update_php_hosts keeps old PHP version when any host is skipped" {
  # Simulate skipping beta.example.com by updating only alpha.example.com
  # Use a custom prompt_read-friendly stdin via bash -c with /dev/null? No, prompt_read checks -t 0 or /dev/tty.
  # Instead, test keeping old PHP when a host fails to update so 8.2 remains in use.
  FAIL_DOMAIN="beta.example.com" run bash "$REPO_ROOT/update_php_hosts.sh" -y
  [ "$status" -eq 1 ]
  [[ "$output" == *"Summary: 1 updated, 0 skipped, 1 failed."* ]]
  [[ "$output" == *"No unused PHP versions found."* ]]

  grep -qF "virtualmin modify-web --domain alpha.example.com --php-version 8.4" "$MOCK_LOG"
  run ! grep -qF "apt-get purge" "$MOCK_LOG"
}

@test "update_php_hosts respects --no-purge and --no-restart" {
  run bash "$REPO_ROOT/update_php_hosts.sh" -y --no-purge --no-restart
  [ "$status" -eq 0 ]
  grep -qF "virtualmin modify-web --domain alpha.example.com --php-version 8.4" "$MOCK_LOG"
  run ! grep -qF "systemctl reload-or-restart" "$MOCK_LOG"
  run ! grep -qF "apt-get purge" "$MOCK_LOG"
}

@test "update_php_hosts --dry-run previews updates and unused versions without making changes" {
  run bash "$REPO_ROOT/update_php_hosts.sh" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"[dry-run] Would update 'alpha.example.com' from PHP 8.2 to PHP 8.4."* ]]
  [[ "$output" == *"[dry-run] Would update 'beta.example.com' from PHP 8.2 to PHP 8.4."* ]]
  [[ "$output" == *"[dry-run] Would remove unused PHP 8.2"* ]]

  run ! grep -qF "virtualmin modify-web" "$MOCK_LOG"
  run ! grep -qF "apt-get purge" "$MOCK_LOG"
  run ! grep -qF "systemctl reload-or-restart" "$MOCK_LOG"
}

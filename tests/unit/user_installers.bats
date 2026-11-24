#!/usr/bin/env bats

bats_require_minimum_version 1.5.0
load test_helper

setup() {
  setup_test_env
  mock_uid 1000 testuser
  touch "$HOME/.bashrc" "$HOME/.zshrc"
}

teardown() {
  teardown_test_env
}

@test "install_antigen downloads from GitHub raw URL and updates .zshrc idempotently" {
  create_mock git 'exit 0'
  create_mock zsh 'exit 0'
  create_mock curl '
echo "curl $*" >>"$MOCK_LOG"
out=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "-o" ]]; then
    out="$2"
    shift 2
  else
    shift
  fi
done
echo "# fake antigen" >"$out"
'

  run bash "$REPO_ROOT/install_antigen.sh" --theme robbyrussell
  [ "$status" -eq 0 ]
  [ -f "$HOME/.antigen/antigen.zsh" ]
  grep -qF "raw.githubusercontent.com/zsh-users/antigen" "$MOCK_LOG"
  run ! grep -qF "git.io" "$MOCK_LOG"
  grep -qF "antigen theme robbyrussell" "$HOME/.zshrc"

  # Re-run with --force should not duplicate .zshrc block
  run bash "$REPO_ROOT/install_antigen.sh" --force
  [ "$status" -eq 0 ]
  local count
  count="$(grep -c ">>> antigen configuration >>>" "$HOME/.zshrc")"
  [ "$count" -eq 1 ]
}

@test "install_composer rejects empty or invalid SHA-384 signature" {
  create_mock php 'echo "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"'
  create_mock curl '
if [[ "$*" == *"installer.sig"* ]]; then
  echo ""
  exit 0
fi
out=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "-o" ]]; then out="$2"; shift 2; else shift; fi
done
echo "<?php echo 1;" >"$out"
'

  run bash "$REPO_ROOT/install_composer.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Invalid or empty expected SHA-384"* ]]
}

@test "install_composer installs into ~/.local/bin and updates rc files idempotently" {
  local sig="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  create_mock curl "
if [[ \"\$*\" == *\"installer.sig\"* ]]; then
  echo \"$sig\"
  exit 0
fi
out=\"\"
while [[ \$# -gt 0 ]]; do
  if [[ \"\$1\" == \"-o\" ]]; then out=\"\$2\"; shift 2; else shift; fi
done
echo '<?php' >\"\$out\"
"
  create_mock php "
if [[ \"\$1\" == \"-r\" ]]; then
  echo \"$sig\"
  exit 0
fi
install_dir=\"\"
for arg in \"\$@\"; do
  case \"\$arg\" in
    --install-dir=*) install_dir=\"\${arg#--install-dir=}\" ;;
  esac
done
cat >\"\${install_dir}/composer\" <<'BIN'
#!/usr/bin/env bash
echo \"Composer version 2.8.0\"
BIN
chmod +x \"\${install_dir}/composer\"
"

  run bash "$REPO_ROOT/install_composer.sh"
  [ "$status" -eq 0 ]
  [ -x "$HOME/.local/bin/composer" ]
  [[ "$output" == *"$HOME/.local/bin/composer"* ]]
  grep -qF '$HOME/.local/bin' "$HOME/.bashrc"
  grep -qF '$HOME/.local/bin' "$HOME/.zshrc"

  # Re-run should not duplicate PATH line
  run bash "$REPO_ROOT/install_composer.sh"
  [ "$status" -eq 0 ]
  [ "$(grep -c '\.local/bin' "$HOME/.bashrc")" -eq 1 ]
  [ "$(grep -c '\.local/bin' "$HOME/.zshrc")" -eq 1 ]
}

@test "install_nvm fails cleanly on empty GitHub API version" {
  create_mock git 'exit 0'
  create_mock curl 'echo "{}"'

  run bash "$REPO_ROOT/install_nvm.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"--version"* ]]
}

@test "install_nvm writes to HOME rc files (not relative CWD .bashrc) and respects idempotency" {
  create_mock git 'exit 0'
  create_mock curl '
out=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "-o" ]]; then out="$2"; shift 2; else shift; fi
done
if [[ -n "$out" ]]; then
  cat >"$out" <<"EOF"
#!/usr/bin/env bash
mkdir -p "$HOME/.nvm"
EOF
fi
'

  cd "$TEST_WORKDIR"
  run bash "$REPO_ROOT/install_nvm.sh" --version v0.40.3
  [ "$status" -eq 0 ]
  [ ! -f "$TEST_WORKDIR/.bashrc" ]
  grep -qF 'export NVM_DIR="$HOME/.nvm"' "$HOME/.bashrc"
  grep -qF 'export NVM_DIR="$HOME/.nvm"' "$HOME/.zshrc"

  # Re-run does not duplicate
  run bash "$REPO_ROOT/install_nvm.sh" --version v0.40.3
  [ "$status" -eq 0 ]
  [ "$(grep -c 'export NVM_DIR=' "$HOME/.bashrc")" -eq 1 ]
  [ "$(grep -c 'export NVM_DIR=' "$HOME/.zshrc")" -eq 1 ]
}

@test "install_wp_cli verifies SHA-512, installs to ~/.local/bin, and does not source .zshrc" {
  echo 'invalid bash syntax: (((' >"$HOME/.zshrc"

  local phar_payload="#!/usr/bin/env bash
echo 'WP-CLI 2.11.0'"
  local expected_sha
  expected_sha="$(printf '%s\n' "$phar_payload" | shasum -a 512 2>/dev/null | awk '{print $1}' || printf '%s\n' "$phar_payload" | sha512sum | awk '{print $1}')"

  create_mock php 'exit 0'
  create_mock sha512sum "echo \"$expected_sha  \$1\""
  create_mock curl "
out=\"\"
url=\"\"
while [[ \$# -gt 0 ]]; do
  if [[ \"\$1\" == \"-o\" ]]; then out=\"\$2\"; shift 2; else url=\"\$1\"; shift; fi
done
if [[ \"\$url\" == *\".sha512\" ]]; then
  echo \"$expected_sha\" >\"\$out\"
else
  cat >\"\$out\" <<'BIN'
#!/usr/bin/env bash
echo 'WP-CLI 2.11.0'
BIN
fi
"

  run bash "$REPO_ROOT/install_wp_cli.sh"
  [ "$status" -eq 0 ]
  [ -x "$HOME/.local/bin/wp" ]
  [[ "$output" == *"WP-CLI 2.11.0"* ]]
  grep -qF '$HOME/.local/bin' "$HOME/.bashrc"
  grep -qF '$HOME/.local/bin' "$HOME/.zshrc"

  # Re-run skips cleanly
  run bash "$REPO_ROOT/install_wp_cli.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already installed"* ]]
}

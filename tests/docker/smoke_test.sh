#!/usr/bin/env bash
set -euo pipefail

# Lightweight Debian container smoke test suite.
# Intended to run inside debian:bookworm and debian:trixie containers:
#   docker run --rm -v "$PWD:/workspace:ro" debian:bookworm bash /workspace/tests/docker/smoke_test.sh

WORKSPACE="${1:-/workspace}"

echo "==> Installing Debian test prerequisites..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  adduser \
  bats \
  ca-certificates \
  curl \
  git \
  openssh-client \
  php-cli \
  shellcheck \
  shfmt \
  sudo \
  unzip \
  zsh

echo "==> Running ShellCheck and shfmt..."
shellcheck -S warning "$WORKSPACE"/*.sh "$WORKSPACE"/tests/docker/*.sh
shfmt -i 2 -ci -d "$WORKSPACE"/*.sh "$WORKSPACE"/tests/docker/*.sh

echo "==> Running BATS unit tests inside $(grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '"')..."
bats "$WORKSPACE/tests/unit/"

echo "==> Smoke testing add_sudoer_with_ssh.sh (real user creation + SSH validation)..."
TMP_KEYS="$(mktemp -d)"
trap 'rm -rf "$TMP_KEYS"' EXIT
ssh-keygen -q -t ed25519 -N "" -f "$TMP_KEYS/id_ed25519"

bash "$WORKSPACE/add_sudoer_with_ssh.sh" \
  -u testdeploy \
  --ssh-key-file "$TMP_KEYS/id_ed25519.pub" \
  --disabled-password \
  --no-lock-root

id testdeploy
id -nG testdeploy | grep -qw sudo
test -s /home/testdeploy/.ssh/authorized_keys
test "$(stat -c '%a' /home/testdeploy/.ssh)" = "700"
test "$(stat -c '%a' /home/testdeploy/.ssh/authorized_keys)" = "600"

echo "==> Smoke testing user-scoped installers as 'testdeploy'..."
su - testdeploy -c 'touch "$HOME/.bashrc" "$HOME/.zshrc"'
su - testdeploy -c "bash '$WORKSPACE/install_antigen.sh'"
su - testdeploy -c 'test -s "$HOME/.antigen/antigen.zsh"'
su - testdeploy -c "bash '$WORKSPACE/install_composer.sh'"
su - testdeploy -c '"$HOME/.local/bin/composer" --version'
su - testdeploy -c "bash '$WORKSPACE/install_wp_cli.sh'"
su - testdeploy -c '"$HOME/.local/bin/wp" --version'
su - testdeploy -c "bash '$WORKSPACE/install_nvm.sh'"
su - testdeploy -c 'test -s "$HOME/.nvm/nvm.sh"'

echo "==> Verifying idempotent re-runs..."
su - testdeploy -c "bash '$WORKSPACE/install_antigen.sh'"
su - testdeploy -c "bash '$WORKSPACE/install_wp_cli.sh'"
su - testdeploy -c "bash '$WORKSPACE/install_nvm.sh' --version v0.40.3"

echo "==> All Debian smoke tests passed!"

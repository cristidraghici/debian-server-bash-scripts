#!/usr/bin/env bash
set -euo pipefail

# Install Composer into ~/.local/bin (or a custom directory) with SHA-384 verification.

ALLOW_ROOT=false
INSTALL_DIR="$HOME/.local/bin"
COMPOSER_VERSION=""
TMP_DIR=""

cleanup() {
  if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
    rm -rf "$TMP_DIR"
  fi
}
trap cleanup EXIT

usage() {
  cat <<'EOF'
Usage: install_composer.sh [OPTIONS]

Download, verify (SHA-384), and install Composer for the current user.

Options:
      --root                 Allow running as the root user
      --install-dir <path>   Installation directory (default: ~/.local/bin)
      --version <ver>        Install a specific Composer version (e.g. 2.8.1)
  -h, --help                 Show this help message and exit

Examples:
  ./install_composer.sh
  ./install_composer.sh --version 2.8.1
  ./install_composer.sh --install-dir "$HOME/bin"
EOF
}

die() {
  echo "Error: $*" >&2
  exit 1
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --root)
        ALLOW_ROOT=true
        shift
        ;;
      --install-dir)
        [[ $# -ge 2 ]] || die "Option $1 requires a value."
        INSTALL_DIR="$2"
        shift 2
        ;;
      --version)
        [[ $# -ge 2 ]] || die "Option $1 requires a value."
        COMPOSER_VERSION="$2"
        shift 2
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *)
        die "Unknown option: $1 (use --help for usage)"
        ;;
    esac
  done
}

check_dependencies() {
  local util
  for util in php curl; do
    if ! command -v "$util" >/dev/null 2>&1; then
      die "Required utility '$util' is not installed. Please install it and rerun this script."
    fi
  done
}

ensure_path_in_rc() {
  local rc_file="$1"
  local path_entry="$INSTALL_DIR"
  local export_line="export PATH=\"${INSTALL_DIR}:\$PATH\""

  if [[ "$INSTALL_DIR" == "$HOME/.local/bin" ]]; then
    export_line='export PATH="$HOME/.local/bin:$PATH"'
  fi

  if [[ ! -f "$rc_file" ]]; then
    return 0
  fi

  if grep -qF "$path_entry" "$rc_file" ||
    ([[ "$INSTALL_DIR" == "$HOME/.local/bin" ]] && grep -qF '$HOME/.local/bin' "$rc_file"); then
    return 0
  fi

  printf '\n%s\n' "$export_line" >>"$rc_file"
  echo "Added $INSTALL_DIR to PATH in $rc_file. Restart your shell or source it to apply."
}

main() {
  parse_args "$@"

  if [[ "$(id -u)" -eq 0 && "$ALLOW_ROOT" != true ]]; then
    die "Please run as a regular user, or pass --root to explicitly allow running as root."
  fi

  check_dependencies

  if [[ -n "$COMPOSER_VERSION" && ! "$COMPOSER_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][a-zA-Z0-9]+)?$ ]]; then
    die "Invalid Composer version '$COMPOSER_VERSION'."
  fi

  echo "Installing Composer for user $(id -un) into $INSTALL_DIR..."

  TMP_DIR="$(mktemp -d)"
  local setup_file="$TMP_DIR/composer-setup.php"

  if ! curl -fsSL "https://getcomposer.org/installer" -o "$setup_file"; then
    die "Failed to download Composer installer."
  fi

  local expected_signature actual_signature
  expected_signature="$(curl -fsSL "https://composer.github.io/installer.sig" | tr -d '[:space:]')"
  if [[ ! "$expected_signature" =~ ^[0-9a-fA-F]{96}$ ]]; then
    die "Invalid or empty expected SHA-384 signature from composer.github.io."
  fi

  actual_signature="$(php -r 'echo hash_file("sha384", $argv[1]);' "$setup_file")"
  if [[ "$expected_signature" != "$actual_signature" ]]; then
    die "Composer installer SHA-384 signature mismatch."
  fi

  mkdir -p "$INSTALL_DIR"

  local installer_args=(--quiet "--install-dir=$INSTALL_DIR" --filename=composer)
  if [[ -n "$COMPOSER_VERSION" ]]; then
    installer_args+=("--version=$COMPOSER_VERSION")
  fi

  if ! php "$setup_file" "${installer_args[@]}"; then
    die "Composer installation failed."
  fi

  local composer_bin="$INSTALL_DIR/composer"
  if [[ ! -x "$composer_bin" ]]; then
    die "Expected Composer binary not found at $composer_bin."
  fi

  echo "Composer installed successfully at $composer_bin."
  COMPOSER_ALLOW_SUPERUSER=1 "$composer_bin" --version

  ensure_path_in_rc "$HOME/.bashrc"
  ensure_path_in_rc "$HOME/.zshrc"
}

main "$@"

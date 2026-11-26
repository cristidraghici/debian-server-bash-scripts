#!/usr/bin/env bash
set -euo pipefail

# Install WP-CLI into ~/.local/bin (or a custom directory) with SHA-512 verification.

ALLOW_ROOT=false
FORCE=false
INSTALL_DIR="$HOME/.local/bin"
WP_CLI_URL="https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar"
WP_CLI_SHA_URL="https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar.sha512"
TMP_DIR=""

cleanup() {
  if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
    rm -rf "$TMP_DIR"
  fi
}
trap cleanup EXIT

usage() {
  cat <<'EOF'
Usage: install_wp_cli.sh [OPTIONS]

Download, verify (SHA-512), and install WP-CLI for the current user.

Options:
      --root                 Allow running as the root user
      --force                Reinstall/overwrite an existing wp binary
      --install-dir <path>   Installation directory (default: ~/.local/bin)
  -h, --help                 Show this help message and exit

Examples:
  ./install_wp_cli.sh
  ./install_wp_cli.sh --force
  ./install_wp_cli.sh --install-dir "$HOME/bin"
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
      --force)
        FORCE=true
        shift
        ;;
      --install-dir)
        [[ $# -ge 2 ]] || die "Option $1 requires a value."
        INSTALL_DIR="$2"
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
  for util in curl php sha512sum; do
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
    die "Please run as a regular user, or pass --root to explicitly allow running as root (when piped: ... | bash -s -- --root)."
  fi

  check_dependencies

  local wp_cli_file="$INSTALL_DIR/wp"
  if [[ -x "$wp_cli_file" && "$FORCE" != true ]]; then
    echo "WP-CLI is already installed at $wp_cli_file (use --force to reinstall)."
    exit 0
  fi

  TMP_DIR="$(mktemp -d)"
  local phar_file="$TMP_DIR/wp-cli.phar"
  local sha_file="$TMP_DIR/wp-cli.phar.sha512"

  echo "Downloading WP-CLI..."
  if ! curl -fsSL "$WP_CLI_URL" -o "$phar_file"; then
    die "Failed to download WP-CLI from $WP_CLI_URL."
  fi

  if ! curl -fsSL "$WP_CLI_SHA_URL" -o "$sha_file"; then
    die "Failed to download WP-CLI SHA-512 checksum from $WP_CLI_SHA_URL."
  fi

  local expected_sha actual_sha
  expected_sha="$(awk '{print $1}' "$sha_file" | tr -d '[:space:]')"
  if [[ ! "$expected_sha" =~ ^[0-9a-fA-F]{128}$ ]]; then
    die "Invalid or empty SHA-512 checksum downloaded for WP-CLI."
  fi

  actual_sha="$(sha512sum "$phar_file" | awk '{print $1}')"
  if [[ "$expected_sha" != "$actual_sha" ]]; then
    die "WP-CLI SHA-512 checksum mismatch."
  fi

  mkdir -p "$INSTALL_DIR"
  chmod 755 "$phar_file"
  mv "$phar_file" "$wp_cli_file"

  ensure_path_in_rc "$HOME/.bashrc"
  ensure_path_in_rc "$HOME/.zshrc"

  echo "WP-CLI installed successfully at $wp_cli_file."
  if [[ "$(id -u)" -eq 0 ]]; then
    "$wp_cli_file" --allow-root --version
  else
    "$wp_cli_file" --version
  fi
}

main "$@"

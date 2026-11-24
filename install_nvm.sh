#!/usr/bin/env bash
set -euo pipefail

# Install NVM (Node Version Manager) for the current user and configure
# ~/.bashrc and ~/.zshrc idempotently.

ALLOW_ROOT=false
NVM_VERSION=""
NO_RC=false
TMP_DIR=""

cleanup() {
  if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
    rm -rf "$TMP_DIR"
  fi
}
trap cleanup EXIT

usage() {
  cat <<'EOF'
Usage: install_nvm.sh [OPTIONS]

Download and install the latest (or specified) version of NVM for the
current user and configure shell startup files idempotently.

Options:
      --root               Allow running as the root user
      --version <vX.Y.Z>   Install a specific NVM version tag (skips GitHub API lookup)
      --no-rc              Do not modify ~/.bashrc or ~/.zshrc
  -h, --help               Show this help message and exit

Examples:
  ./install_nvm.sh
  ./install_nvm.sh --version v0.40.3
  ./install_nvm.sh --no-rc
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
      --version)
        [[ $# -ge 2 ]] || die "Option $1 requires a value."
        NVM_VERSION="$2"
        shift 2
        ;;
      --no-rc)
        NO_RC=true
        shift
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
  for util in curl git; do
    if ! command -v "$util" >/dev/null 2>&1; then
      die "Required utility '$util' is not installed. Please install it and rerun this script."
    fi
  done
}

resolve_nvm_version() {
  if [[ -n "$NVM_VERSION" ]]; then
    if [[ ! "$NVM_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      die "Invalid NVM version '$NVM_VERSION'. Expected format like 'v0.40.3'."
    fi
    return 0
  fi

  local api_response
  if ! api_response="$(curl -fsSL "https://api.github.com/repos/nvm-sh/nvm/releases/latest")"; then
    die "Failed to query GitHub API for latest NVM release. Retry with --version vX.Y.Z."
  fi

  NVM_VERSION="$(printf '%s\n' "$api_response" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
  if [[ ! "$NVM_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    die "Could not parse a valid NVM version tag from GitHub API (rate limited?). Retry with --version vX.Y.Z."
  fi
}

configure_rc_file() {
  local rc_file="$1"
  if [[ ! -f "$rc_file" ]]; then
    return 0
  fi

  if grep -qF "NVM_DIR" "$rc_file"; then
    echo "NVM configuration already present in $rc_file; skipping update."
    return 0
  fi

  cat >>"$rc_file" <<'EOF'

export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"  # This loads nvm bash_completion
EOF
  echo "Added NVM configuration to $rc_file. Restart your shell or source it to apply."
}

main() {
  parse_args "$@"

  if [[ "$(id -u)" -eq 0 && "$ALLOW_ROOT" != true ]]; then
    die "Please run as a regular user, or pass --root to explicitly allow running as root."
  fi

  check_dependencies
  resolve_nvm_version

  echo "Installing NVM ${NVM_VERSION} for user $(id -un)..."

  TMP_DIR="$(mktemp -d)"
  local install_script="$TMP_DIR/nvm-install.sh"
  local install_url="https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh"

  if ! curl -fsSL "$install_url" -o "$install_script"; then
    die "Failed to download NVM install script from $install_url."
  fi

  if [[ ! -s "$install_script" ]]; then
    die "Downloaded NVM install script is empty."
  fi

  # Prevent NVM's own installer from duplicating RC entries; handle RC files cleanly below.
  PROFILE=/dev/null bash "$install_script"

  if [[ "$NO_RC" != true ]]; then
    configure_rc_file "$HOME/.bashrc"
    configure_rc_file "$HOME/.zshrc"
  fi

  echo "NVM ${NVM_VERSION} installation complete."
}

main "$@"

#!/usr/bin/env bash
set -euo pipefail

# Install and configure Antigen for Zsh in the current user's home directory.

ALLOW_ROOT=false
FORCE=false
THEME="bira"
ANTIGEN_URL="https://raw.githubusercontent.com/zsh-users/antigen/master/bin/antigen.zsh"
TMP_DIR=""

cleanup() {
  if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
    rm -rf "$TMP_DIR"
  fi
}
trap cleanup EXIT

usage() {
  cat <<'EOF'
Usage: install_antigen.sh [OPTIONS]

Install Antigen for Zsh into ~/.antigen and configure ~/.zshrc idempotently.

Options:
      --root           Allow running as the root user
      --force          Re-download antigen.zsh even if already installed
      --theme <name>   Antigen theme to configure (default: bira)
  -h, --help           Show this help message and exit

Examples:
  ./install_antigen.sh
  ./install_antigen.sh --theme robbyrussell
  ./install_antigen.sh --force
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
      --theme)
        [[ $# -ge 2 ]] || die "Option $1 requires a value."
        THEME="$2"
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
  for util in git zsh curl; do
    if ! command -v "$util" >/dev/null 2>&1; then
      die "Required utility '$util' is not installed. Please install it and rerun this script."
    fi
  done
}

configure_zshrc() {
  local zshrc="$HOME/.zshrc"
  local marker="# >>> antigen configuration >>>"

  if [[ -f "$zshrc" ]] && (grep -qF "$marker" "$zshrc" || grep -qF "antigen.zsh" "$zshrc"); then
    echo "Antigen configuration already present in $zshrc; skipping update."
    return 0
  fi

  touch "$zshrc"
  cat >>"$zshrc" <<EOF

# >>> antigen configuration >>>
source "\$HOME/.antigen/antigen.zsh"
antigen use oh-my-zsh

antigen bundle git
antigen bundle command-not-found
antigen bundle zsh-users/zsh-syntax-highlighting
antigen bundle zsh-users/zsh-autosuggestions

antigen theme ${THEME}
antigen apply
# <<< antigen configuration <<<
EOF
  echo "Updated $zshrc with Antigen configuration."
}

main() {
  parse_args "$@"

  if [[ "$(id -u)" -eq 0 && "$ALLOW_ROOT" != true ]]; then
    die "Please run as a regular user, or pass --root to explicitly allow running as root."
  fi

  check_dependencies

  if [[ ! "$THEME" =~ ^[a-zA-Z0-9_./-]+$ ]]; then
    die "Invalid theme name '$THEME'."
  fi

  local antigen_dir="$HOME/.antigen"
  local antigen_file="$antigen_dir/antigen.zsh"

  if [[ -f "$antigen_file" && "$FORCE" != true ]]; then
    echo "Antigen is already installed at $antigen_file (use --force to reinstall)."
    exit 0
  fi

  TMP_DIR="$(mktemp -d)"
  echo "Downloading Antigen from $ANTIGEN_URL..."
  if ! curl -fsSL "$ANTIGEN_URL" -o "$TMP_DIR/antigen.zsh"; then
    die "Failed to download Antigen from $ANTIGEN_URL."
  fi

  if [[ ! -s "$TMP_DIR/antigen.zsh" ]]; then
    die "Downloaded Antigen script is empty."
  fi

  mkdir -p "$antigen_dir"
  mv "$TMP_DIR/antigen.zsh" "$antigen_file"

  configure_zshrc

  local current_user
  current_user="$(id -un)"
  if [[ "${SHELL:-}" == *"/zsh" ]]; then
    echo "Antigen has been installed and configured for user $current_user."
    echo "Restart your terminal or run 'source ~/.zshrc' to apply changes."
  else
    echo "Antigen has been installed for user $current_user, but the current shell is not Zsh."
    echo "Switch to Zsh or run 'chsh -s \"\$(command -v zsh)\"' to set Zsh as your default shell."
  fi
}

main "$@"

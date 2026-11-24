#!/usr/bin/env bash
set -euo pipefail

# Create a new Debian sudoer user with validated SSH public key(s)
# and optional root account locking.

USERNAME=""
SSH_KEYS=()
SSH_KEY_FILE=""
LOCK_ROOT="ask"
DISABLED_PASSWORD=false
TMP_DIR=""

cleanup() {
  if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
    rm -rf "$TMP_DIR"
  fi
}
trap cleanup EXIT

usage() {
  cat <<'EOF'
Usage: add_sudoer_with_ssh.sh [OPTIONS]

Create a new Debian user in the 'sudo' group, configure validated SSH
authorized_keys, and optionally lock the root account password.

Options:
  -u, --user <name>        Username for the new sudoer account
  -k, --ssh-key <key>      SSH public key string (may be passed multiple times)
      --ssh-key-file <f>   Path to a file containing SSH public key(s)
      --disabled-password  Create user without prompting for a login password
      --lock-root          Lock the root account password after setup
      --no-lock-root       Do not lock the root account (skip confirmation)
  -h, --help               Show this help message and exit

Examples:
  sudo ./add_sudoer_with_ssh.sh
  sudo ./add_sudoer_with_ssh.sh -u deploy --ssh-key-file ~/.ssh/id_ed25519.pub --disabled-password
  sudo ./add_sudoer_with_ssh.sh -u admin -k "ssh-ed25519 AAAA... user@host" --lock-root
EOF
}

die() {
  echo "Error: $*" >&2
  exit 1
}

prompt_read() {
  local prompt_text="$1"
  local var_name="$2"
  local tty_input=""
  if [[ -t 0 ]]; then
    read -r -p "$prompt_text" tty_input
  elif [[ -r /dev/tty ]]; then
    read -r -p "$prompt_text" tty_input </dev/tty
  else
    die "Non-interactive shell detected. Pass required values via CLI flags (see --help)."
  fi
  printf -v "$var_name" '%s' "$tty_input"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -u | --user)
        [[ $# -ge 2 ]] || die "Option $1 requires a value."
        USERNAME="$2"
        shift 2
        ;;
      -k | --ssh-key)
        [[ $# -ge 2 ]] || die "Option $1 requires a value."
        SSH_KEYS+=("$2")
        shift 2
        ;;
      --ssh-key-file)
        [[ $# -ge 2 ]] || die "Option $1 requires a value."
        SSH_KEY_FILE="$2"
        shift 2
        ;;
      --disabled-password)
        DISABLED_PASSWORD=true
        shift
        ;;
      --lock-root)
        if [[ "$LOCK_ROOT" == "no" ]]; then
          die "Cannot specify both --lock-root and --no-lock-root."
        fi
        LOCK_ROOT="yes"
        shift
        ;;
      --no-lock-root)
        if [[ "$LOCK_ROOT" == "yes" ]]; then
          die "Cannot specify both --lock-root and --no-lock-root."
        fi
        LOCK_ROOT="no"
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
  for util in adduser usermod getent ssh-keygen passwd; do
    if ! command -v "$util" >/dev/null 2>&1; then
      die "Required utility '$util' is not installed."
    fi
  done

  if ! getent group sudo >/dev/null 2>&1; then
    die "The 'sudo' group does not exist. Please install the 'sudo' package first."
  fi
}

validate_username() {
  local user="$1"
  if [[ -z "$user" ]]; then
    die "Username cannot be empty."
  fi
  if [[ "$user" == "root" ]]; then
    die "Refusing to create or overwrite 'root'."
  fi
  if [[ ! "$user" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
    die "Invalid username '$user'. Use lowercase letters, digits, '-' or '_' (max 32 chars, starting with a letter or '_')."
  fi
  if id "$user" >/dev/null 2>&1; then
    die "User '$user' already exists."
  fi
}

collect_and_validate_keys() {
  local raw_keys_file="$TMP_DIR/raw_keys.pub"
  local valid_keys_file="$TMP_DIR/valid_keys.pub"
  local single_key_file="$TMP_DIR/single_key.pub"
  : >"$raw_keys_file"
  : >"$valid_keys_file"

  if [[ -n "$SSH_KEY_FILE" ]]; then
    [[ -r "$SSH_KEY_FILE" ]] || die "SSH key file '$SSH_KEY_FILE' does not exist or is not readable."
    cat "$SSH_KEY_FILE" >>"$raw_keys_file"
    printf '\n' >>"$raw_keys_file"
  fi

  if [[ ${#SSH_KEYS[@]} -gt 0 ]]; then
    local key
    for key in "${SSH_KEYS[@]}"; do
      printf '%s\n' "$key" >>"$raw_keys_file"
    done
  fi

  if [[ -z "$SSH_KEY_FILE" && ${#SSH_KEYS[@]} -eq 0 ]]; then
    echo "Please paste the public SSH key(s), then press Ctrl-D:"
    if [[ -t 0 ]]; then
      cat >>"$raw_keys_file"
    elif [[ -r /dev/tty ]]; then
      cat </dev/tty >>"$raw_keys_file"
    else
      die "Non-interactive shell detected. Provide SSH keys via --ssh-key or --ssh-key-file."
    fi
  fi

  local key_count=0
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    # Strip leading/trailing whitespace and CR
    line="${line%$'\r'}"
    if [[ -z "${line//[[:space:]]/}" ]] || [[ "$line" =~ ^[[:space:]]*# ]]; then
      continue
    fi
    printf '%s\n' "$line" >"$single_key_file"
    if ! ssh-keygen -lf "$single_key_file" >/dev/null 2>&1; then
      die "Invalid SSH public key detected: ${line:0:40}..."
    fi
    printf '%s\n' "$line" >>"$valid_keys_file"
    key_count=$((key_count + 1))
  done <"$raw_keys_file"

  if [[ "$key_count" -eq 0 ]]; then
    die "No valid SSH public keys provided. Aborting without creating user."
  fi

  echo "Validated $key_count SSH public key(s)."
}

lock_root_if_requested() {
  local root_shadow
  root_shadow="$(awk -F: '$1 == "root" { print $2 }' /etc/shadow 2>/dev/null || true)"
  if [[ "$root_shadow" == '!'* || "$root_shadow" == '*'* ]]; then
    echo "The root account is already locked."
    return 0
  fi

  case "$LOCK_ROOT" in
    yes)
      passwd -l root
      echo "Root account password has been locked."
      ;;
    no)
      echo "Skipping root account lock (--no-lock-root)."
      ;;
    ask)
      local confirm=""
      prompt_read "Lock the root account password now? Verify SSH access as '$USERNAME' first [y/N]: " confirm
      if [[ "$confirm" =~ ^[Yy]$ ]]; then
        passwd -l root
        echo "Root account password has been locked."
      else
        echo "Root account was left unlocked."
      fi
      ;;
  esac
}

main() {
  parse_args "$@"

  if [[ "$(id -u)" -ne 0 ]]; then
    die "This script must be run as root."
  fi

  check_dependencies

  if [[ -z "$USERNAME" ]]; then
    prompt_read "Enter the new sudo user's name: " USERNAME
  fi
  validate_username "$USERNAME"

  TMP_DIR="$(mktemp -d)"
  collect_and_validate_keys

  # Use --comment on Debian 12+, falling back to --gecos on older adduser
  local comment_flag="--gecos"
  if adduser --help 2>&1 | grep -q -- '--comment'; then
    comment_flag="--comment"
  fi

  local adduser_args=("$comment_flag" "")
  if [[ "$DISABLED_PASSWORD" == true ]]; then
    adduser_args+=("--disabled-password")
    adduser "${adduser_args[@]}" "$USERNAME"
  elif [[ -t 0 ]]; then
    adduser "${adduser_args[@]}" "$USERNAME"
  elif [[ -r /dev/tty ]]; then
    adduser "${adduser_args[@]}" "$USERNAME" </dev/tty
  else
    die "Non-interactive shell requires --disabled-password when creating a user."
  fi

  usermod -aG sudo "$USERNAME"

  local user_home
  user_home="$(getent passwd "$USERNAME" | cut -d: -f6)"
  if [[ -z "$user_home" || ! -d "$user_home" ]]; then
    die "Could not resolve home directory for user '$USERNAME'."
  fi

  mkdir -p "$user_home/.ssh"
  cp "$TMP_DIR/valid_keys.pub" "$user_home/.ssh/authorized_keys"
  chmod 700 "$user_home/.ssh"
  chmod 600 "$user_home/.ssh/authorized_keys"
  chown -R "$USERNAME:$USERNAME" "$user_home/.ssh"

  if [[ ! -s "$user_home/.ssh/authorized_keys" ]]; then
    die "Failed to write SSH authorized_keys for '$USERNAME'."
  fi

  echo "User '$USERNAME' created with sudo privileges and SSH key authentication."
  lock_root_if_requested
}

main "$@"

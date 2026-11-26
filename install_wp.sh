#!/usr/bin/env bash
set -euo pipefail

# Standalone WordPress installer for Debian servers.
# Downloads WordPress core + unpinned plugins/themes, generates wp-config.php
# with fresh authentication salts, and protects the defaults file.

ALLOW_ROOT=false
DB_HOST="localhost"
DB_NAME=""
DB_USER=""
DB_PASS="${WP_DB_PASS:-}"
DEST_DIR=""
DEFAULTS_FILE=".wp_install_defaults"
NO_PLUGINS=false
ASSUME_YES=false
DB_CLIENT=""
TMP_DIR=""

PLUGINS=()
THEMES=()

DEFAULT_PLUGINS=(
  "password-protected"
  "wordpress-seo"
  "wp-dashboard-notes"
  "sucuri-scanner"
  "simple-page-ordering"
  "regenerate-thumbnails"
  "litespeed-cache"
  "login-recaptcha"
  "limit-login-attempts-reloaded"
  "just-an-admin-button"
  "instant-images"
  "health-check"
  "wpcf7-redirect"
  "contact-form-cfdb7"
  "contact-form-7"
  "child-theme-wizard"
)

RED="0;31"
GREEN="0;32"
YELLOW="0;33"
BLUE="0;34"

cleanup() {
  if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
    rm -rf "$TMP_DIR"
  fi
}
trap cleanup EXIT

usage() {
  cat <<'EOF'
Usage: install_wp.sh [OPTIONS]

Download and configure a standalone WordPress installation with plugins,
themes, fresh authentication salts, and safe wp-config.php generation.

Options:
      --root                  Allow running as the root user
      --db-host <host>        Database host (default: localhost)
      --db-name <name>        Database name
      --db-user <user>        Database username (defaults to database name)
      --db-pass <pass>        Database password (or set WP_DB_PASS env var)
      --dest <dir>            Destination directory (default: ./wordpress)
      --defaults-file <path>  Plugin/theme defaults file (default: .wp_install_defaults)
      --no-plugins            Skip installing plugins
  -y, --yes                   Skip confirmation prompt
  -h, --help                  Show this help message and exit

Defaults file format (one entry per line, # comments allowed):
  plugin:<wordpress-org-slug-or-zip-url>
  theme:<wordpress-org-slug-or-zip-url>

Examples:
  ./install_wp.sh
  WP_DB_PASS='s3cr3t' ./install_wp.sh --db-name wp_site --db-user wp_user --dest /var/www/site -y
EOF
}

colored_echo() {
  local color_code="$1"
  local message="$2"
  if [[ -t 1 ]]; then
    printf '\033[%sm%s\033[0m\n' "$color_code" "$message"
  else
    printf '%s\n' "$message"
  fi
}

die() {
  colored_echo "$RED" "Error: $*" >&2
  exit 1
}

prompt_read() {
  local prompt_text="$1"
  local var_name="$2"
  local silent="${3:-false}"
  local tty_input=""

  if [[ -t 0 ]]; then
    if [[ "$silent" == true ]]; then
      read -r -s -p "$prompt_text" tty_input
      echo
    else
      read -r -p "$prompt_text" tty_input
    fi
  elif [[ -r /dev/tty ]]; then
    if [[ "$silent" == true ]]; then
      read -r -s -p "$prompt_text" tty_input </dev/tty
      echo
    else
      read -r -p "$prompt_text" tty_input </dev/tty
    fi
  else
    die "Non-interactive shell detected. Pass required values via CLI flags (see --help)."
  fi

  printf -v "$var_name" '%s' "$tty_input"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --root)
        ALLOW_ROOT=true
        shift
        ;;
      --db-host)
        [[ $# -ge 2 ]] || die "Option $1 requires a value."
        DB_HOST="$2"
        shift 2
        ;;
      --db-name)
        [[ $# -ge 2 ]] || die "Option $1 requires a value."
        DB_NAME="$2"
        shift 2
        ;;
      --db-user)
        [[ $# -ge 2 ]] || die "Option $1 requires a value."
        DB_USER="$2"
        shift 2
        ;;
      --db-pass)
        [[ $# -ge 2 ]] || die "Option $1 requires a value."
        DB_PASS="$2"
        shift 2
        ;;
      --dest)
        [[ $# -ge 2 ]] || die "Option $1 requires a value."
        DEST_DIR="$2"
        shift 2
        ;;
      --defaults-file)
        [[ $# -ge 2 ]] || die "Option $1 requires a value."
        DEFAULTS_FILE="$2"
        shift 2
        ;;
      --no-plugins)
        NO_PLUGINS=true
        shift
        ;;
      -y | --yes)
        ASSUME_YES=true
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
  for util in curl unzip; do
    if ! command -v "$util" >/dev/null 2>&1; then
      die "Required utility '$util' is not installed. Please install it and rerun this script."
    fi
  done

  if command -v mariadb >/dev/null 2>&1; then
    DB_CLIENT="mariadb"
  elif command -v mysql >/dev/null 2>&1; then
    DB_CLIENT="mysql"
  else
    die "Neither 'mariadb' nor 'mysql' client is installed. Please install mariadb-client."
  fi
}

load_defaults() {
  if [[ -f "$DEFAULTS_FILE" ]]; then
    local line key value
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line%$'\r'}"
      # Trim leading/trailing whitespace
      line="${line#"${line%%[![:space:]]*}"}"
      line="${line%"${line##*[![:space:]]}"}"
      if [[ -z "$line" || "$line" == \#* ]]; then
        continue
      fi
      key="${line%%:*}"
      value="${line#*:}"
      case "$key" in
        plugin)
          [[ -n "$value" ]] && PLUGINS+=("$value")
          ;;
        theme)
          [[ -n "$value" ]] && THEMES+=("$value")
          ;;
        *)
          colored_echo "$YELLOW" "Warning: Ignoring unrecognized defaults entry: $line"
          ;;
      esac
    done <"$DEFAULTS_FILE"
  else
    PLUGINS=("${DEFAULT_PLUGINS[@]}")
    THEMES=()
  fi
}

save_defaults() {
  local target_file="$1"
  {
    echo "# WordPress install defaults (one entry per line)"
    echo "# Format: plugin:<slug-or-url> or theme:<slug-or-url>"
    local item
    if [[ ${#PLUGINS[@]} -gt 0 ]]; then
      for item in "${PLUGINS[@]}"; do
        printf 'plugin:%s\n' "$item"
      done
    fi
    if [[ ${#THEMES[@]} -gt 0 ]]; then
      for item in "${THEMES[@]}"; do
        printf 'theme:%s\n' "$item"
      done
    fi
  } >"$target_file"
}

resolve_asset_url() {
  local asset_type="$1"
  local item="$2"
  if [[ "$item" =~ ^https?:// ]]; then
    printf '%s\n' "$item"
    return 0
  fi
  if [[ "$item" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    printf 'https://downloads.wordpress.org/%s/%s.zip\n' "$asset_type" "$item"
    return 0
  fi
  return 1
}

test_db_credentials() {
  MYSQL_PWD="$DB_PASS" "$DB_CLIENT" \
    -h "$DB_HOST" \
    -u "$DB_USER" \
    "$DB_NAME" \
    -e "SELECT 1;" >/dev/null 2>&1
}

download_and_unzip() {
  local url="$1"
  local destination="$2"
  local archive_file="$TMP_DIR/download.zip"

  colored_echo "$GREEN" "Downloading $url..."
  if ! curl -fsSL "$url" -o "$archive_file"; then
    colored_echo "$RED" "Failed to download $url." >&2
    rm -f "$archive_file"
    return 1
  fi

  if ! unzip -q -o "$archive_file" -d "$destination"; then
    colored_echo "$RED" "Failed to unzip archive from $url." >&2
    rm -f "$archive_file"
    return 1
  fi

  rm -f "$archive_file"
  return 0
}

php_single_quote_escape() {
  local val="$1"
  local out=""
  local i ch
  for ((i = 0; i < ${#val}; i++)); do
    ch="${val:i:1}"
    if [[ "$ch" == '\' || "$ch" == "'" ]]; then
      out+="\\${ch}"
    else
      out+="$ch"
    fi
  done
  printf '%s' "$out"
}

generate_wp_salts() {
  local salts=""
  if salts="$(curl -fsSL "https://api.wordpress.org/secret-key/1.1/salt/" 2>/dev/null)" &&
    [[ "$salts" == *"AUTH_KEY"* && "$salts" == *"NONCE_SALT"* ]]; then
    printf '%s\n' "$salts"
    return 0
  fi

  colored_echo "$YELLOW" "Warning: Could not fetch salts from api.wordpress.org; generating local random salts." >&2
  local key_name secret
  for key_name in \
    AUTH_KEY SECURE_AUTH_KEY LOGGED_IN_KEY NONCE_KEY \
    AUTH_SALT SECURE_AUTH_SALT LOGGED_IN_SALT NONCE_SALT; do
    if command -v openssl >/dev/null 2>&1; then
      secret="$(openssl rand -base64 48 | tr -d '\n' | tr "'" '_')"
    else
      secret="$(LC_ALL=C tr -dc 'A-Za-z0-9!@#%^&*()-_=+[]{}|;:,.<>?' </dev/urandom | head -c 64)"
    fi
    printf "define( '%s', '%s' );\n" "$key_name" "$secret"
  done
}

create_wp_config() {
  local wp_dir="$1"
  local sample_file="$wp_dir/wp-config-sample.php"
  local config_file="$wp_dir/wp-config.php"

  [[ -f "$sample_file" ]] || die "Expected $sample_file was not found."

  local esc_name esc_user esc_pass esc_host salts_block
  esc_name="$(php_single_quote_escape "$DB_NAME")"
  esc_user="$(php_single_quote_escape "$DB_USER")"
  esc_pass="$(php_single_quote_escape "$DB_PASS")"
  esc_host="$(php_single_quote_escape "$DB_HOST")"
  salts_block="$(generate_wp_salts)"

  local salts_written=false
  local line
  : >"$config_file"

  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      *"define("*\'DB_NAME\'*)
        printf "define( 'DB_NAME', '%s' );\n" "$esc_name" >>"$config_file"
        ;;
      *"define("*\'DB_USER\'*)
        printf "define( 'DB_USER', '%s' );\n" "$esc_user" >>"$config_file"
        ;;
      *"define("*\'DB_PASSWORD\'*)
        printf "define( 'DB_PASSWORD', '%s' );\n" "$esc_pass" >>"$config_file"
        ;;
      *"define("*\'DB_HOST\'*)
        printf "define( 'DB_HOST', '%s' );\n" "$esc_host" >>"$config_file"
        ;;
      *"define("*\'AUTH_KEY\'* | *"define("*\'SECURE_AUTH_KEY\'* | *"define("*\'LOGGED_IN_KEY\'* | *"define("*\'NONCE_KEY\'* | \
        *"define("*\'AUTH_SALT\'* | *"define("*\'SECURE_AUTH_SALT\'* | *"define("*\'LOGGED_IN_SALT\'* | *"define("*\'NONCE_SALT\'*)
        if [[ "$salts_written" == false ]]; then
          printf '%s\n' "$salts_block" >>"$config_file"
          salts_written=true
        fi
        ;;
      *)
        printf '%s\n' "$line" >>"$config_file"
        ;;
    esac
  done <"$sample_file"

  chmod 640 "$config_file"
}

update_htaccess() {
  local wp_dir="$1"
  local htaccess_file="$wp_dir/.htaccess"
  local defaults_basename
  defaults_basename="$(basename "$DEFAULTS_FILE")"

  if [[ -f "$htaccess_file" ]] && grep -qF "$defaults_basename" "$htaccess_file"; then
    return 0
  fi

  cat >>"$htaccess_file" <<EOF

# Deny web access to WordPress install defaults file (Apache 2.4+)
<Files "${defaults_basename}">
  Require all denied
</Files>
EOF
}

main() {
  parse_args "$@"

  if [[ "$(id -u)" -eq 0 && "$ALLOW_ROOT" != true ]]; then
    die "This script should not be run as root for security reasons (pass --root to override; when piped: ... | bash -s -- --root)."
  fi

  check_dependencies
  load_defaults

  if [[ -z "$DB_NAME" ]]; then
    colored_echo "$YELLOW" "Provide the database connection credentials"
    local input_host=""
    prompt_read "Enter database address [default: $DB_HOST]: " input_host
    if [[ -n "$input_host" ]]; then
      DB_HOST="$input_host"
    fi
    prompt_read "Enter database name: " DB_NAME
  fi

  [[ -n "$DB_NAME" ]] || die "Database name cannot be empty."

  if [[ -z "$DB_USER" ]]; then
    if [[ "$ASSUME_YES" == true ]]; then
      DB_USER="$DB_NAME"
    else
      local input_user=""
      prompt_read "Enter database username [default: $DB_NAME]: " input_user
      DB_USER="${input_user:-$DB_NAME}"
    fi
  fi

  if [[ -z "$DB_PASS" && "$ASSUME_YES" != true ]]; then
    prompt_read "Enter database password: " DB_PASS true
  fi

  if ! test_db_credentials; then
    die "Invalid database credentials or database '$DB_NAME' is unreachable on '$DB_HOST'."
  fi
  colored_echo "$GREEN" "Database credentials verified."

  if [[ -z "$DEST_DIR" ]]; then
    if [[ "$ASSUME_YES" == true ]]; then
      DEST_DIR="./wordpress"
    else
      local input_dest=""
      prompt_read "Enter destination path for WordPress [default: ./wordpress]: " input_dest
      DEST_DIR="${input_dest:-./wordpress}"
    fi
  fi

  if [[ -f "$DEST_DIR/wp-config.php" ]]; then
    die "Destination '$DEST_DIR' already contains a wp-config.php file. Aborting to avoid overwriting an existing site."
  fi

  if [[ "$ASSUME_YES" != true ]]; then
    local confirm=""
    prompt_read "Proceed with WordPress installation into '$DEST_DIR'? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
      die "Installation aborted."
    fi
  fi

  TMP_DIR="$(mktemp -d)"
  download_and_unzip "https://wordpress.org/latest.zip" "$TMP_DIR" || die "Failed to download WordPress core."

  local stage_wp="$TMP_DIR/wordpress"
  [[ -d "$stage_wp" ]] || die "Expected 'wordpress' directory inside downloaded archive."

  local failed_assets=()
  local item url

  if [[ "$NO_PLUGINS" != true && ${#PLUGINS[@]} -gt 0 ]]; then
    for item in "${PLUGINS[@]}"; do
      if url="$(resolve_asset_url "plugin" "$item")"; then
        if ! download_and_unzip "$url" "$stage_wp/wp-content/plugins"; then
          failed_assets+=("plugin:$item")
        fi
      else
        colored_echo "$RED" "Invalid plugin entry: $item" >&2
        failed_assets+=("plugin:$item")
      fi
    done
  fi

  if [[ ${#THEMES[@]} -gt 0 ]]; then
    for item in "${THEMES[@]}"; do
      if url="$(resolve_asset_url "theme" "$item")"; then
        if ! download_and_unzip "$url" "$stage_wp/wp-content/themes"; then
          failed_assets+=("theme:$item")
        fi
      else
        colored_echo "$RED" "Invalid theme entry: $item" >&2
        failed_assets+=("theme:$item")
      fi
    done
  fi

  create_wp_config "$stage_wp"
  save_defaults "$stage_wp/$(basename "$DEFAULTS_FILE")"
  update_htaccess "$stage_wp"

  mkdir -p "$DEST_DIR"
  # Copy/move all files including dotfiles (.htaccess, .wp_install_defaults)
  (
    shopt -s dotglob nullglob
    mv "$stage_wp"/* "$DEST_DIR/"
  )

  colored_echo "$GREEN" "WordPress installed successfully in '$DEST_DIR'."
  colored_echo "$BLUE" "If you use Nginx, add a rule denying access to '$(basename "$DEFAULTS_FILE")':"
  colored_echo "$BLUE" "  location = /$(basename "$DEFAULTS_FILE") { deny all; }"

  if [[ ${#failed_assets[@]} -gt 0 ]]; then
    colored_echo "$YELLOW" "Warning: Some plugins/themes failed to install: ${failed_assets[*]}" >&2
  fi
}

main "$@"

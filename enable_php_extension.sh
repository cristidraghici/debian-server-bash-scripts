#!/usr/bin/env bash
set -euo pipefail

# Install and enable PHP extensions on Debian 12/13 and reload active
# Apache or Nginx/PHP-FPM services.

PHP_VERSION=""
NO_RESTART=false
SKIP_UPDATE=false
EXTENSIONS=()

usage() {
  cat <<'EOF'
Usage: enable_php_extension.sh [OPTIONS] [EXTENSION...]

Install and enable one or more PHP extensions for the detected or specified
PHP version, then reload active Apache or PHP-FPM/Nginx services.

Options:
  -v, --php-version <X.Y>  Target PHP version (e.g. 8.2, 8.4; auto-detected by default)
      --skip-update        Skip running 'apt-get update' before installation
      --no-restart         Skip reloading/restarting Apache or PHP-FPM/Nginx
  -h, --help               Show this help message and exit

Examples:
  sudo ./enable_php_extension.sh curl gd mbstring
  sudo ./enable_php_extension.sh -v 8.4 intl xml zip
  sudo ./enable_php_extension.sh --no-restart redis
EOF
}

die() {
  echo "Error: $*" >&2
  exit 1
}

prompt_read_array() {
  local prompt_text="$1"
  local input=""
  if [[ -t 0 ]]; then
    read -r -p "$prompt_text" input
  elif [[ -r /dev/tty ]]; then
    read -r -p "$prompt_text" input </dev/tty
  else
    die "Non-interactive shell detected. Pass extension names as arguments (see --help)."
  fi
  read -r -a EXTENSIONS <<<"$input"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -v | --php-version)
        [[ $# -ge 2 ]] || die "Option $1 requires a value."
        PHP_VERSION="$2"
        shift 2
        ;;
      --skip-update)
        SKIP_UPDATE=true
        shift
        ;;
      --no-restart)
        NO_RESTART=true
        shift
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      --)
        shift
        while [[ $# -gt 0 ]]; do
          EXTENSIONS+=("$1")
          shift
        done
        ;;
      -*)
        die "Unknown option: $1 (use --help for usage)"
        ;;
      *)
        EXTENSIONS+=("$1")
        shift
        ;;
    esac
  done
}

detect_php_version() {
  if [[ -n "$PHP_VERSION" ]]; then
    return 0
  fi

  if ! command -v php >/dev/null 2>&1; then
    die "PHP is not installed or not found in PATH. Install PHP or specify --php-version."
  fi

  PHP_VERSION="$(php -r 'echo PHP_MAJOR_VERSION . "." . PHP_MINOR_VERSION;' 2>/dev/null || true)"
  if [[ -z "$PHP_VERSION" ]]; then
    die "Failed to detect installed PHP version."
  fi
}

reload_services() {
  if [[ "$NO_RESTART" == true ]]; then
    echo "Skipping web server/PHP-FPM reload (--no-restart)."
    return 0
  fi

  if ! command -v systemctl >/dev/null 2>&1; then
    echo "systemctl not found; skipping service reload."
    return 0
  fi

  local reloaded=false
  local fpm_service="php${PHP_VERSION}-fpm"

  if systemctl is-active --quiet "$fpm_service" 2>/dev/null; then
    echo "Reloading ${fpm_service}..."
    systemctl reload-or-restart "$fpm_service"
    reloaded=true

    if systemctl is-active --quiet nginx 2>/dev/null; then
      echo "Reloading nginx..."
      systemctl reload nginx
    fi
  fi

  if systemctl is-active --quiet apache2 2>/dev/null; then
    echo "Reloading apache2..."
    systemctl reload-or-restart apache2
    reloaded=true
  fi

  if [[ "$reloaded" == false ]]; then
    echo "No active apache2 or ${fpm_service} service detected; skipping service reload."
  fi
}

main() {
  parse_args "$@"

  if [[ "$(id -u)" -ne 0 ]]; then
    die "This script must be run as root."
  fi

  if ! command -v apt-get >/dev/null 2>&1; then
    die "Required utility 'apt-get' is not available."
  fi

  detect_php_version
  if [[ ! "$PHP_VERSION" =~ ^[0-9]+\.[0-9]+$ ]]; then
    die "Invalid PHP version '$PHP_VERSION'. Expected format like '8.2' or '8.4'."
  fi

  if [[ ${#EXTENSIONS[@]} -eq 0 ]]; then
    prompt_read_array "Enter PHP extensions to install (space-separated, e.g. 'curl gd mbstring'): "
  fi

  if [[ ${#EXTENSIONS[@]} -eq 0 ]]; then
    die "No PHP extensions specified."
  fi

  local packages=()
  local ext
  for ext in "${EXTENSIONS[@]}"; do
    if [[ ! "$ext" =~ ^[a-zA-Z0-9_-]+$ ]]; then
      die "Invalid extension name '$ext'."
    fi
    packages+=("php${PHP_VERSION}-${ext}")
  done

  if [[ "$SKIP_UPDATE" != true ]]; then
    echo "Updating APT package index..."
    DEBIAN_FRONTEND=noninteractive apt-get update
  fi

  echo "Installing extensions for PHP ${PHP_VERSION}: ${packages[*]}..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"

  if command -v phpenmod >/dev/null 2>&1; then
    echo "Enabling extensions with phpenmod..."
    phpenmod -v "$PHP_VERSION" "${EXTENSIONS[@]}"
  fi

  reload_services
  echo "Extensions enabled for PHP ${PHP_VERSION}: ${EXTENSIONS[*]}."
}

main "$@"

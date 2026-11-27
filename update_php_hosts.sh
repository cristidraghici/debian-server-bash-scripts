#!/usr/bin/env bash
set -euo pipefail

# Interactively update Virtualmin hosts one by one to the latest (or specified)
# installed PHP version, reload active web/PHP-FPM services, and remove any PHP
# versions that remain unused afterwards.

TARGET_PHP_VERSION=""
ASSUME_YES=false
NO_PURGE=false
NO_RESTART=false
DRY_RUN=false

RED="0;31"
GREEN="0;32"
YELLOW="0;33"
BLUE="0;34"

usage() {
  cat <<'EOF'
Usage: update_php_hosts.sh [OPTIONS]

List all Virtualmin web hosts with their current PHP versions, confirm updating
each host one by one to the latest (or specified) installed PHP version, reload
active web/PHP-FPM services, and optionally remove any PHP versions that remain
unused afterwards.

Options:
  -v, --php-version <X.Y>  Target PHP version (e.g. 8.4; defaults to latest installed)
      --no-purge           Do not remove unused PHP versions after updating hosts
      --no-restart         Skip reloading Apache or PHP-FPM/Nginx services
      --dry-run            Preview host updates and unused PHP versions without making changes
  -y, --yes                Automatically confirm all host updates and unused PHP removals
  -h, --help               Show this help message and exit

Examples:
  sudo ./update_php_hosts.sh
  sudo ./update_php_hosts.sh -v 8.4
  sudo ./update_php_hosts.sh --dry-run
  sudo ./update_php_hosts.sh -y --no-purge
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
  local tty_input=""
  if [[ -t 0 ]]; then
    read -r -p "$prompt_text" tty_input
  elif [[ -r /dev/tty ]]; then
    read -r -p "$prompt_text" tty_input </dev/tty
  else
    die "Non-interactive shell detected. Re-run with --yes to confirm automatically (see --help)."
  fi
  printf -v "$var_name" '%s' "$tty_input"
}

confirm_action() {
  local prompt_text="$1"
  if [[ "$ASSUME_YES" == true ]]; then
    return 0
  fi
  local answer=""
  prompt_read "${prompt_text} [y/N]: " answer
  [[ "$answer" =~ ^[Yy]$ ]]
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -v | --php-version)
        [[ $# -ge 2 ]] || die "Option $1 requires a value."
        TARGET_PHP_VERSION="$2"
        shift 2
        ;;
      --no-purge)
        NO_PURGE=true
        shift
        ;;
      --no-restart)
        NO_RESTART=true
        shift
        ;;
      --dry-run)
        DRY_RUN=true
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
  for util in virtualmin dpkg-query apt-get; do
    if ! command -v "$util" >/dev/null 2>&1; then
      die "Required utility '$util' is not installed."
    fi
  done
}

# Print installed PHP X.Y versions sorted ascending (one per line).
list_installed_php_versions() {
  local raw=""
  raw="$(
    dpkg-query -W -f='${Package}\t${Status}\n' 'php[0-9].[0-9]*' 2>/dev/null |
      awk -F'\t' '$2 ~ /installed/ {
        if (match($1, /^php([0-9]+\.[0-9]+)(-|$)/)) {
          ver = substr($1, 4, RLENGTH - 3)
          sub(/-$/, "", ver)
          print ver
        }
      }' || true
  )"

  if [[ -z "$raw" ]]; then
    raw="$(
      virtualmin list-php-versions --name-only 2>/dev/null |
        awk '{
          if (match($1, /^([0-9]+\.[0-9]+)/)) {
            print substr($1, 1, RLENGTH)
          }
        }' || true
    )"
  fi

  if [[ -n "$raw" ]]; then
    printf '%s\n' "$raw" | sort -u | sort -t. -k1,1n -k2,2n
  fi
}

# Print installed APT package names for a specific PHP X.Y version (one per line).
list_php_packages_for_version() {
  local ver="$1"
  dpkg-query -W -f='${Package}\t${Status}\n' "php${ver}" "php${ver}-*" 2>/dev/null |
    awk -F'\t' '$2 ~ /installed/ { print $1 }' |
    sort -u || true
}

# Print space-separated unique PHP X.Y versions currently configured for a domain.
get_domain_php_versions() {
  local domain="$1"
  local versions=""

  versions="$(
    virtualmin list-php-directories --domain "$domain" --multiline 2>/dev/null |
      awk '/^[[:space:]]*(PHP )?[Vv]ersion:[[:space:]]*[0-9]+\.[0-9]+/ {
        sub(/^[[:space:]]*(PHP )?[Vv]ersion:[[:space:]]*/, "")
        if (match($0, /^[0-9]+\.[0-9]+/)) {
          print substr($0, 1, RLENGTH)
        }
      }' | sort -u | sort -t. -k1,1n -k2,2n || true
  )"

  if [[ -z "$versions" ]]; then
    versions="$(
      virtualmin list-domains --domain "$domain" --multiline 2>/dev/null |
        awk '/^[[:space:]]*PHP version:[[:space:]]*[0-9]+\.[0-9]+/ {
          sub(/^[[:space:]]*PHP version:[[:space:]]*/, "")
          if (match($0, /^[0-9]+\.[0-9]+/)) {
            print substr($0, 1, RLENGTH)
          }
        }' | sort -u | sort -t. -k1,1n -k2,2n || true
    )"
  fi

  if [[ -n "$versions" ]]; then
    printf '%s\n' "$versions" | tr '\n' ' ' | sed 's/[[:space:]]*$//'
  fi
}

version_in_list() {
  local needle="$1"
  shift
  local item
  for item in "$@"; do
    if [[ "$item" == "$needle" ]]; then
      return 0
    fi
  done
  return 1
}

reload_services() {
  if [[ "$NO_RESTART" == true ]]; then
    colored_echo "$YELLOW" "Skipping web server/PHP-FPM reload (--no-restart)."
    return 0
  fi

  if ! command -v systemctl >/dev/null 2>&1; then
    colored_echo "$YELLOW" "systemctl not found; skipping service reload."
    return 0
  fi

  local reloaded=false
  local fpm_service="php${TARGET_PHP_VERSION}-fpm"

  if systemctl is-active --quiet "$fpm_service" 2>/dev/null; then
    colored_echo "$BLUE" "Reloading ${fpm_service}..."
    systemctl reload-or-restart "$fpm_service"
    reloaded=true

    if systemctl is-active --quiet nginx 2>/dev/null; then
      colored_echo "$BLUE" "Reloading nginx..."
      systemctl reload nginx
    fi
  fi

  if systemctl is-active --quiet apache2 2>/dev/null; then
    colored_echo "$BLUE" "Reloading apache2..."
    systemctl reload-or-restart apache2
    reloaded=true
  fi

  if [[ "$reloaded" == false ]]; then
    colored_echo "$YELLOW" "No active apache2 or ${fpm_service} service detected; skipping service reload."
  fi
}

purge_unused_php_versions() {
  local installed_versions=("$@")
  local in_use_versions=()
  local domain=""
  local dom_vers=""
  local ver=""

  if [[ "$NO_PURGE" == true ]]; then
    colored_echo "$YELLOW" "Skipping unused PHP version cleanup (--no-purge)."
    return 0
  fi

  # Re-query all web domains to get authoritative post-update PHP usage.
  local domains=()
  while IFS= read -r domain; do
    [[ -n "$domain" ]] && domains+=("$domain")
  done < <(virtualmin list-domains --with-feature web --name-only 2>/dev/null || true)

  for domain in "${domains[@]}"; do
    if [[ "$DRY_RUN" == true ]]; then
      # In dry-run mode, simulate that all eligible PHP domains were updated.
      dom_vers="$(get_domain_php_versions "$domain")"
      if [[ -n "$dom_vers" ]]; then
        dom_vers="$TARGET_PHP_VERSION"
      fi
    else
      dom_vers="$(get_domain_php_versions "$domain")"
    fi

    for ver in $dom_vers; do
      if [[ ${#in_use_versions[@]} -eq 0 ]] || ! version_in_list "$ver" "${in_use_versions[@]}"; then
        in_use_versions+=("$ver")
      fi
    done
  done

  local unused_versions=()
  for ver in "${installed_versions[@]}"; do
    if [[ "$ver" == "$TARGET_PHP_VERSION" ]]; then
      continue
    fi
    if [[ ${#in_use_versions[@]} -gt 0 ]] && version_in_list "$ver" "${in_use_versions[@]}"; then
      continue
    fi
    unused_versions+=("$ver")
  done

  if [[ ${#unused_versions[@]} -eq 0 ]]; then
    colored_echo "$BLUE" "No unused PHP versions found."
    return 0
  fi

  echo ""
  colored_echo "$YELLOW" "Unused PHP versions detected: ${unused_versions[*]}"

  local purged_any=false
  local removed_versions=()
  for ver in "${unused_versions[@]}"; do
    local pkgs=()
    local pkg=""
    while IFS= read -r pkg; do
      [[ -n "$pkg" ]] && pkgs+=("$pkg")
    done < <(list_php_packages_for_version "$ver")

    if [[ ${#pkgs[@]} -eq 0 ]]; then
      continue
    fi

    if [[ "$DRY_RUN" == true ]]; then
      colored_echo "$BLUE" "[dry-run] Would remove unused PHP ${ver} (${#pkgs[@]} packages: ${pkgs[*]})."
      removed_versions+=("$ver")
      continue
    fi

    if confirm_action "PHP ${ver} is no longer used by any host (${#pkgs[@]} packages). Remove it?"; then
      if command -v systemctl >/dev/null 2>&1; then
        systemctl disable --now "php${ver}-fpm" 2>/dev/null || true
      fi

      if command -v update-alternatives >/dev/null 2>&1 && [[ -x "/usr/bin/php${TARGET_PHP_VERSION}" ]]; then
        update-alternatives --set php "/usr/bin/php${TARGET_PHP_VERSION}" 2>/dev/null || true
      fi

      colored_echo "$BLUE" "Removing PHP ${ver} packages: ${pkgs[*]}..."
      DEBIAN_FRONTEND=noninteractive apt-get purge -y "${pkgs[@]}"
      purged_any=true
      removed_versions+=("$ver")
    else
      colored_echo "$YELLOW" "Keeping unused PHP ${ver}."
    fi
  done

  if [[ "$purged_any" == true ]]; then
    colored_echo "$BLUE" "Running apt-get autoremove..."
    DEBIAN_FRONTEND=noninteractive apt-get autoremove -y
  fi

  if [[ ${#removed_versions[@]} -gt 0 ]]; then
    colored_echo "$GREEN" "Removed unused PHP version(s): ${removed_versions[*]}"
  fi
}

main() {
  parse_args "$@"

  if [[ "$(id -u)" -ne 0 ]]; then
    die "This script must be run as root."
  fi

  check_dependencies

  local installed_versions=()
  local ver=""
  while IFS= read -r ver; do
    [[ -n "$ver" ]] && installed_versions+=("$ver")
  done < <(list_installed_php_versions)

  if [[ ${#installed_versions[@]} -eq 0 ]]; then
    die "No installed PHP versions were detected."
  fi

  if [[ -n "$TARGET_PHP_VERSION" ]]; then
    if [[ ! "$TARGET_PHP_VERSION" =~ ^[0-9]+\.[0-9]+$ ]]; then
      die "Invalid PHP version '${TARGET_PHP_VERSION}'. Expected format like '8.2' or '8.4'."
    fi
    if ! version_in_list "$TARGET_PHP_VERSION" "${installed_versions[@]}"; then
      die "Target PHP version '${TARGET_PHP_VERSION}' is not installed. Installed versions: ${installed_versions[*]}"
    fi
  else
    TARGET_PHP_VERSION="${installed_versions[$((${#installed_versions[@]} - 1))]}"
  fi

  colored_echo "$BLUE" "Installed PHP versions : ${installed_versions[*]}"
  colored_echo "$BLUE" "Target PHP version     : ${TARGET_PHP_VERSION}"

  local domains=()
  local domain=""
  while IFS= read -r domain; do
    [[ -n "$domain" ]] && domains+=("$domain")
  done < <(virtualmin list-domains --with-feature web --name-only 2>/dev/null || true)

  if [[ ${#domains[@]} -eq 0 ]]; then
    colored_echo "$YELLOW" "No Virtualmin web hosts found."
    purge_unused_php_versions "${installed_versions[@]}"
    return 0
  fi

  local domain_versions=()
  local i=0
  echo ""
  colored_echo "$BLUE" "Available Virtualmin hosts:"
  for domain in "${domains[@]}"; do
    local current_ver=""
    current_ver="$(get_domain_php_versions "$domain")"
    domain_versions+=("$current_ver")

    if [[ -z "$current_ver" ]]; then
      printf '  - %-35s (no PHP)      -> skipped\n' "$domain"
    elif [[ "$current_ver" == "$TARGET_PHP_VERSION" ]]; then
      printf '  - %-35s (PHP %-7s) -> already on %s\n' "$domain" "$current_ver" "$TARGET_PHP_VERSION"
    else
      printf '  - %-35s (PHP %-7s) -> update available\n' "$domain" "$current_ver"
    fi
  done

  echo ""
  local updated_count=0
  local skipped_count=0
  local failed_count=0

  for ((i = 0; i < ${#domains[@]}; i++)); do
    domain="${domains[$i]}"
    local current_ver="${domain_versions[$i]}"

    if [[ -z "$current_ver" || "$current_ver" == "$TARGET_PHP_VERSION" ]]; then
      continue
    fi

    if [[ "$DRY_RUN" == true ]]; then
      colored_echo "$BLUE" "[dry-run] Would update '${domain}' from PHP ${current_ver} to PHP ${TARGET_PHP_VERSION}."
      updated_count=$((updated_count + 1))
      continue
    fi

    if confirm_action "Update '${domain}' (PHP ${current_ver}) to PHP ${TARGET_PHP_VERSION}?"; then
      colored_echo "$BLUE" "Updating '${domain}' to PHP ${TARGET_PHP_VERSION}..."
      if virtualmin modify-web --domain "$domain" --php-version "$TARGET_PHP_VERSION"; then
        colored_echo "$GREEN" "Updated '${domain}' to PHP ${TARGET_PHP_VERSION}."
        updated_count=$((updated_count + 1))
      else
        colored_echo "$RED" "Failed to update '${domain}' to PHP ${TARGET_PHP_VERSION}." >&2
        failed_count=$((failed_count + 1))
      fi
    else
      colored_echo "$YELLOW" "Skipped '${domain}'."
      skipped_count=$((skipped_count + 1))
    fi
  done

  if [[ "$updated_count" -gt 0 && "$DRY_RUN" != true ]]; then
    echo ""
    reload_services
  fi

  purge_unused_php_versions "${installed_versions[@]}"

  echo ""
  colored_echo "$GREEN" "Summary: ${updated_count} updated, ${skipped_count} skipped, ${failed_count} failed."

  if [[ "$failed_count" -gt 0 ]]; then
    exit 1
  fi
}

main "$@"

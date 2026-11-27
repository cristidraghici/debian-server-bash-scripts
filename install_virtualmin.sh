#!/usr/bin/env bash
set -euo pipefail

# Minimal Virtualmin installer and hardening script for Debian 12/13:
# - Installs Virtualmin minimal (--bundle LAMP|LEMP --type mini) with FQDN validation
# - Installs Jailkit + webmin-jailkit with restrictive defaults and enables it on Default Settings
# - Purges Usermin (no mail stack) and moves Webmin to a required custom non-10000 port
# - Applies Virtualmin preferences (full-domain usernames, editable limits, 2 GB default quota)
# - Configures firewalld, adds a Fail2ban webmin-auth jail drop-in if Fail2ban is present,
#   and installs a login MOTD documenting the jailed-user admin workflow.

ROOT_DIR="${VIRTUALMIN_ROOT_DIR:-}"
BUNDLE="LAMP"
FQDN=""
WEBMIN_PORT=""
QUOTA_GB="2"
SKIP_INSTALL=false
SKIP_UPDATE=false
ASSUME_YES=false
VIRTUALMIN_INSTALL_URL="https://download.virtualmin.com/virtualmin-install"
TMP_DIR=""

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
Usage: install_virtualmin.sh [OPTIONS]

Install Virtualmin minimal on Debian 12/13 with restrictive Jailkit isolation,
custom Webmin port, Usermin removal, firewalld rules, Fail2ban integration,
and a helpful login MOTD.

Options:
      --bundle <LAMP|LEMP>  Web stack bundle to install (default: LAMP)
      --hostname <fqdn>     Server FQDN (auto-detected via 'hostname -f' if valid)
      --webmin-port <port>  Custom TCP port for Webmin (1024-65535, must not be 10000)
      --quota-gb <N>        Default plan disk quota in GB (default: 2)
      --skip-install        Skip running the upstream Virtualmin installer
      --skip-update         Skip running 'apt-get update' before installing Jailkit
  -y, --yes                 Skip confirmation prompt (requires --webmin-port)
  -h, --help                Show this help message and exit

Examples:
  sudo ./install_virtualmin.sh
  sudo ./install_virtualmin.sh --hostname panel.example.com --webmin-port 20443 -y
  sudo ./install_virtualmin.sh --bundle LEMP --webmin-port 20443 --quota-gb 5 -y
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
    die "Non-interactive shell detected. Pass required values via CLI flags (see --help)."
  fi
  printf -v "$var_name" '%s' "$tty_input"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --bundle)
        [[ $# -ge 2 ]] || die "Option $1 requires a value."
        BUNDLE="$2"
        shift 2
        ;;
      --hostname)
        [[ $# -ge 2 ]] || die "Option $1 requires a value."
        FQDN="$2"
        shift 2
        ;;
      --webmin-port)
        [[ $# -ge 2 ]] || die "Option $1 requires a value."
        WEBMIN_PORT="$2"
        shift 2
        ;;
      --quota-gb)
        [[ $# -ge 2 ]] || die "Option $1 requires a value."
        QUOTA_GB="$2"
        shift 2
        ;;
      --skip-install)
        SKIP_INSTALL=true
        shift
        ;;
      --skip-update)
        SKIP_UPDATE=true
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

is_valid_fqdn() {
  local host="$1"
  if [[ -z "$host" || ${#host} -gt 253 || "$host" != *.* ]]; then
    return 1
  fi
  if [[ "$host" == "localhost" || "$host" == "localhost.localdomain" || "$host" == *.localdomain ]]; then
    return 1
  fi
  if [[ ! "$host" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+$ ]]; then
    return 1
  fi
  return 0
}

validate_webmin_port() {
  local port="$1"
  local ssh_port="$2"
  if [[ ! "$port" =~ ^[0-9]+$ ]] || ((port < 1024 || port > 65535)); then
    die "Invalid Webmin port '${port}'. Expected an unprivileged port between 1024 and 65535."
  fi
  if [[ "$port" == "10000" ]]; then
    die "Webmin port must not be the default 10000. Choose a custom port (e.g. 20443)."
  fi
  if [[ "$port" == "$ssh_port" ]]; then
    die "Webmin port '${port}' conflicts with the detected SSH port '${ssh_port}'."
  fi
}

check_os() {
  local os_release="${ROOT_DIR}/etc/os-release"
  if [[ -r "$os_release" ]]; then
    local id="" version_id=""
    id="$(awk -F= '$1 == "ID" { gsub(/"/, "", $2); print $2 }' "$os_release" || true)"
    version_id="$(awk -F= '$1 == "VERSION_ID" { gsub(/"/, "", $2); print $2 }' "$os_release" || true)"
    if [[ "$id" != "debian" || ("$version_id" != "12" && "$version_id" != "13") ]]; then
      colored_echo "$YELLOW" "Warning: Detected OS '${id:-unknown} ${version_id:-unknown}'. This script targets Debian 12/13."
    fi
  fi
}

check_dependencies() {
  local util
  for util in apt-get curl hostname; do
    if ! command -v "$util" >/dev/null 2>&1; then
      die "Required utility '$util' is not installed."
    fi
  done
}

detect_ssh_port() {
  local detected=""
  if command -v sshd >/dev/null 2>&1; then
    detected="$(sshd -T 2>/dev/null | awk '$1 == "port" { print $2; exit }' || true)"
  fi

  if [[ ! "$detected" =~ ^[0-9]+$ ]]; then
    local cfg_file
    for cfg_file in "${ROOT_DIR}/etc/ssh/sshd_config.d/"*.conf "${ROOT_DIR}/etc/ssh/sshd_config"; do
      if [[ -r "$cfg_file" ]]; then
        detected="$(awk '/^[[:space:]]*Port[[:space:]]+[0-9]+/ { print $2; exit }' "$cfg_file" || true)"
        if [[ "$detected" =~ ^[0-9]+$ ]]; then
          break
        fi
      fi
    done
  fi

  if [[ "$detected" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$detected"
  else
    printf '22\n'
  fi
}

resolve_fqdn() {
  if [[ -n "$FQDN" ]]; then
    if ! is_valid_fqdn "$FQDN"; then
      die "Invalid FQDN '${FQDN}'. Expected a fully qualified domain name like 'server.example.com'."
    fi
    return 0
  fi

  local detected=""
  detected="$(hostname -f 2>/dev/null || true)"
  if is_valid_fqdn "$detected"; then
    FQDN="$detected"
    colored_echo "$BLUE" "Detected server FQDN: ${FQDN}"
    return 0
  fi

  if [[ "$ASSUME_YES" == true ]]; then
    die "Could not auto-detect a valid FQDN (got '${detected:-empty}'). Pass --hostname <fqdn>."
  fi

  prompt_read "Enter the server FQDN (e.g. server.example.com): " FQDN
  if ! is_valid_fqdn "$FQDN"; then
    die "Invalid FQDN '${FQDN}'. Expected a fully qualified domain name like 'server.example.com'."
  fi
}

set_kv_setting() {
  local file="$1"
  local key="$2"
  local value="$3"
  local tmp_file="${TMP_DIR}/kv.tmp"

  mkdir -p "$(dirname "$file")"
  if [[ -f "$file" ]]; then
    if grep -q "^${key}=" "$file"; then
      awk -v k="$key" -v v="$value" '
        index($0, k "=") == 1 { print k "=" v; next }
        { print }
      ' "$file" >"$tmp_file"
      cat "$tmp_file" >"$file"
      rm -f "$tmp_file"
    else
      printf '%s=%s\n' "$key" "$value" >>"$file"
    fi
  else
    printf '%s=%s\n' "$key" "$value" >"$file"
  fi
}

install_virtualmin_minimal() {
  if [[ "$SKIP_INSTALL" == true ]]; then
    colored_echo "$YELLOW" "Skipping upstream Virtualmin installation (--skip-install)."
    return 0
  fi

  if [[ -f "${ROOT_DIR}/etc/webmin/virtual-server/config" ]] && command -v virtualmin >/dev/null 2>&1; then
    colored_echo "$YELLOW" "Virtualmin appears to be already installed; skipping upstream installer."
    return 0
  fi

  local installer_script="${TMP_DIR}/virtualmin-install.sh"
  colored_echo "$BLUE" "Downloading Virtualmin installer from ${VIRTUALMIN_INSTALL_URL}..."
  curl -fsSL "$VIRTUALMIN_INSTALL_URL" -o "$installer_script"

  colored_echo "$BLUE" "Running Virtualmin minimal install (--bundle ${BUNDLE} --type mini --hostname ${FQDN})..."
  sh "$installer_script" --bundle "$BUNDLE" --type mini --hostname "$FQDN" --yes
}

print_jailkit_manual_fallback() {
  colored_echo "$YELLOW" "Manual fallback to enable Jailkit for all new virtual hosts:"
  cat <<'EOF'
  1. Open Virtualmin > System Settings > Server Templates
  2. Select Default Settings
  3. Open the Administrative user section
  4. Set "Chroot jail new domain Unix users?" to Yes
  5. Save the template
EOF
}

install_and_configure_jailkit() {
  if [[ "$SKIP_UPDATE" != true ]]; then
    colored_echo "$BLUE" "Updating APT package index..."
    DEBIAN_FRONTEND=noninteractive apt-get update
  fi

  colored_echo "$BLUE" "Installing jailkit and webmin-jailkit (keeping restrictive default chroot sections)..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y jailkit webmin-jailkit

  if ! command -v virtualmin >/dev/null 2>&1; then
    colored_echo "$YELLOW" "Warning: 'virtualmin' CLI not found; could not automate Default Settings template update."
    print_jailkit_manual_fallback
    return 0
  fi

  colored_echo "$BLUE" "Enabling Jailkit by default on Virtualmin's Default Settings template..."
  if virtualmin modify-template --id 0 --setting ujail --value 1; then
    local current_val=""
    current_val="$(virtualmin get-template --id 0 --setting ujail 2>/dev/null || true)"
    if [[ "$current_val" == *"1"* ]]; then
      colored_echo "$GREEN" "Verified Jailkit is enabled (ujail=1) on Default Settings template."
    else
      colored_echo "$YELLOW" "Warning: Could not verify ujail=1 from 'virtualmin get-template --id 0 --setting ujail'."
      print_jailkit_manual_fallback
    fi
  else
    colored_echo "$YELLOW" "Warning: Failed to enable Jailkit via 'virtualmin modify-template'."
    print_jailkit_manual_fallback
  fi
}

purge_usermin_if_present() {
  local usermin_installed=false
  if command -v dpkg-query >/dev/null 2>&1; then
    local status=""
    status="$(dpkg-query -W -f='${Status}' usermin 2>/dev/null || true)"
    if [[ "$status" == *"installed"* ]]; then
      usermin_installed=true
    fi
  fi

  if [[ "$usermin_installed" == false && ! -d "${ROOT_DIR}/etc/usermin" ]]; then
    colored_echo "$BLUE" "Usermin is not installed; nothing to remove."
    return 0
  fi

  colored_echo "$BLUE" "Stopping and purging Usermin (not needed without a mail stack)..."
  if command -v systemctl >/dev/null 2>&1; then
    systemctl stop usermin 2>/dev/null || true
    systemctl disable usermin 2>/dev/null || true
  fi
  if command -v usermin >/dev/null 2>&1; then
    usermin stop 2>/dev/null || true
  fi
  if [[ "$usermin_installed" == true ]]; then
    DEBIAN_FRONTEND=noninteractive apt-get purge -y usermin
  fi
  rm -rf "${ROOT_DIR}/etc/usermin"
}

configure_webmin_and_virtualmin_defaults() {
  local miniserv_conf="${ROOT_DIR}/etc/webmin/miniserv.conf"
  if [[ -f "$miniserv_conf" ]]; then
    colored_echo "$BLUE" "Changing Webmin listening port to ${WEBMIN_PORT} in ${miniserv_conf}..."
    set_kv_setting "$miniserv_conf" "port" "$WEBMIN_PORT"
    set_kv_setting "$miniserv_conf" "listen" "$WEBMIN_PORT"
  else
    colored_echo "$YELLOW" "Warning: ${miniserv_conf} not found; skipping Webmin port update."
  fi

  local vs_conf="${ROOT_DIR}/etc/webmin/virtual-server/config"
  if [[ -f "$vs_conf" ]]; then
    colored_echo "$BLUE" "Applying Virtualmin defaults (full-domain usernames, allow editing limits on creation)..."
    # longname=1 => Full domain name style in usernames
    set_kv_setting "$vs_conf" "longname" "1"
    # template_auto=0 => Allow editing of limits when creating a server = Yes
    set_kv_setting "$vs_conf" "template_auto" "0"
  else
    colored_echo "$YELLOW" "Warning: ${vs_conf} not found; skipping Virtualmin module config defaults."
  fi

  if command -v virtualmin >/dev/null 2>&1; then
    local quota_blocks=$((QUOTA_GB * 1048576))
    colored_echo "$BLUE" "Setting Default Plan quota to ${QUOTA_GB} GB (${quota_blocks} x 1KB blocks)..."
    if ! virtualmin modify-plan --id 0 --quota "$quota_blocks" --admin-quota "$quota_blocks"; then
      colored_echo "$YELLOW" "Warning: Failed to update Default Plan quota via CLI; adjust it under Virtualmin > System Settings > Account Plans."
    fi
  fi

  if command -v systemctl >/dev/null 2>&1 && [[ -f "$miniserv_conf" ]]; then
    colored_echo "$BLUE" "Restarting Webmin to apply port and configuration changes..."
    systemctl restart webmin
  fi
}

configure_apache_lowram() {
  if [[ "$BUNDLE" != "LAMP" ]]; then
    return 0
  fi

  local conf_avail="${ROOT_DIR}/etc/apache2/conf-available"
  local conf_enabled="${ROOT_DIR}/etc/apache2/conf-enabled"
  local conf_file="${conf_avail}/99-virtualmin-lowram.conf"
  local conf_link="${conf_enabled}/99-virtualmin-lowram.conf"

  if [[ ! -d "$conf_avail" ]]; then
    colored_echo "$YELLOW" "Warning: ${conf_avail} not found; skipping Apache low-RAM tuning."
    return 0
  fi

  mkdir -p "$conf_enabled"
  colored_echo "$BLUE" "Applying low-RAM Apache timeout and mpm_event worker tuning (${conf_file})..."
  cat >"$conf_file" <<'EOF'
# Managed by install_virtualmin.sh
# Tight timeouts and conservative mpm_event worker caps for low-RAM servers

Timeout 30
KeepAlive On
MaxKeepAliveRequests 100
KeepAliveTimeout 3

<IfModule mpm_event_module>
    StartServers            1
    MinSpareThreads         10
    MaxSpareThreads         25
    ThreadsPerChild         25
    MaxRequestWorkers       50
    MaxConnectionsPerChild  1000
</IfModule>
EOF

  ln -sfn "../conf-available/99-virtualmin-lowram.conf" "$conf_link"

  if command -v apache2ctl >/dev/null 2>&1 && ! apache2ctl -t >/dev/null 2>&1; then
    colored_echo "$YELLOW" "Warning: apache2ctl -t failed after adding ${conf_file}; rolling back Apache tuning."
    rm -f "$conf_link" "$conf_file"
    return 0
  fi

  if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet apache2 2>/dev/null; then
    systemctl reload-or-restart apache2
  fi
}

cleanup_conflicting_nftables_tables() {
  if ! command -v nft >/dev/null 2>&1; then
    return 0
  fi

  local family="" name=""
  while read -r _ family name; do
    if [[ -z "$family" || -z "$name" ]]; then
      continue
    fi
    if [[ ("$family" == "inet" && "$name" == "filter") || "$name" == webmin* ]]; then
      colored_echo "$BLUE" "Removing conflicting nftables table '${family} ${name}' so firewalld is the sole firewall..."
      nft delete table "$family" "$name" 2>/dev/null || true
    fi
  done < <(nft list tables 2>/dev/null || true)
}

configure_firewalld() {
  local ssh_port="$1"
  if ! command -v firewall-cmd >/dev/null 2>&1; then
    colored_echo "$BLUE" "Installing firewalld..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y firewalld
  fi

  if command -v systemctl >/dev/null 2>&1; then
    if systemctl is-active --quiet nftables 2>/dev/null || systemctl is-enabled --quiet nftables 2>/dev/null; then
      colored_echo "$BLUE" "Disabling conflicting nftables.service so firewalld is the sole firewall..."
      systemctl disable --now nftables 2>/dev/null || true
      systemctl enable --now firewalld
      systemctl restart firewalld
    else
      systemctl enable --now firewalld
    fi
  fi

  colored_echo "$BLUE" "Configuring firewalld (SSH ${ssh_port}/tcp, HTTP/HTTPS, Webmin ${WEBMIN_PORT}/tcp; closing 10000/tcp)..."
  if [[ "$ssh_port" == "22" ]]; then
    firewall-cmd --permanent --add-service=ssh >/dev/null 2>&1 ||
      firewall-cmd --permanent --add-port=22/tcp >/dev/null
  else
    firewall-cmd --permanent --add-port="${ssh_port}/tcp" >/dev/null
  fi

  firewall-cmd --permanent --add-service=http >/dev/null
  firewall-cmd --permanent --add-service=https >/dev/null
  firewall-cmd --permanent --add-port="${WEBMIN_PORT}/tcp" >/dev/null

  firewall-cmd --permanent --remove-port=10000/tcp >/dev/null 2>&1 || true
  firewall-cmd --permanent --remove-port=10000-10100/tcp >/dev/null 2>&1 || true
  firewall-cmd --permanent --remove-service=webmin >/dev/null 2>&1 || true

  firewall-cmd --reload >/dev/null
  cleanup_conflicting_nftables_tables
}

configure_fail2ban_handoff() {
  local jail_dir="${ROOT_DIR}/etc/fail2ban/jail.d"
  if ! command -v fail2ban-client >/dev/null 2>&1 && [[ ! -d "$jail_dir" ]]; then
    colored_echo "$YELLOW" "Fail2ban is not installed yet; run harden_server.sh to enable SSH, recidive, and webmin-auth jails."
    return 0
  fi

  mkdir -p "$jail_dir"
  local nft_override="${jail_dir}/virtualmin-nftables.conf"
  if [[ -f "$nft_override" ]]; then
    colored_echo "$BLUE" "Removing conflicting Virtualmin nftables Fail2ban override (${nft_override})..."
    rm -f "$nft_override"
  fi

  colored_echo "$BLUE" "Adding Fail2ban webmin-auth jail for port ${WEBMIN_PORT}..."
  cat >"${jail_dir}/30-virtualmin.local" <<EOF
# Managed by install_virtualmin.sh
[webmin-auth]
enabled = true
port = ${WEBMIN_PORT}
backend = systemd
banaction = firewallcmd-rich-rules
bantime = 24h
findtime = 10m
maxretry = 3
EOF

  if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet fail2ban 2>/dev/null; then
    systemctl reload-or-restart fail2ban
  fi
}

install_motd() {
  local motd_dir="${ROOT_DIR}/etc/update-motd.d"
  local motd_file="${motd_dir}/99-virtualmin-hosting"
  mkdir -p "$motd_dir"

  colored_echo "$BLUE" "Installing login welcome message (${motd_file})..."
  cat >"$motd_file" <<EOF
#!/bin/sh
cat <<'BANNER'

========================================================================
 Virtualmin Minimal Hosting Server (${FQDN})
------------------------------------------------------------------------
 Panel URL : https://${FQDN}:${WEBMIN_PORT}
 Isolation : New domain users are chroot-jailed via Jailkit (restrictive).

 Running host tools as a jailed domain user (from your sudoer account):
   Interactive shell : sudo -u <domain-user> -H /bin/bash
   Single command    : sudo -u <domain-user> /usr/bin/php -v
========================================================================

BANNER
EOF
  chmod 755 "$motd_file"
}

main() {
  parse_args "$@"

  if [[ "$(id -u)" -ne 0 ]]; then
    die "This script must be run as root."
  fi

  # Normalize and validate --bundle
  BUNDLE="$(printf '%s' "$BUNDLE" | tr '[:lower:]' '[:upper:]')"
  if [[ "$BUNDLE" != "LAMP" && "$BUNDLE" != "LEMP" ]]; then
    die "Invalid --bundle '${BUNDLE}'. Expected 'LAMP' or 'LEMP'."
  fi

  if [[ ! "$QUOTA_GB" =~ ^[1-9][0-9]*$ ]]; then
    die "Invalid --quota-gb '${QUOTA_GB}'. Expected a positive integer."
  fi

  check_os
  check_dependencies

  local ssh_port
  ssh_port="$(detect_ssh_port)"
  resolve_fqdn

  if [[ -z "$WEBMIN_PORT" ]]; then
    if [[ "$ASSUME_YES" == true ]]; then
      die "A custom non-10000 Webmin port is required in non-interactive mode. Pass --webmin-port <port>."
    fi
    prompt_read "Enter custom TCP port for Webmin (1024-65535, not 10000, e.g. 20443): " WEBMIN_PORT
  fi
  validate_webmin_port "$WEBMIN_PORT" "$ssh_port"

  if [[ "$ASSUME_YES" != true ]]; then
    colored_echo "$YELLOW" "Virtualmin installation plan:"
    echo "  - Bundle / Type : ${BUNDLE} / mini"
    echo "  - Hostname      : ${FQDN}"
    echo "  - Webmin port   : ${WEBMIN_PORT}/tcp (default 10000 closed)"
    echo "  - Jailkit       : restrictive default chroot, enabled on Default Settings"
    echo "  - Usermin       : purged if present"
    echo "  - Defaults      : full-domain usernames, editable limits, ${QUOTA_GB} GB default quota"
    echo "  - Firewall      : firewalld (SSH ${ssh_port}/tcp, HTTP, HTTPS, Webmin ${WEBMIN_PORT}/tcp)"
    local confirm=""
    prompt_read "Proceed with Virtualmin installation and hardening? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
      die "Installation aborted."
    fi
  fi

  TMP_DIR="$(mktemp -d)"

  local restore_unattended_upgrades=false
  if [[ -f "${ROOT_DIR}/etc/apt/apt.conf.d/51unattended-upgrades-local" ]] ||
    (command -v systemctl >/dev/null 2>&1 && systemctl is-enabled --quiet unattended-upgrades 2>/dev/null); then
    restore_unattended_upgrades=true
  fi

  install_virtualmin_minimal
  if [[ "$restore_unattended_upgrades" == true ]] && command -v systemctl >/dev/null 2>&1; then
    colored_echo "$BLUE" "Re-enabling unattended-upgrades (disabled by Virtualmin installer)..."
    systemctl enable --now unattended-upgrades 2>/dev/null || true
  fi
  install_and_configure_jailkit
  purge_usermin_if_present
  configure_webmin_and_virtualmin_defaults
  configure_apache_lowram
  configure_firewalld "$ssh_port"
  configure_fail2ban_handoff
  install_motd

  colored_echo "$GREEN" "Virtualmin minimal installation and hardening completed."
  colored_echo "$BLUE" "Access Virtualmin at: https://${FQDN}:${WEBMIN_PORT}"
  colored_echo "$BLUE" "To run host commands as a jailed domain user:"
  colored_echo "$BLUE" "  sudo -u <domain-user> -H /bin/bash"
  colored_echo "$BLUE" "  sudo -u <domain-user> /usr/bin/php -v"
}

main "$@"

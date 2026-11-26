#!/usr/bin/env bash
set -euo pipefail

# Reusable Debian 12/13 server hardening script:
# - Hardens OpenSSH via /etc/ssh/sshd_config.d/99-hardening.conf (validated with sshd -t)
# - Configures firewalld for the active SSH port (preserving existing Webmin/web rules)
# - Installs and configures strict Fail2ban (backend=systemd, maxretry=3, bantime=24h, recidive)
# - Installs and configures unattended-upgrades for daily security patches

ROOT_DIR="${HARDEN_ROOT_DIR:-}"
SSH_PORT=""
CURRENT_SSH_PORT=""
ALLOW_PASSWORD_AUTH=false
AUTO_REBOOT=false
REBOOT_TIME="03:00"
NOTIFY_EMAIL=""
SKIP_UPDATE=false
ASSUME_YES=false
IGNORE_IPS=()
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
Usage: harden_server.sh [OPTIONS]

Harden a Debian 12/13 server with safe OpenSSH hardening, firewalld,
strict Fail2ban (systemd backend + recidive), and unattended-upgrades.

Options:
  -p, --ssh-port <port>      Custom SSH port (1-65535; interactive prompt keeps current on Enter)
      --allow-password-auth  Keep SSH PasswordAuthentication enabled
      --ignore-ip <ip/cidr>  Whitelist IP or CIDR in Fail2ban (may be passed multiple times)
      --auto-reboot          Enable automatic reboot in unattended-upgrades when required
      --reboot-time <HH:MM>  Automatic reboot time for unattended-upgrades (default: 03:00)
      --notify-email <addr>  Send unattended-upgrades notifications to this email address
      --skip-update          Skip running 'apt-get update' before package installation
  -y, --yes                  Skip interactive prompts and use defaults for omitted options
  -h, --help                 Show this help message and exit

Examples:
  sudo ./harden_server.sh
  sudo ./harden_server.sh --ssh-port 2222 --ignore-ip 203.0.113.10 -y
  sudo ./harden_server.sh --ssh-port 2222 --auto-reboot --reboot-time 04:00 -y
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
    die "Non-interactive shell detected. Pass required values via CLI flags or --yes (see --help)."
  fi
  printf -v "$var_name" '%s' "$tty_input"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -p | --ssh-port)
        [[ $# -ge 2 ]] || die "Option $1 requires a value."
        SSH_PORT="$2"
        shift 2
        ;;
      --allow-password-auth)
        ALLOW_PASSWORD_AUTH=true
        shift
        ;;
      --ignore-ip)
        [[ $# -ge 2 ]] || die "Option $1 requires a value."
        IGNORE_IPS+=("$2")
        shift 2
        ;;
      --auto-reboot)
        AUTO_REBOOT=true
        shift
        ;;
      --reboot-time)
        [[ $# -ge 2 ]] || die "Option $1 requires a value."
        REBOOT_TIME="$2"
        shift 2
        ;;
      --notify-email)
        [[ $# -ge 2 ]] || die "Option $1 requires a value."
        NOTIFY_EMAIL="$2"
        shift 2
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

validate_port() {
  local port="$1"
  local label="${2:-Port}"
  if [[ ! "$port" =~ ^[0-9]+$ ]] || ((port < 1 || port > 65535)); then
    die "Invalid ${label} '${port}'. Expected an integer between 1 and 65535."
  fi
  if [[ "$port" == "80" || "$port" == "443" ]]; then
    die "Invalid ${label} '${port}'. Refusing to conflict with HTTP/HTTPS ports (80/443)."
  fi
}

validate_inputs() {
  if [[ -n "$SSH_PORT" ]]; then
    validate_port "$SSH_PORT" "SSH port"
  fi

  if [[ ! "$REBOOT_TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
    die "Invalid --reboot-time '${REBOOT_TIME}'. Expected 24-hour HH:MM format (e.g. 03:00)."
  fi

  if [[ -n "$NOTIFY_EMAIL" ]]; then
    if [[ ! "$NOTIFY_EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
      die "Invalid email address '${NOTIFY_EMAIL}'."
    fi
  fi

  if [[ ${#IGNORE_IPS[@]} -gt 0 ]]; then
    local ip
    for ip in "${IGNORE_IPS[@]}"; do
      if [[ ! "$ip" =~ ^[0-9a-fA-F.:/]+$ ]]; then
        die "Invalid --ignore-ip value '${ip}'."
      fi
    done
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
  for util in apt-get sshd; do
    if ! command -v "$util" >/dev/null 2>&1; then
      die "Required utility '$util' is not installed."
    fi
  done
}

detect_current_ssh_port() {
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
    CURRENT_SSH_PORT="$detected"
  else
    CURRENT_SSH_PORT="22"
  fi
}

detect_webmin_port() {
  local miniserv="${ROOT_DIR}/etc/webmin/miniserv.conf"
  if [[ -r "$miniserv" ]]; then
    awk -F= '$1 == "port" { gsub(/[[:space:]]/, "", $2); print $2; exit }' "$miniserv" || true
  fi
}

has_non_root_ssh_keys() {
  local passwd_file="${ROOT_DIR}/etc/passwd"
  local uid home key_file key_line
  local passwd_source=""

  if [[ -n "$ROOT_DIR" && -r "$passwd_file" ]]; then
    passwd_source="$(cat "$passwd_file")"
  elif command -v getent >/dev/null 2>&1; then
    passwd_source="$(getent passwd)"
  elif [[ -r "$passwd_file" ]]; then
    passwd_source="$(cat "$passwd_file")"
  fi

  while IFS=: read -r _ _ uid _ _ home _; do
    if [[ ! "$uid" =~ ^[0-9]+$ ]] || ((uid < 1000 || uid == 65534)); then
      continue
    fi
    key_file="${ROOT_DIR}${home}/.ssh/authorized_keys"
    if [[ -s "$key_file" ]]; then
      while IFS= read -r key_line || [[ -n "$key_line" ]]; do
        key_line="${key_line%$'\r'}"
        if [[ -n "${key_line//[[:space:]]/}" && ! "$key_line" =~ ^[[:space:]]*# ]]; then
          return 0
        fi
      done <"$key_file"
    fi
  done <<<"$passwd_source"

  return 1
}

install_packages() {
  if [[ "$SKIP_UPDATE" != true ]]; then
    colored_echo "$BLUE" "Updating APT package index..."
    DEBIAN_FRONTEND=noninteractive apt-get update
  fi

  colored_echo "$BLUE" "Installing firewalld, fail2ban, python3-systemd, and unattended-upgrades..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    firewalld \
    fail2ban \
    python3-systemd \
    unattended-upgrades
}

configure_firewalld_pre_ssh() {
  if ! command -v firewall-cmd >/dev/null 2>&1; then
    die "firewall-cmd is not available after installing firewalld."
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

  colored_echo "$BLUE" "Allowing SSH port ${SSH_PORT}/tcp in firewalld..."
  if [[ "$SSH_PORT" == "22" ]]; then
    firewall-cmd --permanent --add-service=ssh >/dev/null 2>&1 ||
      firewall-cmd --permanent --add-port=22/tcp >/dev/null
  else
    firewall-cmd --permanent --add-port="${SSH_PORT}/tcp" >/dev/null
  fi

  local webmin_port
  webmin_port="$(detect_webmin_port)"
  if [[ "$webmin_port" =~ ^[0-9]+$ ]]; then
    colored_echo "$BLUE" "Preserving detected Webmin port ${webmin_port}/tcp in firewalld..."
    firewall-cmd --permanent --add-port="${webmin_port}/tcp" >/dev/null
  fi

  firewall-cmd --reload >/dev/null
}

configure_firewalld_post_ssh() {
  if [[ "$SSH_PORT" == "$CURRENT_SSH_PORT" ]]; then
    return 0
  fi

  colored_echo "$BLUE" "Removing previous SSH port (${CURRENT_SSH_PORT}) from firewalld..."
  if [[ "$CURRENT_SSH_PORT" == "22" ]]; then
    firewall-cmd --permanent --remove-service=ssh >/dev/null 2>&1 || true
    firewall-cmd --permanent --remove-port=22/tcp >/dev/null 2>&1 || true
  else
    firewall-cmd --permanent --remove-port="${CURRENT_SSH_PORT}/tcp" >/dev/null 2>&1 || true
  fi
  firewall-cmd --reload >/dev/null
}

configure_ssh() {
  local ssh_dropin_dir="${ROOT_DIR}/etc/ssh/sshd_config.d"
  local ssh_dropin="${ssh_dropin_dir}/99-hardening.conf"
  local backup_file="${TMP_DIR}/99-hardening.conf.bak"
  local had_existing=false
  local disable_password_auth=false

  mkdir -p "$ssh_dropin_dir"
  if [[ -f "$ssh_dropin" ]]; then
    cp "$ssh_dropin" "$backup_file"
    had_existing=true
  fi

  if [[ "$ALLOW_PASSWORD_AUTH" == true ]]; then
    colored_echo "$YELLOW" "Keeping SSH password authentication enabled (--allow-password-auth)."
  elif has_non_root_ssh_keys; then
    disable_password_auth=true
  else
    colored_echo "$YELLOW" "Warning: No non-root user with SSH authorized_keys found; keeping PasswordAuthentication enabled to avoid lockout."
  fi

  colored_echo "$BLUE" "Writing OpenSSH hardening drop-in (${ssh_dropin})..."
  {
    echo "# Managed by harden_server.sh"
    echo "Port ${SSH_PORT}"
    echo "PermitRootLogin no"
    echo "PubkeyAuthentication yes"
    echo "MaxAuthTries 3"
    echo "X11Forwarding no"
    if [[ "$disable_password_auth" == true ]]; then
      echo "PasswordAuthentication no"
      echo "KbdInteractiveAuthentication no"
      echo "ChallengeResponseAuthentication no"
    fi
  } >"$ssh_dropin"
  chmod 600 "$ssh_dropin"

  if ! sshd -t; then
    colored_echo "$RED" "sshd configuration validation failed; rolling back ${ssh_dropin}." >&2
    if [[ "$had_existing" == true ]]; then
      cp "$backup_file" "$ssh_dropin"
    else
      rm -f "$ssh_dropin"
    fi
    die "Aborted SSH hardening due to invalid sshd configuration."
  fi

  if ! command -v systemctl >/dev/null 2>&1; then
    colored_echo "$YELLOW" "systemctl not found; skipping SSH service reload."
    return 0
  fi

  if systemctl is-active --quiet ssh.socket 2>/dev/null || systemctl is-enabled --quiet ssh.socket 2>/dev/null; then
    local socket_dir="${ROOT_DIR}/etc/systemd/system/ssh.socket.d"
    mkdir -p "$socket_dir"
    cat >"${socket_dir}/override.conf" <<EOF
# Managed by harden_server.sh
[Socket]
ListenStream=
ListenStream=${SSH_PORT}
EOF
    systemctl daemon-reload
    systemctl restart ssh.socket
    if systemctl is-active --quiet ssh.service 2>/dev/null; then
      systemctl reload-or-restart ssh.service
    fi
  elif systemctl list-unit-files ssh.service >/dev/null 2>&1 && systemctl is-enabled --quiet ssh.service 2>/dev/null; then
    systemctl reload-or-restart ssh.service
  else
    systemctl reload-or-restart ssh 2>/dev/null || systemctl reload-or-restart sshd
  fi
}

configure_fail2ban() {
  local jail_dir="${ROOT_DIR}/etc/fail2ban/jail.d"
  mkdir -p "$jail_dir"

  local nft_override="${jail_dir}/virtualmin-nftables.conf"
  if [[ -f "$nft_override" ]]; then
    colored_echo "$BLUE" "Removing conflicting Virtualmin nftables Fail2ban override (${nft_override})..."
    rm -f "$nft_override"
  fi

  local ignore_list="127.0.0.1/8 ::1"
  if [[ ${#IGNORE_IPS[@]} -gt 0 ]]; then
    local ip
    for ip in "${IGNORE_IPS[@]}"; do
      ignore_list+=" ${ip}"
    done
  fi

  colored_echo "$BLUE" "Configuring strict Fail2ban jails (maxretry=3, bantime=24h, recidive)..."
  cat >"${jail_dir}/00-defaults.local" <<EOF
# Managed by harden_server.sh
[DEFAULT]
backend = systemd
banaction = firewallcmd-rich-rules
banaction_allports = firewallcmd-rich-rules
ignoreip = ${ignore_list}
bantime = 24h
findtime = 10m
maxretry = 3
EOF

  cat >"${jail_dir}/10-sshd.local" <<EOF
# Managed by harden_server.sh
[sshd]
enabled = true
port = ${SSH_PORT}
backend = systemd
EOF

  cat >"${jail_dir}/20-recidive.local" <<'EOF'
# Managed by harden_server.sh
[recidive]
enabled = true
logpath = /var/log/fail2ban.log
backend = auto
banaction = firewallcmd-rich-rules
bantime = 1w
findtime = 1d
maxretry = 3
EOF

  local webmin_port
  webmin_port="$(detect_webmin_port)"
  if [[ "$webmin_port" =~ ^[0-9]+$ ]]; then
    colored_echo "$BLUE" "Detected Webmin on port ${webmin_port}; enabling Fail2ban webmin-auth jail..."
    cat >"${jail_dir}/30-virtualmin.local" <<EOF
# Managed by harden_server.sh / install_virtualmin.sh
[webmin-auth]
enabled = true
port = ${webmin_port}
backend = systemd
EOF
  fi

  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable --now fail2ban
    systemctl restart fail2ban
  fi
}

configure_unattended_upgrades() {
  local apt_conf_dir="${ROOT_DIR}/etc/apt/apt.conf.d"
  mkdir -p "$apt_conf_dir"

  colored_echo "$BLUE" "Configuring unattended-upgrades for daily security updates..."
  cat >"${apt_conf_dir}/20auto-upgrades" <<'EOF'
// Managed by harden_server.sh
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
EOF

  local reboot_str="false"
  if [[ "$AUTO_REBOOT" == true ]]; then
    reboot_str="true"
  fi

  {
    echo '// Managed by harden_server.sh'
    echo 'Unattended-Upgrade::Origins-Pattern {'
    echo '  "origin=Debian,codename=${distro_codename},label=Debian-Security";'
    echo '  "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";'
    echo '};'
    echo 'Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";'
    echo 'Unattended-Upgrade::Remove-New-Unused-Dependencies "true";'
    echo 'Unattended-Upgrade::Remove-Unused-Dependencies "true";'
    echo "Unattended-Upgrade::Automatic-Reboot \"${reboot_str}\";"
    echo "Unattended-Upgrade::Automatic-Reboot-Time \"${REBOOT_TIME}\";"
    if [[ -n "$NOTIFY_EMAIL" ]]; then
      echo "Unattended-Upgrade::Mail \"${NOTIFY_EMAIL}\";"
      echo 'Unattended-Upgrade::MailReport "on-change";'
    fi
  } >"${apt_conf_dir}/51unattended-upgrades-local"

  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable --now unattended-upgrades 2>/dev/null || true
  fi
}

main() {
  parse_args "$@"

  if [[ "$(id -u)" -ne 0 ]]; then
    die "This script must be run as root."
  fi

  validate_inputs
  check_os
  check_dependencies
  detect_current_ssh_port

  if [[ -z "$SSH_PORT" ]]; then
    if [[ "$ASSUME_YES" == true ]]; then
      SSH_PORT="$CURRENT_SSH_PORT"
    else
      local input_port=""
      prompt_read "Enter SSH port to use [Enter to keep current: ${CURRENT_SSH_PORT}]: " input_port
      SSH_PORT="${input_port:-$CURRENT_SSH_PORT}"
      validate_port "$SSH_PORT" "SSH port"
    fi
  fi

  local webmin_port
  webmin_port="$(detect_webmin_port)"
  if [[ -n "$webmin_port" && "$SSH_PORT" == "$webmin_port" ]]; then
    die "SSH port '${SSH_PORT}' conflicts with detected Webmin port '${webmin_port}'."
  fi

  if [[ "$ASSUME_YES" != true ]]; then
    colored_echo "$YELLOW" "Hardening plan:"
    echo "  - SSH port: ${CURRENT_SSH_PORT} -> ${SSH_PORT} (PermitRootLogin no)"
    echo "  - Firewall: firewalld (allow SSH ${SSH_PORT}/tcp)"
    echo "  - Fail2ban: systemd backend, maxretry=3, bantime=24h, sshd + recidive"
    echo "  - Unattended upgrades: daily security updates (auto-reboot=${AUTO_REBOOT})"
    local confirm=""
    prompt_read "Proceed with server hardening? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
      die "Hardening aborted."
    fi
  fi

  TMP_DIR="$(mktemp -d)"

  install_packages
  configure_firewalld_pre_ssh
  configure_ssh
  configure_firewalld_post_ssh
  configure_fail2ban
  configure_unattended_upgrades

  colored_echo "$GREEN" "Server hardening completed successfully."
  if [[ "$SSH_PORT" != "$CURRENT_SSH_PORT" ]]; then
    colored_echo "$YELLOW" "IMPORTANT: Test SSH login on port ${SSH_PORT} in a new terminal before closing this session!"
  fi
}

main "$@"

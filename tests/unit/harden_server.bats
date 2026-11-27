#!/usr/bin/env bats

bats_require_minimum_version 1.5.0
load test_helper

setup() {
  setup_test_env
  mock_uid 0 root

  FAKE_ROOT="$TEST_TMP/rootfs"
  mkdir -p \
    "$FAKE_ROOT/etc/ssh/sshd_config.d" \
    "$FAKE_ROOT/etc/fail2ban/jail.d" \
    "$FAKE_ROOT/etc/apt/apt.conf.d" \
    "$FAKE_ROOT/home/deploy/.ssh"

  cat >"$FAKE_ROOT/etc/os-release" <<'EOF'
ID=debian
VERSION_ID="12"
EOF

  cat >"$FAKE_ROOT/etc/passwd" <<'EOF'
root:x:0:0:root:/root:/bin/bash
deploy:x:1000:1000::/home/deploy:/bin/bash
EOF

  echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKey deploy@example" >"$FAKE_ROOT/home/deploy/.ssh/authorized_keys"

  export HARDEN_ROOT_DIR="$FAKE_ROOT"

  create_mock apt-get 'echo "apt-get $*" >>"$MOCK_LOG"'
  create_mock firewall-cmd 'echo "firewall-cmd $*" >>"$MOCK_LOG"'
  create_mock sshd '
echo "sshd $*" >>"$MOCK_LOG"
if [[ "${1:-}" == "-T" ]]; then
  echo "port 22"
  exit 0
fi
exit 0
'
  create_mock systemctl '
echo "systemctl $*" >>"$MOCK_LOG"
if [[ "${1:-}" == "is-active" || "${1:-}" == "is-enabled" ]]; then
  if [[ "${3:-}" == "ssh.socket" || "${3:-}" == "nftables" ]]; then
    exit 3
  fi
  exit 0
fi
exit 0
'
}

teardown() {
  unset HARDEN_ROOT_DIR
  teardown_test_env
}

@test "harden_server rejects invalid SSH port values" {
  run bash "$REPO_ROOT/harden_server.sh" --ssh-port 0 -y
  [ "$status" -eq 1 ]
  [[ "$output" == *"Invalid SSH port"* ]]

  run bash "$REPO_ROOT/harden_server.sh" --ssh-port 443 -y
  [ "$status" -eq 1 ]
  [[ "$output" == *"80/443"* ]]

  run bash "$REPO_ROOT/harden_server.sh" --ssh-port 70000 -y
  [ "$status" -eq 1 ]
  [[ "$output" == *"Invalid SSH port"* ]]
}

@test "harden_server rejects invalid reboot-time, email, and ignore-ip" {
  run bash "$REPO_ROOT/harden_server.sh" --reboot-time 25:99 -y
  [ "$status" -eq 1 ]
  [[ "$output" == *"Invalid --reboot-time"* ]]

  run bash "$REPO_ROOT/harden_server.sh" --notify-email 'bad"email' -y
  [ "$status" -eq 1 ]
  [[ "$output" == *"Invalid email"* ]]

  run bash "$REPO_ROOT/harden_server.sh" --ignore-ip '1.2.3.4;rm' -y
  [ "$status" -eq 1 ]
  [[ "$output" == *"Invalid --ignore-ip"* ]]
}

@test "harden_server configures SSH, firewalld, strict fail2ban, and unattended-upgrades" {
  run bash "$REPO_ROOT/harden_server.sh" \
    --ssh-port 2222 \
    --ignore-ip 203.0.113.10 \
    --ignore-ip 198.51.100.0/24 \
    -y

  [ "$status" -eq 0 ]

  # Packages installed
  grep -qF "apt-get update" "$MOCK_LOG"
  grep -qF "apt-get install -y firewalld fail2ban python3-systemd unattended-upgrades" "$MOCK_LOG"

  # SSH drop-in
  [ -f "$FAKE_ROOT/etc/ssh/sshd_config.d/99-hardening.conf" ]
  grep -qF "Port 2222" "$FAKE_ROOT/etc/ssh/sshd_config.d/99-hardening.conf"
  grep -qF "PermitRootLogin no" "$FAKE_ROOT/etc/ssh/sshd_config.d/99-hardening.conf"
  grep -qF "PasswordAuthentication no" "$FAKE_ROOT/etc/ssh/sshd_config.d/99-hardening.conf"

  # Firewall opens new SSH port before removing old port 22
  local add_line remove_line
  add_line="$(grep -nF "firewall-cmd --permanent --add-port=2222/tcp" "$MOCK_LOG" | head -n1 | cut -d: -f1)"
  remove_line="$(grep -nF "firewall-cmd --permanent --remove-service=ssh" "$MOCK_LOG" | head -n1 | cut -d: -f1)"
  [ -n "$add_line" ]
  [ -n "$remove_line" ]
  [ "$add_line" -lt "$remove_line" ]

  # Fail2ban strict jails
  grep -qF "backend = systemd" "$FAKE_ROOT/etc/fail2ban/jail.d/00-defaults.local"
  grep -qF "bantime = 24h" "$FAKE_ROOT/etc/fail2ban/jail.d/00-defaults.local"
  grep -qF "maxretry = 3" "$FAKE_ROOT/etc/fail2ban/jail.d/00-defaults.local"
  grep -qF "ignoreip = 127.0.0.1/8 ::1 203.0.113.10 198.51.100.0/24" "$FAKE_ROOT/etc/fail2ban/jail.d/00-defaults.local"
  grep -qF "port = 2222" "$FAKE_ROOT/etc/fail2ban/jail.d/10-sshd.local"
  grep -qF "[recidive]" "$FAKE_ROOT/etc/fail2ban/jail.d/20-recidive.local"
  grep -qF "backend = auto" "$FAKE_ROOT/etc/fail2ban/jail.d/20-recidive.local"

  # Unattended upgrades
  grep -qF 'APT::Periodic::Unattended-Upgrade "1";' "$FAKE_ROOT/etc/apt/apt.conf.d/20auto-upgrades"
  grep -qF 'Unattended-Upgrade::Automatic-Reboot "false";' "$FAKE_ROOT/etc/apt/apt.conf.d/51unattended-upgrades-local"

  # Low-RAM sysctl, nf_conntrack boot module, and journald caps
  grep -qF "nf_conntrack" "$FAKE_ROOT/etc/modules-load.d/99-nf_conntrack.conf"
  grep -qF "net.ipv4.tcp_syncookies = 1" "$FAKE_ROOT/etc/sysctl.d/99-hardening.conf"
  grep -qF "net.netfilter.nf_conntrack_max = 65536" "$FAKE_ROOT/etc/sysctl.d/99-hardening.conf"
  grep -qF "net.netfilter.nf_conntrack_tcp_timeout_established = 1800" "$FAKE_ROOT/etc/sysctl.d/99-hardening.conf"
  grep -qF "vm.swappiness = 10" "$FAKE_ROOT/etc/sysctl.d/99-hardening.conf"
  grep -qF "SystemMaxUse=100M" "$FAKE_ROOT/etc/systemd/journald.conf.d/99-hardening.conf"
  grep -qF "RuntimeMaxUse=50M" "$FAKE_ROOT/etc/systemd/journald.conf.d/99-hardening.conf"
  grep -qF "systemctl restart systemd-journald" "$MOCK_LOG"

  # Final root-login / Fail2ban unban notice
  [[ "$output" == *"Root SSH login is disabled"* ]]
  [[ "$output" == *"sudo fail2ban-client set sshd unbanip <your-ip>"* ]]
}

@test "harden_server keeps PasswordAuthentication when no non-root SSH keys exist" {
  rm -f "$FAKE_ROOT/home/deploy/.ssh/authorized_keys"

  run bash "$REPO_ROOT/harden_server.sh" --skip-update -y
  [ "$status" -eq 0 ]
  [[ "$output" == *"keeping PasswordAuthentication enabled"* ]]
  run ! grep -qF "PasswordAuthentication no" "$FAKE_ROOT/etc/ssh/sshd_config.d/99-hardening.conf"
  run ! grep -qF "apt-get update" "$MOCK_LOG"
}

@test "harden_server rolls back sshd drop-in when sshd -t fails" {
  create_mock sshd '
echo "sshd $*" >>"$MOCK_LOG"
if [[ "${1:-}" == "-T" ]]; then
  echo "port 22"
  exit 0
fi
if [[ "${1:-}" == "-t" ]]; then
  echo "bad sshd config" >&2
  exit 1
fi
'

  run bash "$REPO_ROOT/harden_server.sh" --ssh-port 2222 --skip-update -y
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid sshd configuration"* ]]
  [ ! -f "$FAKE_ROOT/etc/ssh/sshd_config.d/99-hardening.conf" ]
  run ! grep -qF "remove-service=ssh" "$MOCK_LOG"
}

@test "harden_server updates ssh.socket override when ssh.socket is active" {
  create_mock systemctl '
echo "systemctl $*" >>"$MOCK_LOG"
if [[ "${1:-}" == "is-active" && "${3:-}" == "ssh.socket" ]]; then
  exit 0
fi
exit 0
'

  run bash "$REPO_ROOT/harden_server.sh" --ssh-port 2222 --skip-update -y
  [ "$status" -eq 0 ]
  [ -f "$FAKE_ROOT/etc/systemd/system/ssh.socket.d/override.conf" ]
  grep -qF "ListenStream=2222" "$FAKE_ROOT/etc/systemd/system/ssh.socket.d/override.conf"
  grep -qF "systemctl restart ssh.socket" "$MOCK_LOG"
}

@test "harden_server preserves Webmin port and enables webmin-auth jail if Webmin is already installed" {
  mkdir -p "$FAKE_ROOT/etc/webmin"
  cat >"$FAKE_ROOT/etc/webmin/miniserv.conf" <<'EOF'
port=20443
listen=20443
EOF

  run bash "$REPO_ROOT/harden_server.sh" \
    --ssh-port 2222 \
    --auto-reboot \
    --reboot-time 04:30 \
    --notify-email admin@example.com \
    --skip-update \
    -y

  [ "$status" -eq 0 ]
  grep -qF "firewall-cmd --permanent --add-port=20443/tcp" "$MOCK_LOG"
  [ -f "$FAKE_ROOT/etc/fail2ban/jail.d/30-virtualmin.local" ]
  grep -qF "port = 20443" "$FAKE_ROOT/etc/fail2ban/jail.d/30-virtualmin.local"
  grep -qF 'Unattended-Upgrade::Automatic-Reboot "true";' "$FAKE_ROOT/etc/apt/apt.conf.d/51unattended-upgrades-local"
  grep -qF 'Unattended-Upgrade::Automatic-Reboot-Time "04:30";' "$FAKE_ROOT/etc/apt/apt.conf.d/51unattended-upgrades-local"
  grep -qF 'Unattended-Upgrade::Mail "admin@example.com";' "$FAKE_ROOT/etc/apt/apt.conf.d/51unattended-upgrades-local"
}

@test "harden_server disables conflicting nftables.service and removes virtualmin-nftables.conf" {
  touch "$FAKE_ROOT/etc/fail2ban/jail.d/virtualmin-nftables.conf"
  create_mock systemctl '
echo "systemctl $*" >>"$MOCK_LOG"
if [[ "${1:-}" == "is-active" || "${1:-}" == "is-enabled" ]]; then
  if [[ "${3:-}" == "ssh.socket" ]]; then
    exit 3
  fi
  exit 0
fi
exit 0
'

  run bash "$REPO_ROOT/harden_server.sh" --ssh-port 2222 --skip-update -y
  [ "$status" -eq 0 ]
  grep -qF "systemctl disable --now nftables" "$MOCK_LOG"
  grep -qF "systemctl restart firewalld" "$MOCK_LOG"
  [ ! -f "$FAKE_ROOT/etc/fail2ban/jail.d/virtualmin-nftables.conf" ]
  [ ! -e "$FAKE_ROOT/etc/systemd/system-generators/systemd-ssh-generator" ]
}

@test "harden_server masks systemd-ssh-generator when present on Debian 13+" {
  mkdir -p "$FAKE_ROOT/usr/lib/systemd/system-generators"
  touch "$FAKE_ROOT/usr/lib/systemd/system-generators/systemd-ssh-generator"

  run bash "$REPO_ROOT/harden_server.sh" --skip-update -y
  [ "$status" -eq 0 ]

  local mask_path="$FAKE_ROOT/etc/systemd/system-generators/systemd-ssh-generator"
  [ -L "$mask_path" ]
  [ "$(readlink "$mask_path")" = "/dev/null" ]

  local reload_line install_line
  reload_line="$(grep -nF "systemctl daemon-reload" "$MOCK_LOG" | head -n1 | cut -d: -f1)"
  install_line="$(grep -nF "apt-get install -y" "$MOCK_LOG" | head -n1 | cut -d: -f1)"
  [ -n "$reload_line" ]
  [ -n "$install_line" ]
  [ "$reload_line" -lt "$install_line" ]
}

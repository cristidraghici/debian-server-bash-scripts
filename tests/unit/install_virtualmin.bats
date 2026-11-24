#!/usr/bin/env bats

bats_require_minimum_version 1.5.0
load test_helper

setup() {
  setup_test_env
  mock_uid 0 root

  FAKE_ROOT="$TEST_TMP/rootfs"
  mkdir -p \
    "$FAKE_ROOT/etc/webmin/virtual-server" \
    "$FAKE_ROOT/etc/usermin" \
    "$FAKE_ROOT/etc/fail2ban/jail.d"

  cat >"$FAKE_ROOT/etc/os-release" <<'EOF'
ID=debian
VERSION_ID="12"
EOF

  cat >"$FAKE_ROOT/etc/webmin/miniserv.conf" <<'EOF'
port=10000
listen=10000
ssl=1
EOF

  cat >"$FAKE_ROOT/etc/webmin/virtual-server/config" <<'EOF'
longname=0
template_auto=1
EOF

  export VIRTUALMIN_ROOT_DIR="$FAKE_ROOT"

  create_mock hostname 'echo "panel.example.com"'
  create_mock apt-get 'echo "apt-get $*" >>"$MOCK_LOG"'
  create_mock firewall-cmd 'echo "firewall-cmd $*" >>"$MOCK_LOG"'
  create_mock fail2ban-client 'echo "fail2ban-client $*" >>"$MOCK_LOG"'
  create_mock systemctl 'echo "systemctl $*" >>"$MOCK_LOG"'
  create_mock dpkg-query '
if [[ "$*" == *"usermin"* ]]; then
  echo "install ok installed"
  exit 0
fi
exit 1
'
  create_mock sshd '
if [[ "${1:-}" == "-T" ]]; then
  echo "port 2222"
  exit 0
fi
exit 0
'
  create_mock curl '
echo "curl $*" >>"$MOCK_LOG"
out=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "-o" ]]; then
    out="$2"
    shift 2
  else
    shift
  fi
done
if [[ -n "$out" ]]; then
  cat >"$out" <<'\''SCRIPT'\''
#!/bin/sh
echo "virtualmin-install $*" >>"$MOCK_LOG"
SCRIPT
fi
'
  create_mock virtualmin '
echo "virtualmin $*" >>"$MOCK_LOG"
if [[ "${1:-}" == "get-template" ]]; then
  echo "ujail: 1"
fi
exit 0
'
}

teardown() {
  unset VIRTUALMIN_ROOT_DIR
  teardown_test_env
}

@test "install_virtualmin rejects default port 10000, privileged ports, and SSH port collision" {
  run bash "$REPO_ROOT/install_virtualmin.sh" --webmin-port 10000 -y
  [ "$status" -eq 1 ]
  [[ "$output" == *"must not be the default 10000"* ]]

  run bash "$REPO_ROOT/install_virtualmin.sh" --webmin-port 443 -y
  [ "$status" -eq 1 ]
  [[ "$output" == *"1024 and 65535"* ]]

  run bash "$REPO_ROOT/install_virtualmin.sh" --webmin-port 2222 -y
  [ "$status" -eq 1 ]
  [[ "$output" == *"conflicts with the detected SSH port"* ]]
}

@test "install_virtualmin rejects invalid bundle, quota, and hostname" {
  run bash "$REPO_ROOT/install_virtualmin.sh" --bundle INVALID --webmin-port 20443 -y
  [ "$status" -eq 1 ]
  [[ "$output" == *"Invalid --bundle"* ]]

  run bash "$REPO_ROOT/install_virtualmin.sh" --quota-gb 0 --webmin-port 20443 -y
  [ "$status" -eq 1 ]
  [[ "$output" == *"Invalid --quota-gb"* ]]

  run bash "$REPO_ROOT/install_virtualmin.sh" --hostname localhost --webmin-port 20443 -y
  [ "$status" -eq 1 ]
  [[ "$output" == *"Invalid FQDN"* ]]
}

@test "install_virtualmin requires --webmin-port in non-interactive --yes mode" {
  run bash "$REPO_ROOT/install_virtualmin.sh" -y
  [ "$status" -eq 1 ]
  [[ "$output" == *"--webmin-port"* ]]
}

@test "install_virtualmin performs fresh minimal install, Jailkit, hardening, firewalld, fail2ban, and MOTD" {
  # Simulate fresh host before Virtualmin installer creates virtual-server/config
  rm -f "$FAKE_ROOT/etc/webmin/virtual-server/config"
  create_mock curl '
echo "curl $*" >>"$MOCK_LOG"
out=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "-o" ]]; then
    out="$2"
    shift 2
  else
    shift
  fi
done
if [[ -n "$out" ]]; then
  cat >"$out" <<'\''SCRIPT'\''
#!/bin/sh
echo "virtualmin-install $*" >>"$MOCK_LOG"
mkdir -p "$VIRTUALMIN_ROOT_DIR/etc/webmin/virtual-server"
printf "longname=0\ntemplate_auto=1\n" >"$VIRTUALMIN_ROOT_DIR/etc/webmin/virtual-server/config"
SCRIPT
fi
'

  run bash "$REPO_ROOT/install_virtualmin.sh" --webmin-port 20443 -y
  [ "$status" -eq 0 ]

  # Upstream Virtualmin minimal install invoked with LAMP + mini + detected FQDN
  grep -qF "virtualmin-install --bundle LAMP --type mini --hostname panel.example.com --yes" "$MOCK_LOG"

  # Jailkit installed and automated on Default Settings template
  grep -qF "apt-get install -y jailkit webmin-jailkit" "$MOCK_LOG"
  grep -qF "virtualmin modify-template --id 0 --setting ujail --value 1" "$MOCK_LOG"
  grep -qF "virtualmin get-template --id 0 --setting ujail" "$MOCK_LOG"

  # Usermin purged
  grep -qF "apt-get purge -y usermin" "$MOCK_LOG"
  [ ! -d "$FAKE_ROOT/etc/usermin" ]

  # Webmin port + Virtualmin defaults updated
  grep -qF "port=20443" "$FAKE_ROOT/etc/webmin/miniserv.conf"
  grep -qF "listen=20443" "$FAKE_ROOT/etc/webmin/miniserv.conf"
  grep -qF "longname=1" "$FAKE_ROOT/etc/webmin/virtual-server/config"
  grep -qF "template_auto=0" "$FAKE_ROOT/etc/webmin/virtual-server/config"
  grep -qF "virtualmin modify-plan --id 0 --quota 2097152 --admin-quota 2097152" "$MOCK_LOG"
  grep -qF "systemctl restart webmin" "$MOCK_LOG"

  # Firewalld keeps custom SSH port 2222, opens HTTP/HTTPS/20443, closes 10000
  grep -qF "firewall-cmd --permanent --add-port=2222/tcp" "$MOCK_LOG"
  grep -qF "firewall-cmd --permanent --add-service=http" "$MOCK_LOG"
  grep -qF "firewall-cmd --permanent --add-service=https" "$MOCK_LOG"
  grep -qF "firewall-cmd --permanent --add-port=20443/tcp" "$MOCK_LOG"
  grep -qF "firewall-cmd --permanent --remove-port=10000/tcp" "$MOCK_LOG"

  # Fail2ban handoff drop-in
  [ -f "$FAKE_ROOT/etc/fail2ban/jail.d/30-virtualmin.local" ]
  grep -qF "[webmin-auth]" "$FAKE_ROOT/etc/fail2ban/jail.d/30-virtualmin.local"
  grep -qF "port = 20443" "$FAKE_ROOT/etc/fail2ban/jail.d/30-virtualmin.local"
  grep -qF "maxretry = 3" "$FAKE_ROOT/etc/fail2ban/jail.d/30-virtualmin.local"
  grep -qF "bantime = 24h" "$FAKE_ROOT/etc/fail2ban/jail.d/30-virtualmin.local"

  # Login MOTD installed, executable, and documents jailed-user admin workflow
  [ -x "$FAKE_ROOT/etc/update-motd.d/99-virtualmin-hosting" ]
  grep -qF "https://panel.example.com:20443" "$FAKE_ROOT/etc/update-motd.d/99-virtualmin-hosting"
  grep -qF "sudo -u <domain-user> -H /bin/bash" "$FAKE_ROOT/etc/update-motd.d/99-virtualmin-hosting"
  grep -qF "sudo -u <domain-user> /usr/bin/php -v" "$FAKE_ROOT/etc/update-motd.d/99-virtualmin-hosting"
}

@test "install_virtualmin skips upstream installer on re-run and supports LEMP + custom quota" {
  run bash "$REPO_ROOT/install_virtualmin.sh" \
    --bundle lemp \
    --hostname web.example.org \
    --webmin-port 24443 \
    --quota-gb 5 \
    --skip-update \
    -y

  [ "$status" -eq 0 ]
  [[ "$output" == *"already installed; skipping upstream installer"* ]]
  run ! grep -qF "virtualmin-install" "$MOCK_LOG"
  run ! grep -qF "apt-get update" "$MOCK_LOG"
  grep -qF "virtualmin modify-plan --id 0 --quota 5242880 --admin-quota 5242880" "$MOCK_LOG"
}

@test "install_virtualmin prints manual Jailkit fallback when modify-template fails" {
  create_mock virtualmin '
echo "virtualmin $*" >>"$MOCK_LOG"
if [[ "${1:-}" == "modify-template" ]]; then
  exit 1
fi
exit 0
'

  run bash "$REPO_ROOT/install_virtualmin.sh" --skip-install --skip-update --webmin-port 20443 -y
  [ "$status" -eq 0 ]
  [[ "$output" == *"Manual fallback to enable Jailkit"* ]]
  [[ "$output" == *"Chroot jail new domain Unix users?"* ]]
}

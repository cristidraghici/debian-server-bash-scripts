#!/usr/bin/env bats

bats_require_minimum_version 1.5.0
load test_helper

setup() {
  setup_test_env
  mock_uid 1000 testuser

  create_mock mariadb '
if [[ "${MYSQL_PWD:-}" != "p@ss/w&rd\\test'\''1\"2" ]]; then
  exit 1
fi
exit 0
'
  create_mock curl '
out=""
url=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "-o" ]]; then out="$2"; shift 2; else url="$1"; shift; fi
done
if [[ "$url" == *"api.wordpress.org/secret-key"* ]]; then
  cat <<'\''SALTS'\''
define( '\''AUTH_KEY'\'',         '\''salt-auth-key'\'' );
define( '\''SECURE_AUTH_KEY'\'',  '\''salt-secure-auth-key'\'' );
define( '\''LOGGED_IN_KEY'\'',    '\''salt-logged-in-key'\'' );
define( '\''NONCE_KEY'\'',        '\''salt-nonce-key'\'' );
define( '\''AUTH_SALT'\'',        '\''salt-auth-salt'\'' );
define( '\''SECURE_AUTH_SALT'\'', '\''salt-secure-auth-salt'\'' );
define( '\''LOGGED_IN_SALT'\'',   '\''salt-logged-in-salt'\'' );
define( '\''NONCE_SALT'\'',       '\''salt-nonce-salt'\'' );
SALTS
  exit 0
fi
echo "downloaded:$url" >>"$MOCK_LOG"
echo "FAKEZIP:$url" >"$out"
'
  create_mock unzip '
dest=""
archive=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -d) dest="$2"; shift 2 ;;
    -q|-o) shift ;;
    *) archive="$1"; shift ;;
  esac
done
content="$(cat "$archive")"
if [[ "$content" == *"wordpress.org/latest.zip"* ]]; then
  mkdir -p "$dest/wordpress/wp-content/plugins" "$dest/wordpress/wp-content/themes"
  cat >"$dest/wordpress/wp-config-sample.php" <<'\''CFG'\''
<?php
// Comment mentioning localhost should remain untouched.
define( '\''DB_NAME'\'', '\''database_name_here'\'' );
define( '\''DB_USER'\'', '\''username_here'\'' );
define( '\''DB_PASSWORD'\'', '\''password_here'\'' );
define( '\''DB_HOST'\'', '\''localhost'\'' );
define( '\''AUTH_KEY'\'',         '\''put your unique phrase here'\'' );
define( '\''SECURE_AUTH_KEY'\'',  '\''put your unique phrase here'\'' );
define( '\''LOGGED_IN_KEY'\'',    '\''put your unique phrase here'\'' );
define( '\''NONCE_KEY'\'',        '\''put your unique phrase here'\'' );
define( '\''AUTH_SALT'\'',        '\''put your unique phrase here'\'' );
define( '\''SECURE_AUTH_SALT'\'', '\''put your unique phrase here'\'' );
define( '\''LOGGED_IN_SALT'\'',   '\''put your unique phrase here'\'' );
define( '\''NONCE_SALT'\'',       '\''put your unique phrase here'\'' );
CFG
else
  mkdir -p "$dest/extracted_asset"
fi
'
}

teardown() {
  teardown_test_env
}

@test "install_wp handles special chars in DB password, injects salts, parses defaults, and preserves dotfiles" {
  local defaults="$TEST_WORKDIR/custom.defaults"
  cat >"$defaults" <<'EOF'
# Custom defaults
plugin:contact-form-7
theme:twentytwentyfive
EOF

  local dest="$TEST_WORKDIR/site"
  WP_DB_PASS='p@ss/w&rd\test'\''1"2' run bash "$REPO_ROOT/install_wp.sh" \
    --db-host "db.internal" \
    --db-name "wpdb" \
    --db-user "wpuser" \
    --defaults-file "$defaults" \
    --dest "$dest" \
    --yes

  [ "$status" -eq 0 ]
  [ -f "$dest/wp-config.php" ]
  [ -f "$dest/.htaccess" ]
  [ -f "$dest/.custom.defaults" ] || [ -f "$dest/custom.defaults" ]

  # Verify comment with localhost was NOT clobbered
  grep -qF "// Comment mentioning localhost should remain untouched." "$dest/wp-config.php"
  grep -qF "define( 'DB_HOST', 'db.internal' );" "$dest/wp-config.php"
  grep -qF "define( 'DB_PASSWORD', 'p@ss/w&rd\\\\test\\'1\"2' );" "$dest/wp-config.php"

  # Verify salts were replaced
  run ! grep -qF "put your unique phrase here" "$dest/wp-config.php"
  grep -qF "salt-auth-key" "$dest/wp-config.php"

  # Verify Apache 2.4 directive in .htaccess
  grep -qF "Require all denied" "$dest/.htaccess"
  run ! grep -qF "Order allow,deny" "$dest/.htaccess"

  # Verify both plugin and theme from defaults file were downloaded
  grep -qF "https://downloads.wordpress.org/plugin/contact-form-7.zip" "$MOCK_LOG"
  grep -qF "https://downloads.wordpress.org/theme/twentytwentyfive.zip" "$MOCK_LOG"
}

@test "install_wp refuses to overwrite an existing wp-config.php" {
  local dest="$TEST_WORKDIR/existing_site"
  mkdir -p "$dest"
  touch "$dest/wp-config.php"

  WP_DB_PASS='p@ss/w&rd\test'\''1"2' run bash "$REPO_ROOT/install_wp.sh" \
    --db-name "wpdb" \
    --db-user "wpuser" \
    --dest "$dest" \
    --no-plugins \
    --yes

  [ "$status" -eq 1 ]
  [[ "$output" == *"already contains a wp-config.php"* ]]
}

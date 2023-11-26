#!/bin/bash

# Configuration
DEFAULT_DB_ADDRESS="localhost"
DEFAULTS_FILE=".wp_install_defaults"

# Load defaults from file if it exists
if [ -f "$DEFAULTS_FILE" ]; then
  IFS=';' read -r -a PLUGINS THEMES < "$DEFAULTS_FILE"
else
  PLUGINS=(
    "https://downloads.wordpress.org/plugin/password-protected.2.6.5.1.zip"
    "https://downloads.wordpress.org/plugin/wordpress-seo.21.5.zip"
    "https://downloads.wordpress.org/plugin/wp-dashboard-notes.1.0.10.zip"
    "https://downloads.wordpress.org/plugin/sucuri-scanner.1.8.39.zip"
    "https://downloads.wordpress.org/plugin/simple-page-ordering.2.6.3.zip"
    "https://downloads.wordpress.org/plugin/regenerate-thumbnails.3.1.6.zip"
    "https://downloads.wordpress.org/plugin/litespeed-cache.5.7.0.1.zip"
    "https://downloads.wordpress.org/plugin/login-recaptcha.1.7.1.zip"
    "https://downloads.wordpress.org/plugin/limit-login-attempts-reloaded.2.25.26.zip"
    "https://downloads.wordpress.org/plugin/just-an-admin-button.1.2.0.zip"
    "https://downloads.wordpress.org/plugin/instant-images.6.1.0.zip"
    "https://downloads.wordpress.org/plugin/health-check.1.7.0.zip"
    "https://downloads.wordpress.org/plugin/wpcf7-redirect.3.0.1.zip"
    "https://downloads.wordpress.org/plugin/contact-form-cfdb7.zip"
    "https://downloads.wordpress.org/plugin/contact-form-7.5.8.3.zip"
    "https://downloads.wordpress.org/plugin/child-theme-wizard.1.4.zip"
  )
  THEMES=()
fi

# Color constants
RED="0;31"
GREEN="0;32"
YELLOW="0;33"
BLUE="0;34"

# Function for colored echo messages
colored_echo() {
  local COLOR_CODE="$1"
  local MESSAGE="$2"
  local OPTIONS="${@:3}"

  echo -e $OPTIONS "\033[${COLOR_CODE}m${MESSAGE}\033[0m"
}

# Function to test database credentials
test_db_credentials() {
  local DB_NAME="$1"
  local DB_USER="$2"
  local DB_PASS="$3"
  local DB_ADDRESS="$4"

  # Attempt to connect to the database
  if mysql -h "$DB_ADDRESS" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "quit" 2>/dev/null; then
    return 0  # Success
  else
    return 1  # Failure
  fi
}

# Function to check if a string is a URL
is_url() {
  local URL="$1"
  [[ $URL =~ ^https?:// ]]
}

# Unified function to download and unzip files
download_and_unzip() {
  local URL="$1"
  local DESTINATION="$2"
  local FILE_NAME=$(basename "$URL")

  colored_echo $GREEN "Downloading $URL..."
  if ! wget -q -O "$FILE_NAME" "$URL"; then
    colored_echo $RED "Failed to download $FILE_NAME. Exiting."

    if [ -f "$FILE_NAME" ]; then
      rm "$FILE_NAME"
    fi

    return 1
  fi

  if ! unzip -q "$FILE_NAME" -d "$DESTINATION"; then
    colored_echo $RED "Failed to unzip $FILE_NAME."

    if [ -f "$FILE_NAME" ]; then
      rm "$FILE_NAME"
    fi

    return 1
  fi

  rm "$FILE_NAME"

  return 0
}

# Function to create and update wp-config.php
create_wp_config() {
  local DB_NAME="$1"
  local DB_USER="$2"
  local DB_PASS="$3"
  local DB_ADDRESS="$4"

  local WP_CONFIG_FILE="wordpress/wp-config.php"
  local WP_SAMPLE_CONFIG_FILE="wordpress/wp-config-sample.php"

  # Copy the sample config file to wp-config.php
  cp "$WP_SAMPLE_CONFIG_FILE" "$WP_CONFIG_FILE"

  # Replace database details in wp-config.php
  sed -i "s/database_name_here/$DB_NAME/g" "$WP_CONFIG_FILE"
  sed -i "s/username_here/$DB_USER/g" "$WP_CONFIG_FILE"
  sed -i "s/password_here/$DB_PASS/g" "$WP_CONFIG_FILE"
  sed -i "s/localhost/$DB_ADDRESS/g" "$WP_CONFIG_FILE"

  return 0
}

# Update .htaccess to ignore the defaults file
update_htaccess() {
  local HTACCESS_FILE="wordpress/.htaccess"
  if [ -f "$HTACCESS_FILE" ]; then
    if ! grep -q ".wp_install_defaults" "$HTACCESS_FILE"; then
      echo -e "\n# Ignore .wp_install_defaults file\n<Files .wp_install_defaults>\n\tOrder allow,deny\n\tDeny from all\n</Files>" >> "$HTACCESS_FILE"
    fi
  fi
}

# Ensure the script is not running as root
if [ "$(id -u)" == "0" ]; then
  colored_echo $RED "This script should not be run as root for security reasons."
  exit 1
fi

# Check for required utilities
REQUIRED_UTILS=("wget" "mysql" "unzip")
for UTIL in "${REQUIRED_UTILS[@]}"; do
  if ! command -v $UTIL &> /dev/null; then
    colored_echo $RED "The required utility $UTIL is not installed. Please install it and rerun this script."
    exit 1
  fi
done

# Check if the WordPress directory already exists
if [ -d "wordpress" ]; then
  colored_echo $RED "Error: A 'wordpress' directory already exists. Please remove or rename it before running this script."
  exit 1
fi

# Main script logic
echo

# Ask for database details
colored_echo $YELLOW "Provide the database connection credentials"

read -p "Enter database address [default: $DEFAULT_DB_ADDRESS]: " DB_ADDRESS
DB_ADDRESS=${DB_ADDRESS:-$DEFAULT_DB_ADDRESS}
read -p "Enter database name: " DB_NAME
read -p "Enter database username (leave empty to use '$DB_NAME' as username): " DB_USER
DB_USER=${DB_USER:-$DB_NAME}
read -sp "Enter database password: " DB_PASS
echo

# Test database credentials
if ! test_db_credentials "$DB_NAME" "$DB_USER" "$DB_PASS" "$DB_ADDRESS"; then
  colored_echo $RED "Invalid database credentials or database name. Exiting."
  exit 1
else
  colored_echo $GREEN "The provided credentials are valid."
fi

colored_echo $YELLOW "Proceed with installation? (y/n): " -n
read -n 1 CONFIRM
echo

if [ "$CONFIRM" != "y" ]; then
  colored_echo $RED "Installation aborted."
  exit 1
fi

# Download WordPress, themes, and plugins
download_and_unzip "https://wordpress.org/latest.zip" "."

for PLUGIN in "${PLUGINS[@]}"; do
  if is_url "$PLUGIN"; then
    download_and_unzip "$PLUGIN" "wordpress/wp-content/plugins"
  else
    colored_echo $RED "${PLUGIN} is not a valid URL."
  fi
done

for THEME in "${THEMES[@]}"; do
  if is_url "$THEME"; then
    download_and_unzip "$THEME" "wordpress/wp-content/themes"
  else
    colored_echo $RED "${THEME} is not a valid URL."
  fi
done

# Create wp-config.php (basic example, further configuration may be required)
create_wp_config "$DB_NAME" "$DB_USER" "$DB_PASS" "$DB_ADDRESS"

# Update .htaccess
update_htaccess

# Prompt Nginx users for manual configuration
colored_echo $BLUE "If you are using Nginx, please manually update the server block to deny access to .wp_install_defaults."

# Save the plugins and themes to the defaults file
echo "${PLUGINS[*]};${THEMES[*]}" > "$DEFAULTS_FILE"
if [ -f "$DEFAULTS_FILE" ]; then
  mv "$DEFAULTS_FILE" "wordpress/$DEFAULTS_FILE"
fi

# Prompt for new path
read -p "Enter a new path for WordPress files or leave empty to keep in the current location: " NEW_PATH
if [ -n "$NEW_PATH" ]; then
  mkdir -p "$NEW_PATH"
  mv wordpress/* "$NEW_PATH/"
  rm -rf wordpress
fi

# Prompt to delete the script
colored_echo $YELLOW "Installation complete. Delete this script? (y/n): " -n
read -n 1 DEL_SCRIPT
echo
if [ "$DEL_SCRIPT" == "y" ]; then
  rm -- "$0"
else
  colored_echo $BLUE "The script file was not deleted."
fi

# End of the script
echo

#!/bin/bash

# Define the user's home directory
BIN_DIR="$HOME/bin"
WP_CLI_FILE="$BIN_DIR/wp"

# Check if WP-CLI already exists
if [ -x "$WP_CLI_FILE" ]; then
  echo "WP-CLI is already installed in $BIN_DIR. Installation skipped."
  exit 0
fi

# Download WP-CLI
curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar

# Make WP-CLI executable
chmod +x wp-cli.phar

# Create the 'bin' directory if it doesn't exist
mkdir -p $BIN_DIR

# Move WP-CLI to the 'bin' directory
mv wp-cli.phar $WP_CLI_FILE

# Function to update PATH in the specified file
update_path() {
  local file=$1
  if [ -f "$file" ]; then
    if ! grep -q "$BIN_DIR" "$file"; then
      echo 'export PATH="$PATH:$HOME/bin"' >> "$file"
      source "$file"
    fi
  fi
}

# Update PATH in .zshrc and .bashrc
update_path "$HOME/.zshrc"
update_path "$HOME/.bashrc"

# Verify the installation
wp --version

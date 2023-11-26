#!/bin/bash

# Script to enable specified PHP extensions

# Ensure the script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit
fi

# Function to install and enable extensions for a given PHP version
enable_extensions() {
  local php_version=$1
  shift
  local extensions=("$@")

  echo "Installing extensions for PHP $php_version..."
  for ext in "${extensions[@]}"; do
    echo "Installing $ext..."
    apt-get install -y "php${php_version}-${ext}"
  done

  echo "Restarting Apache to apply changes..."
  systemctl restart apache2

  echo "Extensions enabled for PHP $php_version."
}

# Get PHP version
php_version=$(php -v | grep '^PHP' | cut -d' ' -f2 | cut -d'.' -f1,2 | head -n 1)

if [[ -z "$php_version" ]]; then
  echo "PHP is not installed or not found."
  exit 1
fi

# Check if extensions are provided as command line arguments
if [ $# -eq 0 ]; then
  echo "Enter PHP extensions to install (space-separated, e.g., 'curl gd mbstring'):"
  read -ra extensions
else
  extensions=("$@")
fi

enable_extensions "$php_version" "${extensions[@]}"

#!/bin/bash

# This script installs Composer locally in the user's home directory

# Check if the script is run by a regular user, not root
if [ "$EUID" -eq 0 ]; then 
  echo "Please run as a regular user, not as root"
  exit
fi

echo "Installing Composer for user: $(whoami)"

# Define the installation directory and the composer binary path
INSTALL_DIR=$HOME/.composer
COMPOSER_BIN=$HOME/composer

# Create the installation directory if it does not exist
mkdir -p $INSTALL_DIR

# Download Composer installer
php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"

# Verify installer SHA-384
EXPECTED_SIGNATURE="$(wget -q -O - https://composer.github.io/installer.sig)"
ACTUAL_SIGNATURE="$(php -r "echo hash_file('SHA384', 'composer-setup.php');")"

if [ "$EXPECTED_SIGNATURE" != "$ACTUAL_SIGNATURE" ]
then
    >&2 echo 'ERROR: Invalid installer signature'
    rm composer-setup.php
    exit 1
fi

# Run the installer
php composer-setup.php --quiet --install-dir=$INSTALL_DIR --filename=composer
RESULT=$?

# Remove the installer
rm composer-setup.php

# Check if installation was successful
if [ $RESULT -eq 0 ]; then
    echo "Composer installed successfully in $COMPOSER_BIN"
else
    echo "Composer installation failed"
    exit 1
fi

# Update PATH in .bashrc if the bin directory is not already in PATH
if [ -f $HOME/.bashrc ] && ! grep -q "$INSTALL_DIR" $HOME/.bashrc; then
    echo "export PATH=\"\$PATH:$INSTALL_DIR\"" >> $HOME/.bashrc
    echo "Please log out and log back in or source .bashrc to update PATH."
fi

# Update PATH in .zshrc if the bin directory is not already in PATH
if [ -f $HOME/.zshrc ] && ! grep -q "$INSTALL_DIR" $HOME/.zshrc; then
    echo "export PATH=\"\$PATH:$INSTALL_DIR\"" >> $HOME/.zshrc
    echo "Please log out and log back in or source .zshrc to update PATH."
fi
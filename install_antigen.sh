#!/bin/bash

# Script to install Zsh and Antigen for the current user

# Check the required utils
REQUIRED_UTILS=("git" "zsh")
for UTIL in "${REQUIRED_UTILS[@]}"; do
  if ! command -v $UTIL &> /dev/null; then
    echo "The required utility $UTIL is not installed. Please install it and rerun this script."
    exit
  fi
done

# Check if the script is run by a regular user, not root
if [ "$EUID" -eq 0 ]; then
  echo "Please run as a regular user, not as root"
  exit
fi

# Define Antigen installation path
ANTIGEN_PATH="$HOME/.antigen"

# Check if Antigen is already installed
if [ -d "$ANTIGEN_PATH" ]; then
  echo "Antigen is already installed for user $(whoami)."
  exit
fi

# Create Antigen directory
mkdir -p "$ANTIGEN_PATH"

# Download Antigen
echo "Downloading Antigen..."
curl -L git.io/antigen > "$ANTIGEN_PATH/antigen.zsh"

# Update .zshrc with Antigen configuration
{
echo "# Antigen configuration"
echo "source $ANTIGEN_PATH/antigen.zsh"
echo "antigen use oh-my-zsh"

echo "antigen bundle git"
echo "antigen bundle command-not-found"
echo "antigen bundle zsh-users/zsh-syntax-highlighting"
echo "antigen bundle zsh-users/zsh-autosuggestions"

echo "antigen theme bira"
echo "antigen apply"
} >> "$HOME/.zshrc"

# Check if current shell is Zsh
if [[ "$SHELL" == *"/zsh" ]]; then
  echo "Antigen has been installed and configured for user $(whoami)."
  echo "Please restart your terminal or run 'source ~/.zshrc' to apply changes."
else
  echo "Antigen has been installed for user $(whoami), but the current shell is not Zsh."
  echo "Please switch to Zsh or change your default shell to Zsh."
fi

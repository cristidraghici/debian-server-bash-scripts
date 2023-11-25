#!/bin/bash

# This script downloads and installs the latest version of NVM (Node Version Manager) for the current user

# Check if the script is run by a regular user, not root
if [ "$EUID" -eq 0 ]; then 
  echo "Please run as a regular user, not as root"
  exit
fi

echo "Installing the latest version of NVM (Node Version Manager) for user: $(whoami)"

# Fetch the latest version tag from the NVM GitHub repository
LATEST_NVM_VERSION=$(curl -s https://api.github.com/repos/nvm-sh/nvm/releases/latest | grep 'tag_name' | cut -d\" -f4)

echo "Latest version of NVM: $LATEST_NVM_VERSION"

# Download and execute the install script for the latest version
curl -o- "https://raw.githubusercontent.com/nvm-sh/nvm/${LATEST_NVM_VERSION}/install.sh" | bash

echo "NVM installation complete."
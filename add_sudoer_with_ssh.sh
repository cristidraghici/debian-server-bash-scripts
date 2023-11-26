#!/bin/bash

# Check if the script is run as root
if [ "$(id -u)" != "0" ]; then
  echo "This script must be run as root" 1>&2
  exit 1
fi

# Prompt for the new username
read -p "Enter the new sudo user's name: " USERNAME

# Create a new user and add to sudo group
adduser --gecos "" $USERNAME
usermod -aG sudo $USERNAME

# Lock the root account
passwd -l root

# Setup SSH key for the new user
USER_HOME=$(eval echo ~$USERNAME)
mkdir -p $USER_HOME/.ssh
touch $USER_HOME/.ssh/authorized_keys

echo "Please paste the public SSH key. To retrieve it from your system, you can use the terminal command: 'cat ~/.ssh/id_rsa.pub'"
read SSH_KEY

# Check if the key already exists in the authorized_keys
if grep -qsF "$SSH_KEY" $USER_HOME/.ssh/authorized_keys; then
  echo "Key already exists in authorized_keys."
else
  echo "$SSH_KEY" >> $USER_HOME/.ssh/authorized_keys
  # Set permissions
  chown -R $USERNAME:$USERNAME $USER_HOME/.ssh
  chmod 700 $USER_HOME/.ssh
  chmod 600 $USER_HOME/.ssh/authorized_keys
  echo "SSH key added."
fi

echo "User $USERNAME created and configured."

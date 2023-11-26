#!/bin/bash

# Check if the script is run as root
if [ "$(id -u)" != "0" ]; then
  echo "This script must be run as root" 1>&2
  exit 1
fi

# Prompt for the new username
read -p "Enter the new sudo user's name: " USERNAME

# Check if user already exists
if id "$USERNAME" &>/dev/null; then
  echo "Error: User '$USERNAME' already exists." 1>&2
  exit 1
fi

# Create a new user and add to sudo group
adduser --gecos "" $USERNAME
usermod -aG sudo $USERNAME

# Check if the root account is already locked
ROOT_LOCKED=$(grep '^root:' /etc/shadow | cut -d: -f2)
if [[ $ROOT_LOCKED == '!'* ]]; then
  echo "The root account is already locked."
else
  passwd -l root
fi

# Setup SSH key for the new user
USER_HOME=$(eval echo ~$USERNAME)
mkdir -p $USER_HOME/.ssh
touch $USER_HOME/.ssh/authorized_keys

echo "Please paste the public SSH key, then press Ctrl-D:"
cat >> $USER_HOME/.ssh/authorized_keys

# Set permissions
chown -R $USERNAME:$USERNAME $USER_HOME/.ssh
chmod 700 $USER_HOME/.ssh
chmod 600 $USER_HOME/.ssh/authorized_keys

echo "User $USERNAME created and configured."

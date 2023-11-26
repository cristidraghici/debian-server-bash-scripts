# debian-server-bash-scripts

> Some scripts to help with tasks on a Debian server

## Running the scripts

The safest way to run a script on your server is by downloading it and then inspecting the source code:

1. `wget https://raw.githubusercontent.com/cristidraghici/debian-server-bash-scripts/master/add_sudoer_with_ssh.sh`
2. `cat add_sudoer_with_ssh.sh`
3. `chmod +x add_sudoer_with_ssh.sh`
4. `sudo ./add_sudoer_with_ssh.sh` # make sure not to abuse `sudo`

You can also make the scripts available for every user in the system:

1. `wget https://raw.githubusercontent.com/cristidraghici/debian-server-bash-scripts/master/add_sudoer_with_ssh.sh`
2. `mv add_sudoer_with_ssh.sh /usr/local/bin/add_sudoer_with_ssh.sh`
3. `chmod a+x /usr/local/bin/add_sudoer_with_ssh.sh`

## The fast way

Even if less safe, the faster way is to download and run the scripts in the same command:

- `wget -q -O - https://raw.githubusercontent.com/cristidraghici/debian-server-bash-scripts/master/add_sudoer_with_ssh.sh | sudo bash`
- `wget -q -O - https://raw.githubusercontent.com/cristidraghici/debian-server-bash-scripts/master/install_antigen.sh | sudo bash`
- `wget -q -O - https://raw.githubusercontent.com/cristidraghici/debian-server-bash-scripts/master/install_composer.sh | sudo bash`
- `wget -q -O - https://raw.githubusercontent.com/cristidraghici/debian-server-bash-scripts/master/install_nvm.sh | sudo bash`
- `wget -q -O - https://raw.githubusercontent.com/cristidraghici/debian-server-bash-scripts/master/install_wp_cli.sh | sudo bash`
- `wget -q -O - https://raw.githubusercontent.com/cristidraghici/debian-server-bash-scripts/master/install_wp.sh | sudo bash`
- `wget -q -O - https://raw.githubusercontent.com/cristidraghici/debian-server-bash-scripts/master/enable_php_extension.sh | sudo bash`

You can also have shorthands for creating the system wide available commands:

- `sudo wget -O /usr/local/bin/install_antigen https://raw.githubusercontent.com/cristidraghici/debian-server-bash-scripts/master/install_antigen.sh && sudo chmod +x /usr/local/bin/install_antigen`
- `sudo wget -O /usr/local/bin/install_composer https://raw.githubusercontent.com/cristidraghici/debian-server-bash-scripts/master/install_composer.sh && sudo chmod +x /usr/local/bin/install_composer`
- `sudo wget -O /usr/local/bin/install_nvm https://raw.githubusercontent.com/cristidraghici/debian-server-bash-scripts/master/install_nvm.sh && sudo chmod +x /usr/local/bin/install_nvm`
- `sudo wget -O /usr/local/bin/install_wp_cli https://raw.githubusercontent.com/cristidraghici/debian-server-bash-scripts/master/install_wp_cli.sh && sudo chmod +x /usr/local/bin/install_wp_cli`
- `sudo wget -O /usr/local/bin/install_wp https://raw.githubusercontent.com/cristidraghici/debian-server-bash-scripts/master/install_wp.sh && sudo chmod +x /usr/local/bin/install_wp`
- `sudo wget -O /usr/local/bin/enable_php_extension https://raw.githubusercontent.com/cristidraghici/debian-server-bash-scripts/master/enable_php_extension.sh && sudo chmod +x /usr/local/bin/enable_php_extension`

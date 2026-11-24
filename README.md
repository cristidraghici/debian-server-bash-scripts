# debian-server-bash-scripts

> Self-contained Bash scripts to provision, harden, and manage **Debian 12 (Bookworm)** and **Debian 13 (Trixie)** hosting servers.

Every script is standalone—run a single file directly without cloning the repo. All scripts support `-h` / `--help`, safe interactive prompting via `/dev/tty` (even when piped to `bash`), and CLI flags for unattended automation.

[Fresh Hosting Server Recipe](#fresh-hosting-server-recipe) · [Deploying a Site & Jailed Users](#deploying-a-site--jailed-users) · [Script Reference](#script-reference) · [Development & Testing](#development--testing)

---

## Fresh Hosting Server Recipe

Follow these steps in order on a clean Debian 12 or 13 server to go from a fresh VPS to a hardened, Virtualmin-managed LAMP hosting server.

> **Tip:** Pass flags to any piped script with `-s -- <flags>` (for example, `... | sudo bash -s -- --bundle LEMP`).

<details>
<summary>Prefer to inspect scripts before running them?</summary>

Download, review, and run any script locally instead of piping to `bash`:

```bash
curl -fsSLO https://raw.githubusercontent.com/cristidraghici/debian-server-bash-scripts/master/add_sudoer_with_ssh.sh
less add_sudoer_with_ssh.sh
chmod +x add_sudoer_with_ssh.sh
sudo ./add_sudoer_with_ssh.sh
```

</details>

### Before You Start

- A fresh **Debian 12 (Bookworm)** or **Debian 13 (Trixie)** server with `root` (or `sudo`) access.
- A DNS `A` (and optionally `AAAA`) record pointing your server FQDN (e.g. `panel.example.com`) to the server IP—needed for Virtualmin and Let's Encrypt SSL.
- Your local SSH public key ready to paste (e.g. `~/.ssh/id_ed25519.pub`).

### 1. Update the Base System

Log in as `root` (or prefix with `sudo` if your provider starts you as a cloud user), upgrade packages, and install baseline tools:

```bash
apt-get update && apt-get upgrade -y
apt-get install -y sudo curl git unzip
```

> If a new kernel was installed, `reboot` and reconnect before continuing.

### 2. Create a Sudoer User with SSH Keys

Run as `root`:

```bash
curl -fsSL https://raw.githubusercontent.com/cristidraghici/debian-server-bash-scripts/master/add_sudoer_with_ssh.sh | bash
```

During the prompts:
- Paste your SSH public key(s) and press `Ctrl-D` (keys are validated with `ssh-keygen`).
- **Set a strong password** when prompted (do not use `--disabled-password`)—you will need it for `sudo` and for logging into Virtualmin/Webmin.
- **Before answering `y` to lock `root`**, open a **second terminal** and verify SSH + `sudo` work as the new user:
  ```bash
  ssh <user>@<server-ip>
  sudo -v
  ```

### 3. Harden SSH, Firewall, Fail2ban & Updates

From your new `<user>` SSH session:

```bash
curl -fsSL https://raw.githubusercontent.com/cristidraghici/debian-server-bash-scripts/master/harden_server.sh | sudo bash
```

What this configures:
- **OpenSSH** (`/etc/ssh/sshd_config.d/99-hardening.conf`, validated with `sshd -t`): `PermitRootLogin no`, disables password auth once non-root SSH keys exist, and moves SSH to your chosen port.
- **Firewall (`firewalld`)**: opens the new SSH port and removes the previous one.
- **Fail2ban**: strict `systemd` backend (`maxretry=3`, `bantime=24h`) with `sshd` and `recidive` jails.
- **Unattended upgrades**: daily Debian security patches.

> **Tip:** Have a static admin IP? Whitelist it in Fail2ban with `... | sudo bash -s -- --ignore-ip 203.0.113.10`.

> **Important:** Before closing your current terminal, open a **new terminal** and verify SSH login on the new port:
> ```bash
> ssh -p <ssh-port> <user>@<server-ip>
> ```

### 4. Install & Harden Virtualmin Minimal

From your `<user>` SSH session:

```bash
curl -fsSL https://raw.githubusercontent.com/cristidraghici/debian-server-bash-scripts/master/install_virtualmin.sh | sudo bash
```

You will be prompted for your server FQDN (if not auto-detected) and a custom Webmin port (`1024–65535`, not `10000` or your SSH port—for example `20443`).

What this configures:
- **Virtualmin minimal (`LAMP`)**: Apache, MariaDB, PHP, and Webmin (pass `-s -- --bundle LEMP` if you prefer Nginx).
- **Restrictive Jailkit**: installs `jailkit` + `webmin-jailkit` and enables chroot jailing on Virtualmin's **Default Settings** template.
- **Hardened panel**: purges Usermin (no mail stack), moves Webmin to your custom port, closes `10000/tcp`, and sets full-domain usernames, editable limits, and a `2 GB` default quota.
- **Firewall, Fail2ban & MOTD**: preserves your custom SSH port in `firewalld`, opens HTTP/HTTPS + your Webmin port, adds the `webmin-auth` Fail2ban jail, and installs a helpful login banner (`/etc/update-motd.d/99-virtualmin-hosting`).

> **Note:** `harden_server.sh` and `install_virtualmin.sh` can be run in either order—both detect existing SSH/Webmin ports and wire up `firewalld` and `fail2ban` automatically.

### 5. Install Common PHP Extensions

Install and enable common hosting / WordPress PHP extensions and automatically reload Apache (or PHP-FPM/Nginx):

```bash
curl -fsSL https://raw.githubusercontent.com/cristidraghici/debian-server-bash-scripts/master/enable_php_extension.sh | sudo bash -s -- curl gd imagick intl mbstring xml zip
```

> Pass `-v 8.4` before the extension names if you want to target a specific PHP version instead of auto-detecting.

### 6. Verify & Finish Virtualmin Post-Install

1. Confirm firewall rules and Fail2ban jails from SSH:
   ```bash
   sudo firewall-cmd --list-all
   sudo fail2ban-client status
   ```
   Verify that your custom SSH port, `http`, `https`, and your custom Webmin port are open (`10000/tcp` closed), and that the `sshd`, `recidive`, and `webmin-auth` jails are active.
2. Open `https://<your-fqdn>:<webmin-port>` in your browser and sign in with your **sudoer username and password**.
3. Complete the **Virtualmin Post-Installation Wizard** (MariaDB memory profile, nameservers, and requesting a Let's Encrypt SSL certificate for the Webmin panel hostname).

### 7. Optional: Admin & Developer CLI Tools

Run these as your regular sudoer user (**without** `sudo`)—binaries install to `~/.local/bin` and shell startup files are updated idempotently:

```bash
# Composer (SHA-384 verified)
curl -fsSL https://raw.githubusercontent.com/cristidraghici/debian-server-bash-scripts/master/install_composer.sh | bash

# WP-CLI (SHA-512 verified)
curl -fsSL https://raw.githubusercontent.com/cristidraghici/debian-server-bash-scripts/master/install_wp_cli.sh | bash

# NVM (Node Version Manager)
curl -fsSL https://raw.githubusercontent.com/cristidraghici/debian-server-bash-scripts/master/install_nvm.sh | bash

# Antigen for Zsh (requires zsh: sudo apt-get install -y zsh)
curl -fsSL https://raw.githubusercontent.com/cristidraghici/debian-server-bash-scripts/master/install_antigen.sh | bash
```

Restart your shell (or `source ~/.bashrc` / `source ~/.zshrc`) to apply the updated `PATH`.

---

## Deploying a Site & Jailed Users

New domains created in Virtualmin automatically place their Unix user inside a **restrictive Jailkit chroot** (without copying host PHP, Git, Composer, WP-CLI, or database binaries into every domain's jail).

### Running Host Tools as a Jailed Domain User

From your sudoer account, use `sudo -u` to run host binaries under the domain user's UID and permissions:

```bash
# Open an interactive host shell as the domain user (preserving their HOME)
sudo -u <domain-user> -H /bin/bash

# Or run a single host binary directly
sudo -u <domain-user> /usr/bin/php -v
```

> These commands and your panel URL are also shown on SSH login via `/etc/update-motd.d/99-virtualmin-hosting`.

### Installing WordPress in a Domain

From a host shell as the domain user (`sudo -u <domain-user> -H /bin/bash`), run:

```bash
curl -fsSL https://raw.githubusercontent.com/cristidraghici/debian-server-bash-scripts/master/install_wp.sh | bash -s -- --dest ~/public_html
```

This downloads WordPress core plus unpinned plugins/themes, generates fresh authentication salts and a safe `wp-config.php`, and configures an Apache 2.4 `.htaccess`.

<details>
<summary>Customizing WordPress plugins & themes (<code>.wp_install_defaults</code>)</summary>

`install_wp.sh` reads `.wp_install_defaults` (or `--defaults-file <path>`) with one entry per line:

```text
# Slugs resolve automatically to https://downloads.wordpress.org/<type>/<slug>.zip
plugin:contact-form-7
plugin:wordpress-seo
plugin:https://example.com/custom-plugin.zip
theme:twentytwentyfive
```

</details>

---

## Script Reference

### System Scripts (`sudo`)

| Script | Dependencies | Summary |
| :--- | :--- | :--- |
| [`add_sudoer_with_ssh.sh`](./add_sudoer_with_ssh.sh) | `adduser`, `sudo`, `openssh-client` | Creates a sudoer user, validates SSH public key(s) with `ssh-keygen`, and optionally locks `root` (`--lock-root`). |
| [`harden_server.sh`](./harden_server.sh) | `apt-get`, `sshd` | Hardens OpenSSH (drop-in + `sshd -t`), configures `firewalld`, strict `fail2ban` (`systemd` + `recidive`), and `unattended-upgrades`. |
| [`install_virtualmin.sh`](./install_virtualmin.sh) | `apt-get`, `curl`, `hostname` | Installs Virtualmin minimal (`LAMP`/`LEMP`) with restrictive Jailkit, custom Webmin port, Usermin purge, `firewalld`, `fail2ban` handoff, and login MOTD. |
| [`enable_php_extension.sh`](./enable_php_extension.sh) | `apt-get`, `php` (or `-v`) | Installs & enables PHP extensions in one APT call and reloads active Apache or PHP-FPM/Nginx services. |

### User & Developer Scripts (regular user, `--root` opt-in)

| Script | Dependencies | Summary |
| :--- | :--- | :--- |
| [`install_composer.sh`](./install_composer.sh) | `php`, `curl` | Downloads Composer, verifies its SHA-384 signature, and installs to `~/.local/bin/composer`. |
| [`install_wp_cli.sh`](./install_wp_cli.sh) | `curl`, `php`, `sha512sum` | Downloads WP-CLI, verifies its SHA-512 checksum, and installs to `~/.local/bin/wp`. |
| [`install_nvm.sh`](./install_nvm.sh) | `curl`, `git` | Installs the latest (or `--version`) NVM release and updates `~/.bashrc` and `~/.zshrc` idempotently. |
| [`install_antigen.sh`](./install_antigen.sh) | `git`, `zsh`, `curl` | Installs Antigen from GitHub into `~/.antigen` and configures `~/.zshrc` idempotently. |
| [`install_wp.sh`](./install_wp.sh) | `curl`, `unzip`, `mariadb-client` | Standalone WordPress installer with unpinned plugins/themes, fresh WP salts, safe `wp-config.php`, and Apache 2.4 `.htaccess`. |

**Conventions:**
- **User binaries** default to `~/.local/bin` (override with `--install-dir`) and update `~/.bashrc` / `~/.zshrc` idempotently.
- **Root safety**: user-scoped scripts refuse to run as `root` unless `--root` is passed explicitly.
- **Help**: pass `--help` to any script to list all flags and examples.

<details>
<summary>Non-interactive automation examples</summary>

```bash
# Create a deploy user with a validated SSH key (without locking root)
sudo ./add_sudoer_with_ssh.sh -u deploy --ssh-key-file ~/.ssh/id_ed25519.pub --disabled-password --no-lock-root

# Harden SSH, firewalld, Fail2ban (strict + recidive), and unattended-upgrades
sudo ./harden_server.sh --ssh-port 2222 --ignore-ip 203.0.113.10 -y

# Install Virtualmin minimal (LAMP) with restrictive Jailkit and a custom Webmin port
sudo ./install_virtualmin.sh --hostname panel.example.com --webmin-port 20443 -y

# Enable extensions for PHP 8.4 and reload active Apache or PHP-FPM/Nginx
sudo ./enable_php_extension.sh -v 8.4 curl gd mbstring intl zip

# Install WordPress unattended (pass DB password via env var to keep it out of shell history)
WP_DB_PASS='your-strong-password' ./install_wp.sh \
  --db-host localhost \
  --db-name wp_site \
  --db-user wp_user \
  --dest /var/www/site \
  --yes
```

</details>

<details>
<summary>Install scripts system-wide into <code>/usr/local/bin</code></summary>

Install all scripts as local commands without `.sh` extensions:

```bash
BASE_URL="https://raw.githubusercontent.com/cristidraghici/debian-server-bash-scripts/master"
for script in \
  add_sudoer_with_ssh enable_php_extension harden_server install_virtualmin \
  install_antigen install_composer install_nvm install_wp_cli install_wp; do
  sudo curl -fsSL -o "/usr/local/bin/${script}" "${BASE_URL}/${script}.sh"
  sudo chmod +x "/usr/local/bin/${script}"
done
```

</details>

---

## Development & Testing

<details>
<summary>Local linting, unit tests, Docker smoke tests & Git hooks</summary>

Run static analysis locally:

```bash
shellcheck -S warning ./*.sh tests/docker/*.sh .githooks/pre-push
shfmt -i 2 -ci -d ./*.sh tests/docker/*.sh .githooks/pre-push
```

Run BATS unit tests:

```bash
bats tests/unit/
```

Run the full Docker smoke test suite on Debian 12 or 13:

```bash
docker run --rm -v "$PWD:/workspace:ro" debian:bookworm bash /workspace/tests/docker/smoke_test.sh
docker run --rm -v "$PWD:/workspace:ro" debian:trixie bash /workspace/tests/docker/smoke_test.sh
```

### Git Hooks

Enable the bundled `pre-push` hook (runs `shellcheck`, `shfmt`, and `bats` before pushing; delete-only pushes are skipped):

```bash
git config core.hooksPath .githooks
```

Install the required local tools:

```bash
# macOS (Homebrew)
brew install shellcheck shfmt bats-core

# Debian / Ubuntu
sudo apt-get install -y shellcheck shfmt bats
```

</details>

## License

[MIT](./LICENSE)

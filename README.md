# debian-server-bash-scripts

> Self-contained Bash scripts for common administration and developer setup tasks on **Debian 12 (Bookworm)** and **Debian 13 (Trixie)** servers.

Every script is standalone—you can download and run a single file without cloning the repository. All scripts support `-h` / `--help`, safe interactive prompting (even when stdin is piped via `/dev/tty`), and CLI flags for non-interactive automation.

## Scripts Overview

| Script | Run As | Dependencies | Summary |
| :--- | :--- | :--- | :--- |
| [`add_sudoer_with_ssh.sh`](./add_sudoer_with_ssh.sh) | `root` (`sudo`) | `adduser`, `sudo`, `openssh-client` | Creates a sudoer user, validates SSH public key(s) with `ssh-keygen`, and optionally locks `root` (`--lock-root`). |
| [`enable_php_extension.sh`](./enable_php_extension.sh) | `root` (`sudo`) | `apt-get`, `php` (or `--php-version`) | Installs & enables PHP extensions in one APT call and reloads active Apache or PHP-FPM/Nginx services. |
| [`install_antigen.sh`](./install_antigen.sh) | Regular user (`--root` opt-in) | `git`, `zsh`, `curl` | Installs Antigen from GitHub into `~/.antigen` and configures `~/.zshrc` idempotently. |
| [`install_composer.sh`](./install_composer.sh) | Regular user (`--root` opt-in) | `php`, `curl` | Downloads Composer, verifies its SHA-384 signature, and installs to `~/.local/bin/composer`. |
| [`install_nvm.sh`](./install_nvm.sh) | Regular user (`--root` opt-in) | `curl`, `git` | Installs the latest (or `--version`) NVM release and updates `~/.bashrc` and `~/.zshrc` idempotently. |
| [`install_wp_cli.sh`](./install_wp_cli.sh) | Regular user (`--root` opt-in) | `curl`, `php`, `sha512sum` | Downloads WP-CLI, verifies its SHA-512 checksum, and installs to `~/.local/bin/wp`. |
| [`install_wp.sh`](./install_wp.sh) | Regular user (`--root` opt-in) | `curl`, `unzip`, `mariadb-client` | Standalone WordPress installer with unpinned plugins/themes, fresh WP salts, safe `wp-config.php`, and Apache 2.4 `.htaccess`. |

## Conventions

- **User binaries**: User-scoped CLI installers (`install_composer.sh`, `install_wp_cli.sh`) default to `~/.local/bin` (XDG standard) and add it to `~/.bashrc` / `~/.zshrc` idempotently. Override with `--install-dir`.
- **Root safety**: User-scoped scripts refuse to run as `root` by default. Pass `--root` explicitly if you intentionally want a root installation.
- **Help & automation**: Pass `--help` to any script to see all available flags and examples.

## Running the Scripts

### Recommended: Download, Inspect, Run

```bash
curl -fsSLO https://raw.githubusercontent.com/cristidraghici/debian-server-bash-scripts/master/add_sudoer_with_ssh.sh
less add_sudoer_with_ssh.sh
chmod +x add_sudoer_with_ssh.sh
sudo ./add_sudoer_with_ssh.sh
```

### Quick One-Liners

System scripts require `sudo`:

```bash
curl -fsSL https://raw.githubusercontent.com/cristidraghici/debian-server-bash-scripts/master/add_sudoer_with_ssh.sh | sudo bash
curl -fsSL https://raw.githubusercontent.com/cristidraghici/debian-server-bash-scripts/master/enable_php_extension.sh | sudo bash -s -- curl gd mbstring
```

User-scoped scripts should run **without** `sudo`:

```bash
curl -fsSL https://raw.githubusercontent.com/cristidraghici/debian-server-bash-scripts/master/install_antigen.sh | bash
curl -fsSL https://raw.githubusercontent.com/cristidraghici/debian-server-bash-scripts/master/install_composer.sh | bash
curl -fsSL https://raw.githubusercontent.com/cristidraghici/debian-server-bash-scripts/master/install_nvm.sh | bash
curl -fsSL https://raw.githubusercontent.com/cristidraghici/debian-server-bash-scripts/master/install_wp_cli.sh | bash
curl -fsSL https://raw.githubusercontent.com/cristidraghici/debian-server-bash-scripts/master/install_wp.sh | bash
```

> **Tip:** To pass flags to a piped script, append `-s -- <flags>` (for example, `... | bash -s -- --version v0.40.3`).

### Install System-Wide Commands (`/usr/local/bin`)

```bash
sudo curl -fsSL -o /usr/local/bin/add_sudoer_with_ssh https://raw.githubusercontent.com/cristidraghici/debian-server-bash-scripts/master/add_sudoer_with_ssh.sh && sudo chmod +x /usr/local/bin/add_sudoer_with_ssh
sudo curl -fsSL -o /usr/local/bin/enable_php_extension https://raw.githubusercontent.com/cristidraghici/debian-server-bash-scripts/master/enable_php_extension.sh && sudo chmod +x /usr/local/bin/enable_php_extension
sudo curl -fsSL -o /usr/local/bin/install_antigen https://raw.githubusercontent.com/cristidraghici/debian-server-bash-scripts/master/install_antigen.sh && sudo chmod +x /usr/local/bin/install_antigen
sudo curl -fsSL -o /usr/local/bin/install_composer https://raw.githubusercontent.com/cristidraghici/debian-server-bash-scripts/master/install_composer.sh && sudo chmod +x /usr/local/bin/install_composer
sudo curl -fsSL -o /usr/local/bin/install_nvm https://raw.githubusercontent.com/cristidraghici/debian-server-bash-scripts/master/install_nvm.sh && sudo chmod +x /usr/local/bin/install_nvm
sudo curl -fsSL -o /usr/local/bin/install_wp_cli https://raw.githubusercontent.com/cristidraghici/debian-server-bash-scripts/master/install_wp_cli.sh && sudo chmod +x /usr/local/bin/install_wp_cli
sudo curl -fsSL -o /usr/local/bin/install_wp https://raw.githubusercontent.com/cristidraghici/debian-server-bash-scripts/master/install_wp.sh && sudo chmod +x /usr/local/bin/install_wp
```

## Non-Interactive Automation Examples

```bash
# Create a deploy user with a validated SSH key (without locking root)
sudo ./add_sudoer_with_ssh.sh -u deploy --ssh-key-file ~/.ssh/id_ed25519.pub --disabled-password --no-lock-root

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

### Customizing WordPress Plugins & Themes (`.wp_install_defaults`)

`install_wp.sh` reads `.wp_install_defaults` (or `--defaults-file <path>`) with one entry per line:

```text
# Slugs resolve automatically to https://downloads.wordpress.org/<type>/<slug>.zip
plugin:contact-form-7
plugin:wordpress-seo
plugin:https://example.com/custom-plugin.zip
theme:twentytwentyfive
```

## Development & Testing

Run static analysis locally:

```bash
shellcheck -S warning ./*.sh tests/docker/*.sh
shfmt -i 2 -ci -d ./*.sh tests/docker/*.sh
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

## License

[MIT](./LICENSE)

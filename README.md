````markdown
# bootstrap-nextjs.sh

Cross-platform, production-grade provisioning for Next.js projects

## Prerequisites

- A POSIX-compliant shell (bash)
- **Root** privileges (script must run as root)
- One of the following package managers:
  - Debian/Ubuntu: `apt-get`
  - Red Hat/CentOS: `yum`
  - macOS: `brew`
- Installed or installable packages:
  - `curl`
  - `git`
  - `jq`
  - `gh` (GitHub CLI) or `glab` (GitLab CLI) if you want remote repo creation
  - `docker`
  - `docker-compose` (or Docker Compose v2 via `docker compose`)
  - `vault` CLI (if using Vault for secrets)
  - `aws` CLI (if using AWS Secrets Manager)
  - `tar`, `ss`, `gpg`
- Network access to:
  - Your template repository (HTTPS)
  - Vault or AWS Secrets Manager endpoints (if using)

## Installation

1. Download the script:
   ```bash
   wget https://…/bootstrap-nextjs.sh -O bootstrap-nextjs.sh
   chmod +x bootstrap-nextjs.sh
````

2. (Optional) Generate a sample config:

   ```bash
   sudo ./bootstrap-nextjs.sh --generate-config
   ```

   Edit `~/.bootstrap_nextjs.conf` to customize defaults.

## Usage

```bash
sudo ./bootstrap-nextjs.sh [options]
```

### Required

* `-n NAME`
  Project name (alphanumeric, `_`, or `-`).

### Common Options

* `-v VISIBILITY`
  `public` or `private` (default: `public`).

* `-t TEMPLATE_REPO`
  Template repo URL (must start with `https://`).

* `-r TEMPLATE_REF`
  Template branch or tag (default: `main`).

* `--projects-root DIR`
  Base directory for new projects (default: `~/progetti`).

* `--backup-root DIR`
  Mirror backup directory (default: `~/backup/repos`).

* `--port-start NUM`
  Starting port (1024–65535; default: `3000`).

* `--retention-days NUM`
  Backup retention in days (default: `30`).

* `--secret-provider vault|aws|none`
  Secrets backend (default: `vault`).

* `--dry-run`
  Show planned actions without executing.

* `--yes`
  Non-interactive mode (assume “yes” to all prompts).

* `--skip-vault`
  Don’t fetch secrets from Vault.

* `--skip-backup`
  Don’t mirror the repo.

* `--skip-remote`
  Don’t create a remote repo.

* `--no-enable-docker`
  Install Docker but don’t enable/start via systemd.

* `--verbose`
  Enable debug tracing.

* `-h, --help`
  Show help and exit.

## Examples

```bash
# Generate a sample config
sudo ./bootstrap-nextjs.sh -n my-app --generate-config

# Dry run, private project, custom template
sudo ./bootstrap-nextjs.sh -n my-app -v private \
  -t https://github.com/your-org/nextjs-template.git --dry-run

# Non-interactive, skip backup
sudo ./bootstrap-nextjs.sh -n my-app --yes --skip-backup
```

## What It Does

1. Detects OS and installs prerequisites (curl, git, jq, gh, docker, etc.).
2. Installs/enables Docker & Docker Compose.
3. Clones the Next.js template repo.
4. Assigns a free port from your `--port-start`.
5. Generates `Dockerfile`, `.dockerignore`, and `docker-compose.yml`.
6. Fetches or writes `.env` (Vault, AWS, or example).
7. Detects Node version via `.nvmrc` or `package.json`.
8. Initializes a local Git repo and commits.
9. Creates a remote repo on GitHub/GitLab (unless skipped).
10. Generates a simple `README.md`.
11. Sets up a GitHub Actions CI workflow.
12. Mirrors the repo to your backup directory and prunes old backups.
13. Starts the Docker container.
14. Prints a summary (URLs, port, log file).

## Logging

All actions are logged to `~/bootstrap_nextjs.log`. Check this file for troubleshooting.

## Configuration

Create `~/.bootstrap_nextjs.conf` to override defaults:

```bash
# ~/.bootstrap_nextjs.conf
PROJECTS_ROOT="$HOME/progetti"
BACKUP_ROOT="$HOME/backup/repos"
PORT_START=3000
RETENTION_DAYS=30
TEMPLATE_REPO="https://github.com/your-org/nextjs-template.git"
TEMPLATE_REF="main"
IMAGE_REGISTRY="ghcr.io/your-org"
BASE_IMAGE="node:18-alpine"
BRANCH="main"
SECRET_PROVIDER="vault"
```

## Troubleshooting

* **Not root?** Run with `sudo`.
* **Port in use?** Choose a different `--port-start`.
* **Vault errors?** Ensure `VAULT_ADDR`, `VAULT_ROLE_ID`, and `VAULT_SECRET_ID` are set.
* **AWS errors?** Make sure your AWS CLI is configured.



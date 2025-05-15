# Bootstrap Next.js Script

This guide will walk you through preparing your Ubuntu server and running the `bootstrap-nextjs.sh` script to provision a new Next.js project with Docker, Git, and secret management.

---

## Prerequisites

1. **Ubuntu Server** (18.04+, 20.04, or 22.04)  
2. **SSH Access** with a user that can run `sudo`  
3. **Git** installed on your server (the script will install if missing)  
4. **Docker** and **Docker Compose** (the script will install and enable by default)  
5. **GitHub CLI** (`gh`) or **GitLab CLI** (`glab`) if you plan to create a remote repo  
6. **Vault CLI** or **AWS CLI** if you use the corresponding secret provider  

---

## Step 1: Transfer & Prepare the Script

1. **Copy** `bootstrap-nextjs.sh` to your server:

   ```bash
   scp bootstrap-nextjs.sh user@your-server:/home/user/

    SSH into your server:

ssh user@your-server

Make the script executable:

    chmod +x ~/bootstrap-nextjs.sh

Step 2: (Optional) Generate & Customize Config

You can generate a default config file to avoid passing flags every run:

sudo ~/bootstrap-nextjs.sh --generate-config

This creates ~/.bootstrap_nextjs.conf: edit it to set defaults:

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

Step 3: Set Environment Variables for Secrets

    Vault provider:

export VAULT_ADDR="https://vault.example.com"
export VAULT_ROLE_ID="<your-role-id>"
export VAULT_SECRET_ID="<your-secret-id>"
export VAULT_PATH="secret/data"

AWS provider (if selected):

    aws configure

If you choose none, the script will generate an .env.example file.
Step 4: Install & Authenticate Git CLI

    GitHub CLI:

sudo apt update && sudo apt install gh -y
gh auth login

GitLab CLI:

    sudo apt install glab -y
    glab auth login

This ensures the script can create a remote repo if --skip-remote is not used.
Step 5: Run the Script

Use sudo (the script requires root to install packages and enable Docker):

sudo ~/bootstrap-nextjs.sh \
  -n my-app \
  -v private \
  -t https://github.com/your-org/nextjs-template.git \
  -r main

    -n: Project name (alphanumeric, _ or -)

    -v: Visibility (public or private)

    -t and -r: Template URL and branch/tag (if not set in config)

To preview actions without changing anything, add --dry-run:

sudo ~/bootstrap-nextjs.sh -n my-app --dry-run

Step 6: After Completion

    Your project is created under $PROJECTS_ROOT/my-app.

    Docker container is running on the first available port starting at PORT_START (default 3000).

    A backup mirror is stored in $BACKUP_ROOT/my-app.git.

    Check logs in ~/bootstrap_nextjs.log for details.

cd ~/progetti/my-app
docker compose ps
tail -n 50 ~/bootstrap_nextjs.log

Enjoy your new Next.js project!

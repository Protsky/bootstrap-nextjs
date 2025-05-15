#!/usr/bin/env bash
#
# bootstrap-nextjs.sh
# Cross-platform, production-grade provisioning for Next.js projects
#
set -Eeuo pipefail
trap 'error $LINENO "Unexpected error."' ERR
trap cleanup EXIT INT TERM HUP

##############################################
# Load user overrides and plugins
CONFIG_FILE="${HOME}/.bootstrap_nextjs.conf"
if [[ -f "$CONFIG_FILE" ]]; then
  chmod 600 "$CONFIG_FILE"
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
fi
if [[ -d "${HOME}/.bootstrap_nextjs.d" ]]; then
  for plug in "${HOME}/.bootstrap_nextjs.d/"*.sh; do
    [[ -r "$plug" ]] && # shellcheck source=/dev/null
    source "$plug"
  done
fi

##############################################
# Defaults
readonly DEFAULT_PROJECTS_ROOT="${HOME}/progetti"
readonly DEFAULT_BACKUP_ROOT="${HOME}/backup/repos"
readonly DEFAULT_PORT_START=3000
readonly DEFAULT_RETENTION_DAYS=30

DRY_RUN=false
YES=false
GENERATE_CONFIG=false
SKIP_VAULT=false
SKIP_BACKUP=false
SKIP_REMOTE=false
VERBOSE=false
NO_ENABLE_DOCKER=false

SECRET_PROVIDER="${SECRET_PROVIDER:-vault}"
PROJECTS_ROOT="${PROJECTS_ROOT:-$DEFAULT_PROJECTS_ROOT}"
BACKUP_ROOT="${BACKUP_ROOT:-$DEFAULT_BACKUP_ROOT}"
LOG_FILE="${LOG_FILE:-${HOME}/bootstrap_nextjs.log}"
RETENTION_DAYS="${RETENTION_DAYS:-$DEFAULT_RETENTION_DAYS}"
PORT_START="${PORT_START:-$DEFAULT_PORT_START}"

# To be set later
PROJECT_NAME=""
VISIBILITY="public"
TEMPLATE_REPO=""
TEMPLATE_REF="main"
IMAGE_REGISTRY=""
BASE_IMAGE=""
BRANCH="main"
GIT_PROVIDER="${GIT_PROVIDER:-github}"

# Temp globals
LOCKDIR=""
LOCK_FD=""
DEST=""
PORT=""
OS=""
PKG_CMD=""
DC=""

##############################################
usage() {
  cat <<EOF
Usage: $0 [options]

Bootstrap a Next.js project with Docker, Git provider, and secrets.

Options:
  -n NAME              Project name (required; alphanum,_,-)
  -v VIS               public|private (default: public)
  -t URL               Template repo URL (https://…)
  -r REF               Template branch/tag (default: main)
      --projects-root DIR
                       Projects root (default: $PROJECTS_ROOT)
      --backup-root DIR
                       Backup root (default: $BACKUP_ROOT)
      --port-start NUM Starting port (1024–65535; default: $PORT_START)
      --retention-days NUM
                       Backup retention days (default: $RETENTION_DAYS)
      --secret-provider vault|aws|none (default: vault)
      --dry-run        Show actions without executing
      --yes            Non-interactive
      --generate-config
                       Write ~/.bootstrap_nextjs.conf and exit
      --skip-vault     Do not fetch secrets
      --skip-backup    Do not create mirror backup
      --skip-remote    Do not create remote repo
      --no-enable-docker
                       Install docker but do not enable systemd
      --verbose        Debug tracing
  -h, --help           Show this help and exit

Examples:
  $0 -n my-app -v private --generate-config
  $0 --name my-app --dry-run
EOF
  exit 1
}

##############################################
log()    { printf '[%s][INFO] %s\n'  "$(date +'%Y-%m-%dT%H:%M:%S')" "$*" >>"$LOG_FILE"; }
warn()   { printf '[%s][WARN] %s\n'  "$(date +'%Y-%m-%dT%H:%M:%S')" "$*" >>"$LOG_FILE"; }
echo_ok(){ printf '[%s] %s\n'        "$(date +'%H:%M:%S')" "$*"; }
error() {
  local lineno=$1; shift
  printf '[%s][ERROR] %s (line %d)\n' \
    "$(date +'%Y-%m-%dT%H:%M:%S')" "$*" "$lineno" | tee -a "$LOG_FILE" >&2
  cleanup
  exit 1
}

cleanup() {
  if [[ -n "${LOCK_FD:-}" ]]; then
    flock -u "$LOCK_FD" 2>/dev/null || :
    eval "exec ${LOCK_FD}>&-"
  fi
  [[ -d "${LOCKDIR:-}" ]] && rm -rf "$LOCKDIR"
  [[ -d "${DEST:-}" && ! -d "${DEST}/.git" ]] && rm -rf "$DEST" && warn "Removed partial $DEST"
}

run_cmd() {
  local cmd=("$@")
  if [[ "$DRY_RUN" == true ]]; then
    log "[DRY-RUN] ${cmd[*]}"
  else
    "${cmd[@]}"
  fi
}

##############################################
# Parse args (portable)
while [[ $# -gt 0 ]]; do
  case $1 in
    -n)           PROJECT_NAME="$2"; shift 2;;
    -v)           VISIBILITY="$2"; shift 2;;
    -t)           TEMPLATE_REPO="$2"; shift 2;;
    -r)           TEMPLATE_REF="$2"; shift 2;;
    --projects-root)   PROJECTS_ROOT="$2"; shift 2;;
    --backup-root)     BACKUP_ROOT="$2"; shift 2;;
    --port-start)      PORT_START="$2"; shift 2;;
    --retention-days)  RETENTION_DAYS="$2"; shift 2;;
    --secret-provider) SECRET_PROVIDER="$2"; shift 2;;
    --dry-run)         DRY_RUN=true; shift;;
    --yes)             YES=true; shift;;
    --generate-config) GENERATE_CONFIG=true; shift;;
    --skip-vault)      SKIP_VAULT=true; shift;;
    --skip-backup)     SKIP_BACKUP=true; shift;;
    --skip-remote)     SKIP_REMOTE=true; shift;;
    --no-enable-docker) NO_ENABLE_DOCKER=true; shift;;
    --verbose)         VERBOSE=true; shift;;
    -h|--help)        usage;;
    *) error ${LINENO} "Unknown option: $1";;
  esac
done

# Conflict check
(( DRY_RUN && YES )) && error ${LINENO} "--dry-run and --yes cannot be combined"

##############################################
generate_sample_config() {
  cat > "${HOME}/.bootstrap_nextjs.conf" <<EOF
# ~/.bootstrap_nextjs.conf

PROJECTS_ROOT="\$HOME/progetti"
BACKUP_ROOT="\$HOME/backup/repos"
PORT_START=3000
RETENTION_DAYS=30
TEMPLATE_REPO="https://github.com/your-org/nextjs-template.git"
TEMPLATE_REF="main"
IMAGE_REGISTRY="ghcr.io/your-org"
BASE_IMAGE="node:18-alpine"
BRANCH="main"
SECRET_PROVIDER="vault"
EOF
  chmod 600 "${HOME}/.bootstrap_nextjs.conf"
  echo_ok "Sample config written to ~/.bootstrap_nextjs.conf"
  exit 0
}
[[ "$GENERATE_CONFIG" == true ]] && generate_sample_config

require_root() { (( EUID == 0 )) || error ${LINENO} "Must run as root."; }
enable_verbose() {
  [[ "$VERBOSE" == true ]] && { export PS4='+ ${BASH_SOURCE##*/}:${LINENO}:${FUNCNAME[0]}: '; set -x; }
}
validate_inputs() {
  [[ "$PROJECT_NAME" =~ ^[a-zA-Z0-9_-]+$ ]] \
    || error ${LINENO} "Invalid project name."
  [[ "$TEMPLATE_REPO" =~ ^https:// ]] \
    || error ${LINENO} "Template repo must start with https://."
  [[ "$PORT_START" =~ ^[0-9]+$ ]] \
    || error ${LINENO} "port-start must be numeric."
  [[ "$RETENTION_DAYS" =~ ^[0-9]+$ ]] \
    || error ${LINENO} "retention-days must be numeric."
  (( PORT_START >= 1024 && PORT_START <= 65535 )) \
    || error ${LINENO} "port-start out of range (1024–65535)."
  case "$VISIBILITY" in public|private) ;; \
    *) error ${LINENO} "visibility must be public or private.";; esac
  case "$SECRET_PROVIDER" in vault|aws|none) ;; \
    *) error ${LINENO} "secret-provider must be vault, aws, or none.";; esac
}

##############################################
detect_os_and_pkg() {
  if command -v apt-get &>/dev/null; then
    OS=debian; PKG_CMD="apt-get install -y --no-install-recommends"
  elif command -v yum &>/dev/null; then
    OS=redhat; PKG_CMD="yum install -y"
  elif command -v brew &>/dev/null; then
    OS=macos; PKG_CMD="brew install"
  else
    error ${LINENO} "Unsupported OS: no apt-get, yum, or brew found."
  fi
  log "Detected OS: $OS"
}

install_packages() {
  local pkgs=(curl git jq gh docker ss gpg tar)
  log "Installing prerequisites: ${pkgs[*]}"
  run_cmd $PKG_CMD "${pkgs[@]}" >>"$LOG_FILE" 2>&1
  if [[ "$OS" != "macos" && "$NO_ENABLE_DOCKER" == false ]]; then
    run_cmd systemctl enable --now docker >>"$LOG_FILE" 2>&1
  fi
}

detect_compose() {
  if docker compose version &>/dev/null; then
    DC="docker compose"
  elif docker-compose version &>/dev/null; then
    DC="docker-compose"
  else
    log "Installing docker-compose"
    local ver url shasum
    ver=$(curl -fsSL https://api.github.com/repos/docker/compose/releases/latest \
      | jq -r '.tag_name')
    url="https://github.com/docker/compose/releases/download/${ver}/docker-compose-$(uname -s)-$(uname -m)"
    shasum=$(curl -fsSL "${url}.sha256" | awk '{print $1}')
    run_cmd curl -fsSL "$url" -o /usr/local/bin/docker-compose
    echo "${shasum}  /usr/local/bin/docker-compose" > compose.sha256
    sha256sum -c compose.sha256 || error ${LINENO} "Compose checksum mismatch."
    chmod +x /usr/local/bin/docker-compose
    rm compose.sha256
    DC="docker-compose"
  fi
  log "Using Compose: $DC"
}

prompt_for_name() {
  [[ -n "$PROJECT_NAME" ]] && return
  if [[ "$YES" == true ]]; then
    error ${LINENO} "Project name is required."
  fi
  read -rp "Project name: " PROJECT_NAME
}
prompt_for_name

validate_inputs
require_root
enable_verbose
init_logging() { : >"$LOG_FILE"; }
init_logging

##############################################
# Locking
generate_lockdir() {
  local safe_name="${PROJECT_NAME//[^a-zA-Z0-9]/_}"
  LOCKDIR=$(mktemp -d "/tmp/bootstrap-nextjs-${safe_name}-lock.XXXXXX")
  exec {LOCK_FD}>"$LOCKDIR/lock"
  flock -n "$LOCK_FD" || error ${LINENO} "Another instance running for '$PROJECT_NAME'."
}
generate_lockdir

##############################################
# Workspace & clone
prepare_workspace() {
  mkdir -p "$PROJECTS_ROOT" "$BACKUP_ROOT"
  DEST="$PROJECTS_ROOT/$PROJECT_NAME"
  [[ -e "$DEST" ]] && error ${LINENO} "Destination '$DEST' exists."
  mkdir -p "$DEST"
  cd "$DEST"
}
prepare_workspace

clone_template() {
  echo_ok "1/15 Cloning template…"
  git ls-remote "$TEMPLATE_REPO" &>/dev/null \
    || error ${LINENO} "Template repo unreachable"
  run_cmd git clone --depth 1 \
    ${TEMPLATE_REF:+--branch "$TEMPLATE_REF"} \
    "$TEMPLATE_REPO" . >>"$LOG_FILE" 2>&1
}
clone_template

##############################################
# Set IMAGE_REGISTRY default
if [[ -z "$IMAGE_REGISTRY" ]]; then
  if [[ "$GIT_PROVIDER" == "github" && command -v gh &>/dev/null ]]; then
    IMAGE_REGISTRY="ghcr.io/$(gh api user --timeout 5 | jq -r .login)"
  else
    IMAGE_REGISTRY="${GIT_PROVIDER}.example.com/${PROJECT_NAME}"
  fi
fi
log "IMAGE_REGISTRY=$IMAGE_REGISTRY"

##############################################
assign_port() {
  echo_ok "2/15 Assigning port…"
  PORT=$PORT_START
  while nc -z -w1 localhost "$PORT" 2>/dev/null; do
    (( PORT++ )); (( PORT>65535 )) && error ${LINENO} "No free port from $PORT_START"
  done
  log "Assigned port: $PORT"
}

generate_dockerfile() {
  echo_ok "3/15 Generating Dockerfile…"
  cat > Dockerfile <<EOF
# builder
FROM ${BASE_IMAGE:-node:18-alpine} AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build

# runtime
FROM ${BASE_IMAGE:-node:18-alpine}
WORKDIR /app
COPY package*.json ./
RUN npm ci --production
COPY --from=builder /app/.next ./.next
COPY --from=builder /app/public ./public
EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=5s \\
  CMD wget --no-verbose --tries=1 --spider http://localhost:${PORT} || exit 1
CMD ["npm","run","start"]
EOF
  log "Dockerfile written"
}

generate_dockerignore() {
  echo_ok "4/15 Generating .dockerignore…"
  cat > .dockerignore <<EOF
node_modules
.git
.env*
.next/cache
Dockerfile
docker-compose.yml
*.log
EOF
  log ".dockerignore written"
}

generate_compose() {
  echo_ok "5/15 Generating docker-compose.yml…"
  cat > docker-compose.yml <<EOF
version: '3.8'
services:
  web:
    build: .
    container_name: "${PROJECT_NAME}_web"
    command: npm run dev
    ports:
      - "${PORT}:3000"
    env_file:
      - .env
EOF
  log "docker-compose.yml written"
}

secret_manager() {
  echo_ok "6/15 Handling secrets…"
  case "$SECRET_PROVIDER" in
    vault)
      if [[ "$SKIP_VAULT" == false && -n "${VAULT_ADDR:-}" ]]; then
        : "${VAULT_ROLE_ID:?VAULT_ROLE_ID required}"
        : "${VAULT_SECRET_ID:?VAULT_SECRET_ID required}"
        local tok
        tok=$(vault write -field=token auth/approle/login \
          role_id="$VAULT_ROLE_ID" secret_id="$VAULT_SECRET_ID")
        vault kv get -format=json "$VAULT_PATH/$PROJECT_NAME" \
          | jq -r '.data.data|to_entries[]|"\(.key)=\(.value)"' >.env
        chmod 600 .env
      else
        echo "# Example .env" >.env.example
      fi ;;
    aws)
      if command -v aws &>/dev/null; then
        aws secretsmanager get-secret-value --secret-id "$PROJECT_NAME" \
          --query SecretString --output text >.env
        chmod 600 .env
      else
        warn "AWS CLI missing; writing example .env"
        echo "# Example .env" >.env.example
      fi ;;
    none)
      echo "# Example .env" >.env.example ;;
  esac
  log "Secrets handled"
}

detect_node() {
  echo_ok "7/15 Detecting Node version…"
  if [[ -f .nvmrc ]]; then
    run_cmd curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
    # shellcheck source=/dev/null
    source "$HOME/.nvm/nvm.sh"
    run_cmd nvm install && nvm use
    BASE_IMAGE="node:$(<.nvmrc)-alpine"
  elif grep -q '"engines"' package.json 2>/dev/null; then
    local ver
    ver=$(jq -r '.engines.node' package.json)
    BASE_IMAGE="node:${ver#>=}-alpine"
  else
    BASE_IMAGE="node:18-alpine"
  fi
  log "Using base image: $BASE_IMAGE"
}

init_git() {
  echo_ok "8/15 Initializing Git…"
  git init >>"$LOG_FILE" 2>&1
  git checkout -b "${BRANCH:-main}" >>"$LOG_FILE" 2>&1 || :
  git add . >>"$LOG_FILE" 2>&1
  git commit -qm "chore: init" >>"$LOG_FILE" 2>&1
}

create_remote() {
  echo_ok "9/15 Creating remote repo…"
  [[ "$SKIP_REMOTE" == true ]] && return
  if [[ "$GIT_PROVIDER" == "github" ]]; then
    command -v gh &>/dev/null || run_cmd $PKG_CMD gh
    if ! gh repo view "$PROJECT_NAME" &>/dev/null; then
      gh auth status &>/dev/null || gh auth login
      gh repo create "$PROJECT_NAME" --"$VISIBILITY" >>"$LOG_FILE"
    else
      log "GitHub repo exists; skipping"
    fi
  elif [[ "$GIT_PROVIDER" == "gitlab" ]]; then
    command -v glab &>/dev/null || run_cmd $PKG_CMD glab
    if ! glab repo view "$PROJECT_NAME" &>/dev/null; then
      glab auth status &>/dev/null || glab auth login
      glab repo create "$PROJECT_NAME" --"$VISIBILITY" >>"$LOG_FILE"
    else
      log "GitLab repo exists; skipping"
    fi
  else
    warn "Unknown GIT_PROVIDER '$GIT_PROVIDER'; skipping remote"
  fi
}

generate_readme() {
  echo_ok "10/15 Generating README.md…"
  cat > README.md <<EOF
# ${PROJECT_NAME}

## Local development

\`\`\`bash
cd ${DEST}
npm install
docker compose up --build
\`\`\`

Open http://localhost:${PORT}
EOF
}

setup_ci() {
  echo_ok "11/15 Setting up CI…"
  mkdir -p .github/workflows
  cat > .github/workflows/ci.yml <<EOF
name: CI
on: [push]

jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - run: |
          shellcheck bootstrap-nextjs.sh
          shfmt -d bootstrap-nextjs.sh

  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - run: npm ci && npm test

  build:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        platform: [linux/amd64,linux/arm64]
    steps:
      - uses: actions/checkout@v3
      - uses: docker/setup-buildx-action@v2
      - uses: docker/login-action@v2
        with:
          registry: ${IMAGE_REGISTRY}
          username: \${{ github.actor }}
          password: \${{ secrets.GITHUB_TOKEN }}
      - name: Build & push
        uses: docker/build-push-action@v4
        with:
          context: .
          push: true
          platforms: \${{ matrix.platform }}
          tags: ${IMAGE_REGISTRY}/${PROJECT_NAME}:\${{ matrix.platform }}
EOF
}

backup_repo() {
  echo_ok "12/15 Backing up repo…"
  [[ "$SKIP_BACKUP" == true ]] && return
  mkdir -p "$BACKUP_ROOT"
  local mirror="$BACKUP_ROOT/${PROJECT_NAME}.git"
  if [[ -d "$mirror" ]]; then
    run_cmd git -C "$mirror" fetch --prune origin >>"$LOG_FILE" 2>&1
  else
    run_cmd git clone --mirror "$(pwd)" "$mirror" >>"$LOG_FILE" 2>&1
  fi
  # prune old mirrors
  find "$BACKUP_ROOT" -maxdepth 1 -type d -name "${PROJECT_NAME}.git" \
    -mtime +"$RETENTION_DAYS" -exec rm -rf {} +
}

start_container() {
  echo_ok "13/15 Starting container…"
  run_cmd $DC up -d --build >>"$LOG_FILE" 2>&1
}

final_summary() {
  echo_ok "14/15 Done!"
  echo_ok "▶ ${PROJECT_NAME} @ http://localhost:${PORT}"
  echo_ok "▶ Clone URL: \$(git config --get remote.origin.url)"
  echo_ok "▶ Logs: $LOG_FILE"
}

##############################################
# Main flow
detect_os_and_pkg
install_packages
detect_compose

clone_template
assign_port
generate_dockerfile
generate_dockerignore
generate_compose
secret_manager
detect_node
init_git
create_remote
generate_readme
setup_ci
backup_repo
start_container
final_summary

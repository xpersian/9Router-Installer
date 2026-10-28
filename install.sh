#!/usr/bin/env bash
set -euo pipefail

# =============================================================
# 9router — Quick VPS Installer (public internet access)
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/xpersian/9Router-Installer/main/install.sh | sudo bash
#   (or download it first and run: sudo bash install.sh)
#
# * First run: prompts for admin password, port and public URL.
#   Prompts are read from /dev/tty (NOT stdin), so the piped
#   one-liner above works: a plain "read" would otherwise swallow
#   the script's own lines when stdin is the curl pipe.
# * Later runs: silent update — reuses the config saved in
#   /opt/9router/.env, regenerates nothing, and skips
#   npm install/build entirely when the source has not changed.
# * Fully non-interactive (optional): pass INITIAL_PASSWORD,
#   PORT and/or BASE_URL as environment variables to skip prompts.
#
# Platform: Ubuntu/Debian, root or sudo required.
#
# NOTE: the upstream repo's "npm start" hardcodes --port 20127,
# so this script starts custom-server.js directly with the chosen
# port instead (default 20128, per 9router docs).
# =============================================================

APP_NAME="9router"
APP_DIR="/opt/9router"
DATA_DIR="/var/lib/9router"
ENV_FILE="$APP_DIR/.env"
ECOSYSTEM_FILE="$APP_DIR/ecosystem.config.js"
MANAGER="/usr/local/bin/9router"
CRON_FILE="/etc/cron.d/9router-update"
UPDATE_LOG="/var/log/9router-update.log"
REPO="https://github.com/decolua/9router.git"
CLOUD_URL="https://9router.com"
INSTALLER_URL="https://raw.githubusercontent.com/xpersian/9Router-Installer/main/install.sh"
DEFAULT_PORT="20128"

# ---------- Colors ----------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[+]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[x]${NC} $1" >&2; exit 1; }

[[ $EUID -eq 0 ]] || error "Please run this script with sudo."

# ---------- Prompt helpers ----------
# stdin may be the script itself (curl ... | bash), so never read
# answers from stdin: always use the controlling terminal instead.
ask() {  # ask <prompt> <default>  -> prints the answer
  local prompt="$1" def="$2" ans=""
  if [[ -r /dev/tty && -w /dev/tty ]]; then
    read -r -p "$prompt" ans </dev/tty || ans=""
  fi
  printf '%s' "${ans:-$def}"
}
ask_secret() {  # ask_secret <prompt>  -> prints the answer (input hidden)
  local prompt="$1" ans=""
  if [[ -r /dev/tty && -w /dev/tty ]]; then
    read -r -s -p "$prompt" ans </dev/tty || ans=""
    echo >&2
  fi
  printf '%s' "$ans"
}
env_get() {  # env_get <key>  -> value saved in $ENV_FILE ("" if missing)
  local key="$1" v=""
  if [[ -f "$ENV_FILE" ]]; then
    v="$(grep -m1 -E "^${key}=" "$ENV_FILE" 2>/dev/null | head -n1 | cut -d= -f2-)" || true
  fi
  v="${v%$'\r'}"       # tolerate CRLF line endings
  case "$v" in        # tolerate values wrapped in quotes, e.g. PORT="20128"
    \"*\") v="${v:1:-1}" ;;
    \'*\') v="${v:1:-1}" ;;
  esac
  printf '%s' "$v"
}
js_escape() {  # make a value safe inside a JS double-quoted string
  local s="$1"
  s="${s//\\/\\\\}"   # escape backslashes first
  s="${s//\"/\\\"}"   # then double quotes
  printf '%s' "$s"
}

RUN_USER="${SUDO_USER:-root}"

# ---------- Gather configuration ----------
MODE="install"
if [[ -f "$ENV_FILE" ]] && grep -q '^PORT=' "$ENV_FILE" 2>/dev/null; then
  MODE="update"
  info "Existing config found in $ENV_FILE — silent update mode (no prompts)."
  PORT="${PORT:-$(env_get PORT)}"
  PORT="${PORT:-$DEFAULT_PORT}"
  BASE_URL="${BASE_URL:-$(env_get NEXT_PUBLIC_BASE_URL)}"
  SAVED_RUN_USER="$(env_get RUN_USER)"
  [[ -z "$SAVED_RUN_USER" ]] || RUN_USER="$SAVED_RUN_USER"
else
  # Fresh install: environment variables win; otherwise prompt on the terminal.
  if [[ -z "${PORT:-}" ]]; then
    PORT="$(ask "Port to listen on (Enter = $DEFAULT_PORT): " "$DEFAULT_PORT")"
  fi
  if [[ -z "${BASE_URL:-}" ]]; then
    PUB_IP="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
    DEFAULT_URL="http://${PUB_IP:-localhost}:$PORT"
    BASE_URL="$(ask "Public URL for NEXT_PUBLIC_BASE_URL (Enter = $DEFAULT_URL): " "$DEFAULT_URL")"
  fi
fi

# Fallback (e.g. updating from an old config that lacks the URL key)
if [[ -z "${BASE_URL:-}" ]]; then
  PUB_IP="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  BASE_URL="http://${PUB_IP:-localhost}:$PORT"
fi

if [[ -z "${INITIAL_PASSWORD:-}" ]]; then
  INITIAL_PASSWORD="$(env_get INITIAL_PASSWORD)"   # reuse saved password on updates
fi
if [[ -z "${INITIAL_PASSWORD:-}" ]]; then
  INITIAL_PASSWORD="$(ask_secret "Initial admin password (input hidden): ")"
fi
[[ -n "${INITIAL_PASSWORD:-}" ]] || error "Password cannot be empty (INITIAL_PASSWORD missing and no terminal available for a prompt)."
[[ "$PORT" =~ ^[0-9]+$ ]] || error "Port must be a number (got: $PORT)."

# ---------- Auto-generate secure secrets (reuse saved ones on update) ----------
command -v openssl >/dev/null || {
  command -v apt-get >/dev/null || error "openssl is required but not installed."
  apt-get update -qq && apt-get install -y -qq openssl
}
gen_secret() {  # gen_secret <key>
  local v
  v="$(env_get "$1")"
  [[ -n "$v" ]] || v="$(openssl rand -hex 32)"
  printf '%s' "$v"
}
JWT_SECRET="$(gen_secret JWT_SECRET)"
API_KEY_SECRET="$(gen_secret API_KEY_SECRET)"
MACHINE_ID_SALT="$(gen_secret MACHINE_ID_SALT)"

# ---------- Node.js >= 20.9 required by Next.js 16; we standardize on 22.x ----------
# Distros often ship Node 18.x, and NodeSource's nodejs bundles npm while
# conflicting with the distro npm package. If the current Node is not recent
# enough, replace the system nodejs/npm with the LATEST Node.js 22.x from
# NodeSource (version resolved fresh at install time).
node_ok() {
  command -v node >/dev/null && command -v npm >/dev/null \
    && (( $(node -p 'Number(process.versions.node.split(".")[0])') >= 22 ))
}

ensure_node22() {
  apt-get update -qq
  warn "Replacing the system nodejs/npm with Node.js 22.x ..."
  apt-get purge -y -qq nodejs npm >/dev/null 2>&1 || true
  apt-get autoremove -y -qq >/dev/null 2>&1 || true
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    || warn "NodeSource setup failed; trying distro packages."
  apt-get install -y -qq nodejs || apt-get install -y -qq nodejs npm
}

if node_ok; then
  info "Node.js $(node -v) + npm $(npm -v) already installed and recent."
else
  info "Installing/upgrading to the latest Node.js 22.x (required by Next.js 16) ..."
  ensure_node22
fi

command -v node >/dev/null || error "Node.js installation failed."
command -v npm  >/dev/null || error "npm installation failed. Please report the output above."
hash -r
NODE_MAJOR="$(node -p 'Number(process.versions.node.split(".")[0])')"
NODE_MINOR="$(node -p 'Number(process.versions.node.split(".")[1])')"
(( NODE_MAJOR > 20 || ( NODE_MAJOR == 20 && NODE_MINOR >= 9 ) )) \
  || error "Node.js >= 20.9 required by Next.js 16 (found: $(node -v))."
info "Node.js: $(node -v) | npm: $(npm -v)"

# ---------- Fetch source ----------
SKIP_BUILD=0
if [[ -d "$APP_DIR/.git" ]]; then
  info "Updating existing install in $APP_DIR ..."
  cd "$APP_DIR"
  OLD_HEAD="$(git rev-parse HEAD 2>/dev/null || true)"
  git pull --ff-only || error "git pull failed — resolve local changes in $APP_DIR and re-run."
  NEW_HEAD="$(git rev-parse HEAD 2>/dev/null || true)"
  if [[ -n "$OLD_HEAD" && "$OLD_HEAD" == "$NEW_HEAD" && -d "$APP_DIR/.next" ]]; then
    SKIP_BUILD=1
    info "Source unchanged since the last build — skipping npm install/build."
  fi
else
  info "Cloning repository ..."
  rm -rf "$APP_DIR"
  git clone "$REPO" "$APP_DIR"
  cd "$APP_DIR"
fi

# ---------- Optional temp swap for low-RAM VPS (the build is memory hungry) ----------
cleanup() {
  if [[ -e /swapfile_temp ]]; then
    swapoff /swapfile_temp >/dev/null 2>&1 || true
    rm -f /swapfile_temp
  fi
}
trap cleanup EXIT

TOTAL_MEM_MB="$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print int($2/1024)}' || true)"
TOTAL_MEM_MB="${TOTAL_MEM_MB:-8192}"
if (( TOTAL_MEM_MB < 2048 )) && command -v fallocate >/dev/null \
  && command -v swapon >/dev/null && command -v mkswap >/dev/null; then
  if ! swapon --show 2>/dev/null | grep -q '/swapfile_temp'; then
    SWAP_MB=$(( TOTAL_MEM_MB < 1024 ? 4096 : 2048 ))
    info "Low RAM (${TOTAL_MEM_MB}MB) detected; creating temporary ${SWAP_MB}MB swap for the build ..."
    fallocate -l "${SWAP_MB}M" /swapfile_temp
    chmod 600 /swapfile_temp
    mkswap /swapfile_temp >/dev/null
    swapon /swapfile_temp
  fi
fi

# ---------- Install & build ----------
if [[ "$SKIP_BUILD" != "1" ]]; then
  info "Installing dependencies (npm install) ..."
  npm install --no-audit --no-fund
  info "Building project (npm run build) ..."
  export MAKEFLAGS="-j1"
  # Raise V8 heap limit: Next.js builds OOM around ~256MB on low-RAM boxes
  export NODE_OPTIONS="--max-old-space-size=2048"
  npm run build
fi

# ---------- Data directory ----------
mkdir -p "$DATA_DIR"
chown -R "$RUN_USER" "$DATA_DIR"

# ---------- Install PM2 ----------
if ! command -v pm2 >/dev/null || ! pm2 -v >/dev/null 2>&1; then
  info "Installing PM2 ..."
  npm install -g pm2
fi

# ---------- Save config to .env (reused verbatim on later updates) ----------
cat > "$ENV_FILE" <<EOF
JWT_SECRET=$JWT_SECRET
INITIAL_PASSWORD=$INITIAL_PASSWORD
DATA_DIR=$DATA_DIR
PORT=$PORT
HOSTNAME=0.0.0.0
NODE_ENV=production
NEXT_PUBLIC_BASE_URL=$BASE_URL
NEXT_PUBLIC_CLOUD_URL=$CLOUD_URL
API_KEY_SECRET=$API_KEY_SECRET
MACHINE_ID_SALT=$MACHINE_ID_SALT
RUN_USER=$RUN_USER
EOF
chmod 600 "$ENV_FILE"
chown "$RUN_USER" "$ENV_FILE"

# ---------- PM2 ecosystem ----------
# IMPORTANT: we launch custom-server.js directly with --port,
# because "npm run start" hardcodes --port 20127.
cat > "$ECOSYSTEM_FILE" <<EOF
module.exports = {
  apps: [{
    name: "$APP_NAME",
    cwd: "$APP_DIR",
    script: "node",
    args: "custom-server.js --port $PORT",
    env: {
      NODE_ENV: "production",
      PORT: "$PORT",
      HOSTNAME: "0.0.0.0",
      DATA_DIR: "$DATA_DIR",
      JWT_SECRET: "$(js_escape "$JWT_SECRET")",
      INITIAL_PASSWORD: "$(js_escape "$INITIAL_PASSWORD")",
      NEXT_PUBLIC_BASE_URL: "$(js_escape "$BASE_URL")",
      NEXT_PUBLIC_CLOUD_URL: "$(js_escape "$CLOUD_URL")",
      API_KEY_SECRET: "$(js_escape "$API_KEY_SECRET")",
      MACHINE_ID_SALT: "$(js_escape "$MACHINE_ID_SALT")",
    },
  }],
};
EOF
chown "$RUN_USER" "$ECOSYSTEM_FILE"

# ---------- Start ----------
info "Starting with PM2 on port $PORT ..."
pm2 delete "$APP_NAME" >/dev/null 2>&1 || true
pm2 start "$ECOSYSTEM_FILE"
pm2 save
RUN_HOME="$(getent passwd "$RUN_USER" 2>/dev/null | cut -d: -f6 || true)"
RUN_HOME="${RUN_HOME:-/root}"
if ! pm2 startup systemd -u "$RUN_USER" --hp "$RUN_HOME" >/dev/null 2>&1; then
  pm2 startup >/dev/null 2>&1 || true
fi

# ---------- 9router management helper (sudo 9router) ----------
cat > "$MANAGER" <<'MANAGER_EOF'
#!/usr/bin/env bash
# 9router management helper — installed by 9Router-Installer
set -euo pipefail
APP_NAME="9router"
INSTALLER_URL="https://raw.githubusercontent.com/xpersian/9Router-Installer/main/install.sh"

[[ $EUID -eq 0 ]] || { echo "Please run this with sudo."; exit 1; }

have_tty() { [[ -r /dev/tty && -w /dev/tty ]]; }

run_update() {
  local tmp
  tmp="$(mktemp /tmp/9router-install.XXXXXX)"
  trap 'rm -f "$tmp"' EXIT
  curl -fsSL "$INSTALLER_URL" -o "$tmp"
  bash "$tmp"
}

do_uninstall() {
  pm2 delete "$APP_NAME" >/dev/null 2>&1 || true
  pm2 save >/dev/null 2>&1 || true
  rm -rf /opt/9router
  rm -f /etc/cron.d/9router-update
  local ans=""
  if have_tty; then
    read -r -p "Also remove the data directory /var/lib/9router? [y/N] " ans </dev/tty || ans=""
  fi
  if [[ "${ans,}" == y* ]]; then
    rm -rf /var/lib/9router
    echo "Removed /var/lib/9router."
  else
    echo "Kept /var/lib/9router (remove manually if you want)."
  fi
  echo "9router uninstalled."
  rm -f /usr/local/bin/9router   # last step: this file is running right now
}

case "${1:-menu}" in
  update)
    run_update ;;
  --no-auto-update)
    rm -f /etc/cron.d/9router-update
    echo "9router daily auto-update disabled." ;;
  uninstall|remove)
    do_uninstall ;;
  menu)
    if ! have_tty; then
      echo "No terminal available. Use: sudo 9router update | uninstall | --no-auto-update"
      exit 1
    fi
    echo "9router management"
    echo "  1) Update now"
    echo "  2) Uninstall"
    echo "  3) Exit"
    choice=""
    read -r -p "Choose [1-3]: " choice </dev/tty || choice=""
    case "$choice" in
      1) run_update ;;
      2) do_uninstall ;;
      *) exit 0 ;;
    esac ;;
  help|-h|--help|*)
    echo "Usage: sudo 9router [update|uninstall|--no-auto-update]"
    echo "Run without arguments for the interactive menu." ;;
esac
MANAGER_EOF
chmod 755 "$MANAGER"
info "Management command installed: sudo 9router (menu: update / uninstall)."

# ---------- Daily auto-update (cron 04:45) ----------
if [[ -d /etc/cron.d ]]; then
  cat > "$CRON_FILE" <<EOF
SHELL=/bin/bash
# 9router daily auto-update — disable with: sudo 9router --no-auto-update
45 4 * * * root curl -fsSL $INSTALLER_URL -o /tmp/.9router-update.sh && bash /tmp/.9router-update.sh >> $UPDATE_LOG 2>&1
EOF
  chmod 644 "$CRON_FILE"
  info "Daily auto-update enabled (04:45) — log: $UPDATE_LOG"
else
  warn "/etc/cron.d not found — skipped the daily auto-update."
fi

# ---------- Firewall: allow access from the internet ----------
if command -v ufw >/dev/null; then
  ufw allow "$PORT"/tcp >/dev/null 2>&1 || true
  info "Port $PORT opened in ufw."
else
  warn "ufw not found; make sure port $PORT is reachable."
fi

# ---------- Verify ----------
sleep 3
if command -v ss >/dev/null && ss -tlnp 2>/dev/null | grep -q ":$PORT "; then
  info "App is listening on 0.0.0.0:$PORT"
else
  warn "Nothing detected on port $PORT yet. Check: pm2 logs $APP_NAME"
fi

echo
echo -e "${GREEN}================ Installation complete ================${NC}"
echo "  Public URL:   $BASE_URL"
echo "  Port:         $PORT (bound on 0.0.0.0)"
echo "  Data dir:     $DATA_DIR"
echo "  Config file:  $ENV_FILE (keep it safe)"
echo "  Auto-update:  daily 04:45 (disable: sudo 9router --no-auto-update)"
echo
echo "IMPORTANT: if this VPS runs behind a cloud firewall"
echo "(AWS/GCP/Hetzner/Oracle security group), also open TCP $PORT there."
echo
echo "Useful commands:"
echo "  pm2 status          # check status"
echo "  pm2 logs $APP_NAME  # view logs"
echo "  pm2 restart $APP_NAME"
echo "  sudo 9router        # management menu"

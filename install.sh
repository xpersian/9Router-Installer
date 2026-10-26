#!/usr/bin/env bash
set -euo pipefail

# =============================================================
# 9router — VPS Installer / Updater (Ubuntu/Debian)
#
# Usage:
#   sudo bash install-9router.sh              interactive menu
#   sudo bash install-9router.sh install       smart run (same button):
#     - no existing install -> asks config and installs
#     - existing install    -> updates silently with saved config
#   sudo bash install-9router.sh uninstall     remove 9router
#   sudo bash install-9router.sh --auto-update   enable daily auto-update
#   sudo bash install-9router.sh --no-auto-update disable auto-update
#
# On install, the script copies itself to /usr/local/sbin/9router,
# so afterwards you can simply run:  sudo 9router
#
# NOTE: the repo's own "npm start" hardcodes --port 20127, so we
# launch custom-server.js directly with the chosen port instead.
# =============================================================

APP_NAME="9router"
APP_DIR="/opt/9router"
DATA_DIR="/var/lib/9router"
REPO="https://github.com/decolua/9router.git"
SCRIPT_URL="https://raw.githubusercontent.com/xpersian/9Router-Installer/main/install.sh"
CLOUD_URL="https://9router.com"
ENV_FILE="$APP_DIR/.env"
ECO_FILE="$APP_DIR/ecosystem.config.js"
SELF_INSTALL_PATH="/usr/local/sbin/9router"
CRON_FILE="/etc/cron.d/9router-update"
UPDATE_LOG="/var/log/9router-update.log"
CRON_TIME="45 4"   # auto-update daily at 04:45

# ---------- Colors ----------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[+]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[x]${NC} $1"; exit 1; }

[[ $EUID -eq 0 ]] || error "Please run this script with sudo."

# ---------- Helpers ----------
get_env() {  # get_env KEY -> value from $ENV_FILE (quotes stripped)
  [[ -f "$ENV_FILE" ]] || return 0
  local v
  v="$(grep -E "^$1=" "$ENV_FILE" | head -1 | cut -d= -f2- || true)"
  v="${v%\"}"; v="${v#\"}"
  printf '%s' "$v"
}

self_install() {  # copy this script to /usr/local/sbin/9router
  local src
  src="$(readlink -f "${BASH_SOURCE[0]:-}" 2>/dev/null || true)"
  if [[ -z "$src" || ! -f "$src" ]] && [[ -n "$SCRIPT_URL" ]]; then
    # Piped one-liner (curl | sudo bash): download ourselves to a stable path
    curl -fsSL "$SCRIPT_URL" -o "$SELF_INSTALL_PATH" && chmod +x "$SELF_INSTALL_PATH"
    return
  fi
  if [[ -n "$src" && "$src" != "$SELF_INSTALL_PATH" ]]; then
    cp "$src" "$SELF_INSTALL_PATH"
    chmod +x "$SELF_INSTALL_PATH"
  fi
}

create_temp_swap() {  # build is memory hungry on small VPSes
  TOTAL_MEM_MB="$(grep MemTotal /proc/meminfo | awk '{print int($2/1024)}')"
  if (( TOTAL_MEM_MB < 2048 )) && ! swapon --show 2>/dev/null | grep -q '/swapfile_temp'; then
    SWAP_MB=$(( TOTAL_MEM_MB < 1024 ? 4096 : 2048 ))
    info "Low RAM (${TOTAL_MEM_MB}MB); creating temporary ${SWAP_MB}MB swap for the build ..."
    fallocate -l "${SWAP_MB}M" /swapfile_temp
    chmod 600 /swapfile_temp
    mkswap /swapfile_temp >/dev/null
    swapon /swapfile_temp
  fi
}

remove_temp_swap() {
  if swapon --show 2>/dev/null | grep -q '/swapfile_temp'; then
    swapoff /swapfile_temp || true
    rm -f /swapfile_temp
    info "Temporary swap removed."
  fi
}

# ---------- Node.js 22.x + npm (always a recent, sufficient version) ----------
# Next.js 16 (used by 9router) requires Node.js >= 20.9. Distros often ship
# much older versions (e.g. 18.19), and NodeSource's nodejs bundles npm while
# conflicting with the distro npm package. Solution: if the current Node is not
# recent enough, purge any existing nodejs/npm pair and install the LATEST
# Node.js 22.x from NodeSource (version resolved fresh at install time).
node_ok() {
  command -v node >/dev/null && command -v npm >/dev/null \
    && (( $(node -p 'Number(process.versions.node.split(".")[0])') >= 22 ))
}

ensure_node22() {
  apt-get update -qq
  apt-get purge -y -qq nodejs npm >/dev/null 2>&1 || true
  apt-get autoremove -y -qq >/dev/null 2>&1 || true
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    || warn "NodeSource setup failed; trying distro packages."
  apt-get install -y -qq nodejs || apt-get install -y -qq nodejs npm
}

ensure_recent_node() {
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
}

ensure_pm2() {
  if ! command -v pm2 >/dev/null || ! pm2 -v >/dev/null 2>&1; then
    info "Installing PM2 ..."
    npm install -g pm2
  fi
}

fetch_source() {
  if [[ -d "$APP_DIR/.git" ]]; then
    info "Updating source in $APP_DIR ..."
    git -C "$APP_DIR" pull --ff-only || warn "git pull failed; building current version."
  else
    info "Cloning repository ..."
    rm -rf "$APP_DIR"
    git clone "$REPO" "$APP_DIR"
  fi
}

build_app() {
  cd "$APP_DIR"
  # IMPORTANT: devDependencies (tailwind/postcss etc.) are required for the
  # build. Make sure NODE_ENV is NOT "production" during install/build.
  unset NODE_ENV
  info "Installing dependencies (npm install) ..."
  npm install --include=dev --no-audit --no-fund
  info "Building project (npm run build) ..."
  export MAKEFLAGS="-j1"
  # Raise V8 heap limit: Next.js builds OOM around ~256MB on low-RAM boxes
  export NODE_OPTIONS="${NODE_OPTIONS:-} --max-old-space-size=2048"
  create_temp_swap
  npm run build
  remove_temp_swap
}

write_env() {
  cat > "$ENV_FILE" <<EOF
JWT_SECRET="$JWT_SECRET"
INITIAL_PASSWORD="$INITIAL_PASSWORD"
DATA_DIR="$DATA_DIR"
PORT="$PORT"
HOSTNAME="0.0.0.0"
NODE_ENV="production"
NEXT_PUBLIC_BASE_URL="$BASE_URL"
NEXT_PUBLIC_CLOUD_URL="$CLOUD_URL"
API_KEY_SECRET="$API_KEY_SECRET"
MACHINE_ID_SALT="$MACHINE_ID_SALT"
EOF
  chmod 600 "$ENV_FILE"
}

write_ecosystem() {
  cat > "$ECO_FILE" <<EOF
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
      JWT_SECRET: "$JWT_SECRET",
      INITIAL_PASSWORD: "$INITIAL_PASSWORD",
      NEXT_PUBLIC_BASE_URL: "$BASE_URL",
      NEXT_PUBLIC_CLOUD_URL: "$CLOUD_URL",
      API_KEY_SECRET: "$API_KEY_SECRET",
      MACHINE_ID_SALT: "$MACHINE_ID_SALT",
    },
  }],
};
EOF
}

start_app() {
  ensure_pm2
  pm2 delete "$APP_NAME" >/dev/null 2>&1 || true
  pm2 start "$ECO_FILE"
  pm2 save
}

verify_port() {
  sleep 3
  if ss -tlnp 2>/dev/null | grep -q ":$PORT "; then
    info "App is listening on 0.0.0.0:$PORT"
  else
    warn "Nothing detected on port $PORT yet. Check: pm2 logs $APP_NAME"
  fi
}

# =============================================================
# INSTALL / UPDATE (one smart flow)
#   - fresh:      ask config, generate secrets, install
#   - existing:   reuse saved .env, update silently (no prompts)
# =============================================================
main_9router() {
  if [[ -f "$ENV_FILE" ]]; then
    info "Existing install found; updating with saved config ..."
    PORT="$(get_env PORT)";      PORT="${PORT:-20128}"
    BASE_URL="$(get_env NEXT_PUBLIC_BASE_URL)"
    JWT_SECRET="$(get_env JWT_SECRET)"
    INITIAL_PASSWORD="$(get_env INITIAL_PASSWORD)"
    API_KEY_SECRET="$(get_env API_KEY_SECRET)"
    MACHINE_ID_SALT="$(get_env MACHINE_ID_SALT)"
    IS_UPDATE=1
  else
    # ---------- Fresh install: user input ----------
    read -rp "Initial admin password (INITIAL_PASSWORD): " INITIAL_PASSWORD < /dev/tty
    [[ -n "$INITIAL_PASSWORD" ]] || error "Password cannot be empty."

    read -rp "Port to listen on (Enter = 20128): " CUSTOM_PORT < /dev/tty
    PORT="${CUSTOM_PORT:-20128}"

    # Auto-detect public IP so the app is reachable from the internet
    PUB_IP="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
    DEFAULT_URL="http://${PUB_IP:-localhost}:$PORT"
    read -rp "Public URL for NEXT_PUBLIC_BASE_URL (Enter = $DEFAULT_URL): " CUSTOM_URL < /dev/tty
    BASE_URL="${CUSTOM_URL:-$DEFAULT_URL}"

    # ---------- Auto-generate secure secrets ----------
    command -v openssl >/dev/null || { apt-get update -qq && apt-get install -y -qq openssl; }
    JWT_SECRET="$(openssl rand -hex 32)"
    API_KEY_SECRET="$(openssl rand -hex 32)"
    MACHINE_ID_SALT="$(openssl rand -hex 32)"
    IS_UPDATE=0
  fi

  ensure_recent_node
  fetch_source
  build_app

  # ---------- Data directory & saved config ----------
  mkdir -p "$DATA_DIR"
  RUN_USER="${SUDO_USER:-root}"
  chown -R "$RUN_USER" "$DATA_DIR"
  write_env
  chown "$RUN_USER" "$ENV_FILE"

  # ---------- Start ----------
  write_ecosystem
  if (( IS_UPDATE )); then
    info "Restarting with PM2 on port $PORT ..."
  else
    info "Starting with PM2 on port $PORT ..."
  fi
  start_app

  # ---------- First-time-only extras ----------
  if (( ! IS_UPDATE )); then
    pm2 startup systemd -u "$RUN_USER" --hp "$(getent passwd "$RUN_USER" | cut -d: -f6)" || pm2 startup
    if command -v ufw >/dev/null; then
      ufw allow "$PORT"/tcp >/dev/null 2>&1 || true
      info "Port $PORT opened in ufw."
    else
      warn "ufw not found; make sure port $PORT is reachable."
    fi
  fi

  self_install
  verify_port

  # ---------- Enable daily auto-update automatically ----------
  enable_autoupdate

  echo
  if (( IS_UPDATE )); then
    echo -e "${GREEN}================ Update complete ================${NC}"
  else
    echo -e "${GREEN}================ Installation complete ================${NC}"
  fi
  echo "  Public URL:   $BASE_URL"
  echo "  Port:         $PORT (bound on 0.0.0.0)"
  echo "  Data dir:     $DATA_DIR"
  echo "  Secrets file: $ENV_FILE (keep it safe)"
  echo "  Auto-update:  daily at $CRON_TIME (log: $UPDATE_LOG)"
  echo
  echo "  Update/upgrade anytime: sudo 9router"
  echo "  Disable auto-update:  sudo 9router --no-auto-update"
  if (( ! IS_UPDATE )); then
    echo
    echo "IMPORTANT: if this VPS runs behind a cloud firewall"
    echo "(AWS/GCP/Hetzner/Oracle security group), also open TCP $PORT there."
  fi
}

# =============================================================
# UNINSTALL
# =============================================================
uninstall_9router() {
  [[ -d "$APP_DIR" || -d "$DATA_DIR" ]] || error "9router does not appear to be installed."

  read -rp "This will STOP and REMOVE 9router. Continue? [y/N]: " CONFIRM < /dev/tty
  [[ "$CONFIRM" == "y" || "$CONFIRM" == "Y" ]] || { info "Cancelled."; exit 0; }

  PORT="$(get_env PORT)"

  info "Stopping app ..."
  command -v pm2 >/dev/null && { pm2 delete "$APP_NAME" >/dev/null 2>&1 || true; pm2 save || true; } || true

  info "Removing app directory ($APP_DIR) ..."
  rm -rf "$APP_DIR"

  read -rp "Also DELETE all 9router data in $DATA_DIR? [y/N]: " DELDATA < /dev/tty
  if [[ "$DELDATA" == "y" || "$DELDATA" == "Y" ]]; then
    rm -rf "$DATA_DIR"
    info "Data directory removed."
  else
    info "Data directory kept at $DATA_DIR"
  fi

  # Close firewall port if we opened it
  if command -v ufw >/dev/null && [[ -n "$PORT" ]]; then
    ufw delete allow "$PORT"/tcp >/dev/null 2>&1 || true
  fi

  # Remove auto-update cron + installed copy of this script
  rm -f "$CRON_FILE"
  rm -f "$SELF_INSTALL_PATH"
  rm -f "$UPDATE_LOG"

  echo
  info "9router uninstalled."
}

# =============================================================
# AUTO-UPDATE (daily cron)
# =============================================================
enable_autoupdate() {
  self_install
  cat > "$CRON_FILE" <<EOF
# 9router daily auto-update (edit time here if needed)
$CRON_TIME * * * root $SELF_INSTALL_PATH update >> $UPDATE_LOG 2>&1
EOF
  chmod 644 "$CRON_FILE"
  info "Daily auto-update enabled ($CRON_TIME), log: $UPDATE_LOG"
}

disable_autoupdate() {
  if [[ -f "$CRON_FILE" ]]; then
    rm -f "$CRON_FILE"
    info "Auto-update disabled."
  else
    info "Auto-update was not enabled."
  fi
}

# =============================================================
# MODE SELECTION
# =============================================================
if [[ -z "${1:-}" ]]; then
  # Menu is shown whenever we have a terminal (works with the piped
  # one-liner too: stdin is the script, so we read the choice from /dev/tty)
  if [[ -t 1 ]] && exec 3<>/dev/tty 2>/dev/null; then
    echo "=== 9router Manager ==="
    echo "  1) Install / Update (smart)"
    echo "  2) Uninstall"
    read -rp "Select [1-2]: " CHOICE < /dev/tty
    case "$CHOICE" in
      1) MODE="main" ;;
      2) MODE="uninstall" ;;
      *) error "Invalid choice." ;;
    esac
  else
    MODE="main"
  fi
else
  case "$1" in
    install|-i|--install)            MODE="main" ;;
    update|-u|--update)             MODE="main" ;;
    uninstall|remove|-r|--remove)   MODE="uninstall" ;;
    --auto-update)                  MODE="autoupdate" ;;
    --no-auto-update)               MODE="noautoupdate" ;;
    *) error "Unknown option: $1 (use: install | update | uninstall | --auto-update | --no-auto-update)" ;;
  esac
fi

case "$MODE" in
  main)         main_9router ;;
  uninstall)    uninstall_9router ;;
  autoupdate)   enable_autoupdate ;;
  noautoupdate) disable_autoupdate ;;
esac

#!/usr/bin/env bash
set -euo pipefail

# =============================================================
# 9router — Quick VPS Installer (public internet access)
# Usage:    sudo bash install-9router.sh
# Platform: Ubuntu/Debian, root or sudo required
#
# NOTE: the repo's own "npm start" hardcodes --port 20127,
# so this script starts custom-server.js directly with the
# chosen port instead (default 20128, per 9router docs).
# =============================================================

APP_NAME="9router"
APP_DIR="/opt/9router"
DATA_DIR="/var/lib/9router"
REPO="https://github.com/decolua/9router.git"
CLOUD_URL="https://9router.com"

# ---------- Colors ----------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[+]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[x]${NC} $1"; exit 1; }

[[ $EUID -eq 0 ]] || error "Please run this script with sudo."

# ---------- User input ----------
read -rp "Initial admin password (INITIAL_PASSWORD): " INITIAL_PASSWORD
[[ -n "$INITIAL_PASSWORD" ]] || error "Password cannot be empty."

read -rp "Port to listen on (Enter = 20128): " CUSTOM_PORT
PORT="${CUSTOM_PORT:-20128}"

# Auto-detect public IP so the app is reachable from the internet
PUB_IP="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
DEFAULT_URL="http://${PUB_IP:-localhost}:$PORT"
read -rp "Public URL for NEXT_PUBLIC_BASE_URL (Enter = $DEFAULT_URL): " CUSTOM_URL
BASE_URL="${CUSTOM_URL:-$DEFAULT_URL}"

# ---------- Auto-generate secure secrets ----------
command -v openssl >/dev/null || { apt-get update -qq && apt-get install -y -qq openssl; }
JWT_SECRET="$(openssl rand -hex 32)"
API_KEY_SECRET="$(openssl rand -hex 32)"
MACHINE_ID_SALT="$(openssl rand -hex 32)"

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
if [[ -d "$APP_DIR/.git" ]]; then
  info "Updating existing install in $APP_DIR ..."
  cd "$APP_DIR" && git pull --ff-only
else
  info "Cloning repository ..."
  rm -rf "$APP_DIR"
  git clone "$REPO" "$APP_DIR"
  cd "$APP_DIR"
fi

# ---------- Optional temp swap for low-RAM VPS (build is memory hungry) ----------
TOTAL_MEM_MB="$(grep MemTotal /proc/meminfo | awk '{print int($2/1024)}')"
if (( TOTAL_MEM_MB < 2048 )); then
  if ! swapon --show 2>/dev/null | grep -q '/swapfile_temp'; then
    SWAP_MB=$(( TOTAL_MEM_MB < 1024 ? 4096 : 2048 ))
    info "Low RAM (${TOTAL_MEM_MB}MB) detected; creating temporary ${SWAP_MB}MB swap for the build ..."
    fallocate -l "${SWAP_MB}M" /swapfile_temp
    chmod 600 /swapfile_temp
    mkswap /swapfile_temp >/dev/null
    swapon /swapfile_temp
  fi
  TEMP_SWAP=1
fi

# ---------- Install & build ----------
info "Installing dependencies (npm install) ..."
npm install --no-audit --no-fund
info "Building project (npm run build) ..."
export MAKEFLAGS="-j1"
# Raise V8 heap limit: Next.js builds OOM around ~256MB on low-RAM boxes
export NODE_OPTIONS="--max-old-space-size=2048"
npm run build

# Remove temp swap after build
if [[ "${TEMP_SWAP:-0}" == "1" ]]; then
  swapoff /swapfile_temp && rm -f /swapfile_temp
  info "Temporary swap removed."
fi

# ---------- Data directory ----------
mkdir -p "$DATA_DIR"
RUN_USER="${SUDO_USER:-root}"
chown -R "$RUN_USER" "$DATA_DIR"

# ---------- Install PM2 ----------
if ! command -v pm2 >/dev/null || ! pm2 -v >/dev/null 2>&1; then
  info "Installing PM2 ..."
  npm install -g pm2
fi

# ---------- Save env vars to .env (reference & manual runs) ----------
cat > "$APP_DIR/.env" <<EOF
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
EOF
chmod 600 "$APP_DIR/.env"
chown "$RUN_USER" "$APP_DIR/.env"

# ---------- PM2 ecosystem ----------
# IMPORTANT: we launch custom-server.js directly with --port,
# because "npm run start" hardcodes --port 20127.
cat > "$APP_DIR/ecosystem.config.js" <<EOF
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

# ---------- Start ----------
info "Starting with PM2 on port $PORT ..."
pm2 delete "$APP_NAME" >/dev/null 2>&1 || true
pm2 start "$APP_DIR/ecosystem.config.js"
pm2 save
pm2 startup systemd -u "$RUN_USER" --hp "$(getent passwd "$RUN_USER" | cut -d: -f6)" || pm2 startup

# ---------- Firewall: allow access from the internet ----------
if command -v ufw >/dev/null; then
  ufw allow "$PORT"/tcp >/dev/null 2>&1 || true
  info "Port $PORT opened in ufw."
else
  warn "ufw not found; make sure port $PORT is reachable."
fi

# ---------- Verify ----------
sleep 3
if ss -tlnp 2>/dev/null | grep -q ":$PORT "; then
  info "App is listening on 0.0.0.0:$PORT"
else
  warn "Nothing detected on port $PORT yet. Check: pm2 logs $APP_NAME"
fi

echo
echo -e "${GREEN}================ Installation complete ================${NC}"
echo "  Public URL:   $BASE_URL"
echo "  Port:         $PORT (bound on 0.0.0.0)"
echo "  Data dir:     $DATA_DIR"
echo "  Secrets file: $APP_DIR/.env (keep it safe)"
echo
echo "IMPORTANT: if this VPS runs behind a cloud firewall"
echo "(AWS/GCP/Hetzner/Oracle security group), also open TCP $PORT there."
echo
echo "Useful commands:"
echo "  pm2 status          # check status"
echo "  pm2 logs $APP_NAME  # view logs"
echo "  pm2 restart $APP_NAME"

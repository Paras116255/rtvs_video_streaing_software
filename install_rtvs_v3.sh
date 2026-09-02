#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# RTVS v3 - Automated Installation Script
# Usage:
#   chmod +x install_rtvs.sh
#   sudo ./install_rtvs.sh
#
# This script:
#   - installs required OS packages
#   - installs Docker Engine and Docker Compose plugin
#   - extracts RTVS_files
#   - asks for the new RTVS domain
#   - replaces the old RTVS domain in configuration
#   - creates/verifies cvnetwork
#   - configures Nginx -> RTVS port 6001
#   - starts the complete RTVS stack
#   - verifies critical containers and network
#
# It intentionally does NOT automatically open broad firewall ranges.
# ============================================================

readonly SCRIPT_VERSION="3.0"
readonly RTVS_NETWORK="cvnetwork"
readonly RTVS_SUBNET="172.29.108.0/24"
readonly RTVS_HTTP_PORT="6001"
readonly RTVS_HTTP_MAP_PORT="30888"

log()  { printf '\n[%s] %s\n' "$(date '+%F %T')" "$*"; }
ok()   { printf '  OK: %s\n' "$*"; }
warn() { printf '  WARNING: %s\n' "$*" >&2; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

trap 'die "Installation failed at line $LINENO. Check the output above."' ERR

[[ $EUID -eq 0 ]] || die "Run this installer with sudo."

TARGET_USER="${SUDO_USER:-}"
if [[ -z "$TARGET_USER" || "$TARGET_USER" == "root" ]]; then
    TARGET_USER="$(logname 2>/dev/null || true)"
fi
[[ -n "$TARGET_USER" ]] || TARGET_USER="root"

TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[[ -n "$TARGET_HOME" && -d "$TARGET_HOME" ]] || die "Could not determine home directory for $TARGET_USER."

INSTALL_ROOT="$TARGET_HOME"
PACKAGE_ZIP="$INSTALL_ROOT/RTVS_files.zip"
RTVS_ROOT="$INSTALL_ROOT/RTVS_files"
SCRIPT_DIR="$RTVS_ROOT/RTVS/script"
STATE_DIR="/etc/rtvs-installer"
DOMAIN_STATE="$STATE_DIR/domain"
NGINX_CONF="/etc/nginx/conf.d/rtvs.conf"

command_exists() { command -v "$1" >/dev/null 2>&1; }

run_as_user() {
    if [[ "$TARGET_USER" == "root" ]]; then
        "$@"
    else
        sudo -u "$TARGET_USER" "$@"
    fi
}

# ------------------------------------------------------------
# 1. OS
# ------------------------------------------------------------
log "[1/9] Detecting operating system"

if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
else
    die "/etc/os-release not found."
fi

case "${ID:-}" in
    ubuntu|debian)
        ok "$PRETTY_NAME"
        ;;
    *)
        warn "Detected ${PRETTY_NAME:-unknown}. This installer is tested primarily on Ubuntu/Debian."
        ;;
esac

ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"
case "$ARCH" in
    amd64|x86_64) COMPOSE_ARCH="x86_64" ;;
    arm64|aarch64) COMPOSE_ARCH="aarch64" ;;
    armhf|armv7l) COMPOSE_ARCH="armv7" ;;
    *) die "Unsupported architecture: $ARCH" ;;
esac

# ------------------------------------------------------------
# 2. Packages
# ------------------------------------------------------------
log "[2/9] Installing required packages"

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y \
    ca-certificates \
    curl \
    wget \
    unzip \
    gnupg \
    lsb-release \
    apt-transport-https \
    software-properties-common \
    jq \
    nginx

ok "Required packages installed."

# ------------------------------------------------------------
# 3. Docker + Compose
# ------------------------------------------------------------
log "[3/9] Installing/verifying Docker and Docker Compose"

if ! command_exists docker; then
    log "Docker not found. Installing Docker Engine."
    curl -fsSL https://get.docker.com | sh
fi

systemctl enable --now docker

docker --version
ok "Docker is available."

if docker compose version >/dev/null 2>&1; then
    ok "Docker Compose plugin is already available."
else
    log "Docker Compose plugin not found. Installing official Compose binary."

    COMPOSE_DIR="/usr/local/lib/docker/cli-plugins"
    mkdir -p "$COMPOSE_DIR"

    curl -fL \
        "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-${COMPOSE_ARCH}" \
        -o "$COMPOSE_DIR/docker-compose"

    chmod +x "$COMPOSE_DIR/docker-compose"

    docker compose version >/dev/null 2>&1 \
        || die "Docker Compose installation failed."

    ok "Docker Compose installed."
fi

# Add deployment user to docker group. This takes effect after a new login.
if [[ "$TARGET_USER" != "root" ]]; then
    groupadd -f docker
    usermod -aG docker "$TARGET_USER"
    ok "$TARGET_USER added to docker group."
fi

# ------------------------------------------------------------
# 4. RTVS package
# ------------------------------------------------------------
log "[4/9] Preparing RTVS package"

if [[ -f "$PACKAGE_ZIP" ]]; then
    ZIP_TO_USE="$PACKAGE_ZIP"
elif [[ -f "$(pwd)/RTVS_files.zip" ]]; then
    ZIP_TO_USE="$(pwd)/RTVS_files.zip"
else
    die "RTVS_files.zip not found. Put it in $INSTALL_ROOT or run this script from the directory containing it."
fi

# If an existing complete installation exists, reuse it.
if [[ -f "$SCRIPT_DIR/run_all.sh" ]]; then
    ok "Existing RTVS installation detected: $SCRIPT_DIR"
else
    if [[ -d "$RTVS_ROOT" ]]; then
        BACKUP_DIR="${RTVS_ROOT}.backup.$(date +%Y%m%d_%H%M%S)"
        mv "$RTVS_ROOT" "$BACKUP_DIR"
        warn "Existing incomplete RTVS directory moved to $BACKUP_DIR."
    fi

    mkdir -p "$INSTALL_ROOT"
    unzip -q "$ZIP_TO_USE" -d "$INSTALL_ROOT"

    # Support both:
    #   RTVS_files/RTVS/script/run_all.sh
    # and a ZIP containing RTVS/script directly.
    if [[ ! -f "$SCRIPT_DIR/run_all.sh" && -f "$INSTALL_ROOT/RTVS/script/run_all.sh" ]]; then
        mkdir -p "$RTVS_ROOT"
        if [[ -d "$INSTALL_ROOT/RTVS" ]]; then
            mv "$INSTALL_ROOT/RTVS" "$RTVS_ROOT/"
        fi
    fi

    [[ -f "$SCRIPT_DIR/run_all.sh" ]] \
        || die "RTVS package extracted, but RTVS/script/run_all.sh was not found."

    ok "RTVS package extracted."
fi

chmod +x "$SCRIPT_DIR"/*.sh 2>/dev/null || true
chown -R "$TARGET_USER":"$(id -gn "$TARGET_USER")" "$RTVS_ROOT" 2>/dev/null || true

# ------------------------------------------------------------
# 5. Domain replacement
# ------------------------------------------------------------
log "[5/9] Configuring RTVS domain"

read -r -p "Enter the new RTVS domain (example: streaming.example.com): " NEW_DOMAIN

NEW_DOMAIN="${NEW_DOMAIN#http://}"
NEW_DOMAIN="${NEW_DOMAIN#https://}"
NEW_DOMAIN="${NEW_DOMAIN%%/*}"
NEW_DOMAIN="${NEW_DOMAIN%%:*}"

[[ -n "$NEW_DOMAIN" ]] || die "Domain cannot be empty."
[[ "$NEW_DOMAIN" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] \
    || die "Invalid domain name: $NEW_DOMAIN"

mkdir -p "$STATE_DIR"

OLD_DOMAIN=""
if [[ -f "$DOMAIN_STATE" ]]; then
    OLD_DOMAIN="$(head -n1 "$DOMAIN_STATE" || true)"
fi

if [[ -z "$OLD_DOMAIN" ]]; then
    OLD_DOMAIN="$(grep -hE '^[[:space:]]*(export[[:space:]]+)?IPADDRESS=' "$SCRIPT_DIR/run_all.sh" 2>/dev/null \
        | head -n1 \
        | sed -E 's/.*IPADDRESS=//; s/[[:space:]]*#.*$//' \
        | tr -d '"' \
        | tr -d "'" || true)"
fi

# The known baseline domain is also replaced if present.
DOMAINS_TO_REPLACE=()
[[ -n "$OLD_DOMAIN" ]] && DOMAINS_TO_REPLACE+=("$OLD_DOMAIN")
DOMAINS_TO_REPLACE+=("streaming.wfm.om")

# Replace domain only in text configuration/scripts.
# Do not touch .git metadata or certificate/private-key material.
for old in "${DOMAINS_TO_REPLACE[@]}"; do
    [[ "$old" == "$NEW_DOMAIN" ]] && continue

    find "$SCRIPT_DIR" \
        -type f \
        ! -path '*/.git/*' \
        ! -name '*.pem' \
        ! -name '*.key' \
        -print0 |
    while IFS= read -r -d '' file; do
        if grep -Iq . "$file" 2>/dev/null; then
            sed -i "s|${old}|${NEW_DOMAIN}|g" "$file"
        fi
    done
done

# Explicitly set IPADDRESS in run_all.sh.
if grep -qE '^[[:space:]]*export[[:space:]]+IPADDRESS=' "$SCRIPT_DIR/run_all.sh"; then
    sed -i -E "s|^[[:space:]]*export[[:space:]]+IPADDRESS=.*$|export IPADDRESS=${NEW_DOMAIN}|" \
        "$SCRIPT_DIR/run_all.sh"
else
    printf '\nexport IPADDRESS=%s\n' "$NEW_DOMAIN" >> "$SCRIPT_DIR/run_all.sh"
fi

# Update HTTPS wrapper if present.
if [[ -f "$SCRIPT_DIR/run_all_https.sh" ]]; then
    sed -i -E "s|^[[:space:]]*export[[:space:]]+BeianAddress=.*$|export BeianAddress=${NEW_DOMAIN}|" \
        "$SCRIPT_DIR/run_all_https.sh" || true

    sed -i -E "s|/etc/letsencrypt/live/[^/]+/fullchain\\.pem|/etc/letsencrypt/live/${NEW_DOMAIN}/fullchain.pem|g" \
        "$SCRIPT_DIR/run_all_https.sh" || true

    sed -i -E "s|/etc/letsencrypt/live/[^/]+/privkey\\.pem|/etc/letsencrypt/live/${NEW_DOMAIN}/privkey.pem|g" \
        "$SCRIPT_DIR/run_all_https.sh" || true
fi

printf '%s\n' "$NEW_DOMAIN" > "$DOMAIN_STATE"
chmod 0644 "$DOMAIN_STATE"

# Fail if the active run_all configuration still points to the old domain.
if grep -nE '^[[:space:]]*export[[:space:]]+IPADDRESS=' "$SCRIPT_DIR/run_all.sh" | grep -v "$NEW_DOMAIN" >/dev/null 2>&1; then
    die "run_all.sh still contains an unexpected IPADDRESS value."
fi

ok "RTVS domain configured as $NEW_DOMAIN."

# ------------------------------------------------------------
# 6. Nginx
# ------------------------------------------------------------
log "[6/9] Configuring Nginx"

mkdir -p /var/www/certbot

cat > "$NGINX_CONF" <<EOF
server {
    listen 80;
    server_name ${NEW_DOMAIN};

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        proxy_pass http://127.0.0.1:${RTVS_HTTP_PORT};

        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";

        client_max_body_size 2G;
        proxy_request_buffering off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
EOF

# Remove an older generated RTVS config if it is not the current config.
for old_conf in /etc/nginx/conf.d/streaming.wfm.om.conf; do
    if [[ -f "$old_conf" && "$old_conf" != "$NGINX_CONF" ]]; then
        rm -f "$old_conf"
    fi
done

nginx -t
systemctl enable --now nginx
systemctl reload nginx

ok "Nginx configured for $NEW_DOMAIN -> 127.0.0.1:${RTVS_HTTP_PORT}."

# ------------------------------------------------------------
# 7. Docker network
# ------------------------------------------------------------
log "[7/9] Creating/verifying Docker network"

if docker network inspect "$RTVS_NETWORK" >/dev/null 2>&1; then
    EXISTING_SUBNET="$(
        docker network inspect "$RTVS_NETWORK" \
            --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' \
            | head -n1
    )"

    if [[ "$EXISTING_SUBNET" != "$RTVS_SUBNET" ]]; then
        die "Docker network $RTVS_NETWORK already exists with subnet '$EXISTING_SUBNET', expected '$RTVS_SUBNET'. Refusing to alter it automatically."
    fi

    ok "Docker network $RTVS_NETWORK already exists with correct subnet."
else
    docker network create \
        --driver bridge \
        --subnet "$RTVS_SUBNET" \
        "$RTVS_NETWORK"

    ok "Docker network $RTVS_NETWORK created."
fi

docker network inspect "$RTVS_NETWORK" >/dev/null 2>&1 \
    || die "Docker network verification failed."

# ------------------------------------------------------------
# 8. Start RTVS
# ------------------------------------------------------------
log "[8/9] Starting complete RTVS stack"

cd "$SCRIPT_DIR"

# RTVS scripts create /etc/service and manage Docker containers,
# so the deployment itself is intentionally started as root.
bash ./run_all.sh

ok "RTVS startup script completed."

# ------------------------------------------------------------
# 9. Verification
# ------------------------------------------------------------
log "[9/9] Verifying RTVS deployment"

REQUIRED_CONTAINERS=(
    "cvcluster-1"
    "gbsip-1"
    "tstgw808-1"
    "attachment-1"
    "sfu-mediasoup"
    "rtvsweb-publish-1"
    "nginx-rtmp-1"
)

log "Waiting for required containers to become running..."

MAX_WAIT=90
WAITED=0

while (( WAITED < MAX_WAIT )); do
    ALL_RUNNING=1

    for container in "${REQUIRED_CONTAINERS[@]}"; do
        if ! docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null | grep -qx true; then
            ALL_RUNNING=0
            break
        fi
    done

    (( ALL_RUNNING == 1 )) && break

    sleep 5
    WAITED=$((WAITED + 5))
done

FAILED=0

for container in "${REQUIRED_CONTAINERS[@]}"; do
    if docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null | grep -qx true; then
        ok "$container is running."
    else
        printf '  FAILED: %s is not running.\n' "$container"
        FAILED=1
    fi
done

# Network verification.
if docker network inspect "$RTVS_NETWORK" >/dev/null 2>&1; then
    ok "Docker network $RTVS_NETWORK exists."
else
    warn "Docker network $RTVS_NETWORK is missing."
    FAILED=1
fi

# Verify the primary RTVS HTTP port is published/listening.
if ss -lnt 2>/dev/null | awk '{print $4}' | grep -Eq '(^|:)6001$'; then
    ok "RTVS port 6001 is listening."
else
    warn "RTVS port 6001 is not listening."
    FAILED=1
fi

# Verify Nginx configuration.
if nginx -t >/dev/null 2>&1; then
    ok "Nginx configuration is valid."
else
    warn "Nginx configuration test failed."
    FAILED=1
fi

# Verify Nginx can reach the local RTVS endpoint.
HTTP_CODE="$(
    curl -sS \
        -o /dev/null \
        -w '%{http_code}' \
        --max-time 10 \
        -H "Host: ${NEW_DOMAIN}" \
        "http://127.0.0.1/" 2>/dev/null || true
)"

if [[ "$HTTP_CODE" =~ ^[234][0-9][0-9]$ ]]; then
    ok "Nginx -> RTVS HTTP check returned $HTTP_CODE."
elif [[ "$HTTP_CODE" =~ ^4[0-9][0-9]$ ]]; then
    ok "Nginx -> RTVS proxy is reachable (HTTP $HTTP_CODE)."
else
    warn "Nginx -> RTVS HTTP check returned '${HTTP_CODE:-no response}'."
    FAILED=1
fi

# Ensure old baseline domain is not still active in run_all.sh.
if grep -n "streaming.wfm.om" "$SCRIPT_DIR/run_all.sh" >/dev/null 2>&1; then
    warn "Old domain streaming.wfm.om still appears in run_all.sh."
    FAILED=1
else
    ok "run_all.sh contains no active streaming.wfm.om reference."
fi

printf '\n'
printf '%s\n' '============================================================'
printf '%s\n' '                 RTVS INSTALLATION RESULT'
printf '%s\n' '============================================================'
printf 'Version          : %s\n' "$SCRIPT_VERSION"
printf 'Domain           : %s\n' "$NEW_DOMAIN"
printf 'RTVS directory   : %s\n' "$RTVS_ROOT"
printf 'Docker network   : %s (%s)\n' "$RTVS_NETWORK" "$RTVS_SUBNET"
printf 'Nginx config     : %s\n' "$NGINX_CONF"
printf 'RTVS HTTP port   : %s\n' "$RTVS_HTTP_PORT"
printf 'HTTP map port    : %s\n' "$RTVS_HTTP_MAP_PORT"
printf '============================================================\n'

if (( FAILED != 0 )); then
    printf '\nRTVS INSTALLATION FAILED VERIFICATION.\n'
    printf 'Run the following commands for diagnostics:\n\n'
    printf '  sudo docker ps -a\n'
    printf '  sudo docker network inspect %s\n' "$RTVS_NETWORK"
    printf '  sudo docker logs --tail 100 rtvsweb-publish-1\n'
    printf '  sudo nginx -t\n'
    exit 1
fi

printf '\nRTVS INSTALLATION COMPLETED SUCCESSFULLY.\n'
printf 'Domain: http://%s/\n' "$NEW_DOMAIN"

if [[ "$TARGET_USER" != "root" ]]; then
    printf '\nDocker group membership was added for %s.\n' "$TARGET_USER"
    printf 'Log out and log back in before using docker without sudo.\n'
fi

printf '\nFirewall/security-group ports were NOT automatically opened.\n'
printf 'Configure only the externally required RTVS ports in your infrastructure firewall.\n'

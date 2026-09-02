#!/usr/bin/env bash
set -euo pipefail

GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
log(){ echo -e "${GREEN}$1${NC}"; }
err(){ echo -e "${RED}$1${NC}"; exit 1; }

if [[ $EUID -ne 0 ]]; then
  err "Run with sudo."
fi

# ---- OS detection ----
source /etc/os-release
OS=${ID}
if [[ "$OS" =~ (ubuntu|debian) ]]; then
  PM=apt
elif [[ "$OS" =~ (centos|rhel|rocky|almalinux|fedora) ]]; then
  PM=dnf
else
  err "Unsupported OS: $OS"
fi

log "[1/9] Installing required packages"

if [[ "$PM" == "apt" ]]; then
  apt update
  apt install -y curl unzip nginx git ca-certificates gnupg lsb-release jq
else
  dnf install -y curl unzip nginx git ca-certificates jq
fi

# ---- Docker ----
log "[2/9] Installing / Verifying Docker"

if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sh
fi

systemctl enable docker
systemctl start docker

# ---- Docker Compose ----
log "[3/9] Installing / Verifying Docker Compose"

if ! docker compose version >/dev/null 2>&1; then
  mkdir -p /usr/local/lib/docker/cli-plugins
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64) ARCH=linux-x86_64 ;;
    aarch64|arm64) ARCH=linux-aarch64 ;;
    *) err "Unsupported architecture: $ARCH" ;;
  esac

  curl -SL \
    "https://github.com/docker/compose/releases/latest/download/docker-compose-${ARCH}" \
    -o /usr/local/lib/docker/cli-plugins/docker-compose

  chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
fi

docker compose version >/dev/null 2>&1 || err "Docker Compose installation failed."

# ---- Extract RTVS ----
log "[4/9] Extracting RTVS package"

TARGET_HOME=$(eval echo "~${SUDO_USER:-$USER}")
cd "$TARGET_HOME/rtvs_video_streaing_software"

rm -rf "$TARGET_HOME/RTVS_files"
unzip -q RTVS_files.zip -d "$TARGET_HOME"

SCRIPT_DIR="$TARGET_HOME/RTVS_files/RTVS/script"
[[ -d "$SCRIPT_DIR" ]] || err "RTVS script directory not found."

chmod +x "$SCRIPT_DIR"/*.sh

# ---- Domain ----
log "[5/9] Configure RTVS Domain"

read -rp "Enter RTVS Domain (example: streaming.example.com): " DOMAIN
[[ -n "$DOMAIN" ]] || err "Domain cannot be empty."

OLD_DOMAIN="streaming.wfm.om"

find "$SCRIPT_DIR" -type f \
  \( -name "*.sh" -o -name "*.tmp" -o -name "*.js" -o -name "*.xml" \) \
  -exec sed -i "s/${OLD_DOMAIN}/${DOMAIN}/g" {} +

sed -i "s#export IPADDRESS=.*#export IPADDRESS=${DOMAIN}#" "$SCRIPT_DIR/run_all.sh"

sed -i "s#export BeianAddress=.*#export BeianAddress=${DOMAIN}#" "$SCRIPT_DIR/run_all_https.sh"
sed -i "s#/etc/letsencrypt/live/.*#/etc/letsencrypt/live/${DOMAIN}/fullchain.pem#" "$SCRIPT_DIR/run_all_https.sh"
sed -i "s#/etc/letsencrypt/live/.*/privkey.pem#/etc/letsencrypt/live/${DOMAIN}/privkey.pem#" "$SCRIPT_DIR/run_all_https.sh"

# ---- Nginx ----
log "[6/9] Creating Nginx configuration"

cat >/etc/nginx/conf.d/${DOMAIN}.conf <<EOF
server {
    listen 80;
    server_name ${DOMAIN};

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        proxy_pass http://127.0.0.1:6001;
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

nginx -t
systemctl enable nginx
systemctl restart nginx

# ---- Firewall ----
log "[7/9] Firewall ports"

PORTS="80 443 6001 6003 6004 6005 6006 6007 6008 6010 6011 6012 6013 6015 6016 6017 6018 6019 6020 6021 6022 6024 6025 6028 6029 6030 6031 6032 6033 6034 6035 6036 17000 30888 30443 5060 9080 9081 9082 9300"

if command -v ufw >/dev/null 2>&1; then
  for p in $PORTS; do ufw allow $p/tcp || true; done
  ufw allow 5060/udp || true
  ufw allow 14003:14200/udp || true
fi

if command -v firewall-cmd >/dev/null 2>&1; then
  for p in $PORTS; do firewall-cmd --permanent --add-port=${p}/tcp || true; done
  firewall-cmd --permanent --add-port=5060/udp || true
  firewall-cmd --permanent --add-port=14003-14200/udp || true
  firewall-cmd --reload || true
fi

# ---- RTVS ----
log "[8/9] Starting RTVS"

cd "$SCRIPT_DIR"
./run_all.sh

log "[9/9] Deployment Summary"

docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

echo
log "RTVS deployed successfully."
echo "Domain : $DOMAIN"
echo "RTVS   : $SCRIPT_DIR"
echo "Nginx  : /etc/nginx/conf.d/${DOMAIN}.conf"
echo
echo "Next:"
echo "1. Point DNS of $DOMAIN to this server."
echo "2. Generate SSL:"
echo "   sudo certbot --nginx -d $DOMAIN"

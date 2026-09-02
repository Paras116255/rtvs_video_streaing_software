#!/usr/bin/env bash
set -Eeuo pipefail

# RTVS new-server bootstrap installer
# Usage:
#   chmod +x install_rtvs.sh
#   sudo ./install_rtvs.sh
#
# Optional:
#   RTVS_ZIP=/path/to/RTVS_files.zip sudo ./install_rtvs.sh

BASE_DOMAIN="streaming.wfm.om"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ZIP_FILE="${RTVS_ZIP:-$SCRIPT_DIR/RTVS_files.zip}"

log()  { printf '\n[%s] %s\n' "$1" "$2"; }
ok()   { printf '      OK: %s\n' "$1"; }
warn() { printf '      WARNING: %s\n' "$1"; }
die()  { printf '\nERROR: %s\n' "$1" >&2; exit 1; }

trap 'die "Installation failed at line $LINENO. Check the output above."' ERR

[[ $EUID -eq 0 ]] || die "Run this installer with sudo/root."

# Resolve the non-root operator so RTVS_files is placed in the expected home.
TARGET_USER="${SUDO_USER:-}"
if [[ -z "$TARGET_USER" || "$TARGET_USER" == "root" ]]; then
    TARGET_USER="$(id -un)"
fi
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[[ -n "$TARGET_HOME" && -d "$TARGET_HOME" ]] || die "Cannot determine home directory for user: $TARGET_USER"

RTVS_ROOT="$TARGET_HOME/RTVS_files"
RTVS_DIR="$RTVS_ROOT/RTVS"
SCRIPT_ROOT="$RTVS_DIR/script"
NGINX_CONF_DIR="/etc/nginx/conf.d"

export DEBIAN_FRONTEND=noninteractive

command_exists() { command -v "$1" >/dev/null 2>&1; }

detect_os() {
    [[ -r /etc/os-release ]] || die "/etc/os-release not found."
    # shellcheck disable=SC1091
    source /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_LIKE="${ID_LIKE:-}"
    OS_VERSION="${VERSION_ID:-unknown}"

    case "$OS_ID" in
        ubuntu|debian)
            PKG_FAMILY="debian"
            PKG_UPDATE=(apt-get update)
            PKG_INSTALL=(apt-get install -y)
            ;;
        rhel|centos|rocky|almalinux|fedora)
            PKG_FAMILY="rhel"
            if command_exists dnf; then
                PKG_UPDATE=(dnf makecache)
                PKG_INSTALL=(dnf install -y)
            elif command_exists yum; then
                PKG_UPDATE=(yum makecache)
                PKG_INSTALL=(yum install -y)
            else
                die "Neither dnf nor yum is available."
            fi
            ;;
        *)
            if [[ "$OS_LIKE" == *debian* ]]; then
                PKG_FAMILY="debian"
                PKG_UPDATE=(apt-get update)
                PKG_INSTALL=(apt-get install -y)
            elif [[ "$OS_LIKE" == *rhel* || "$OS_LIKE" == *fedora* ]]; then
                PKG_FAMILY="rhel"
                if command_exists dnf; then
                    PKG_UPDATE=(dnf makecache)
                    PKG_INSTALL=(dnf install -y)
                elif command_exists yum; then
                    PKG_UPDATE=(yum makecache)
                    PKG_INSTALL=(yum install -y)
                else
                    die "Unsupported RPM-based system: $OS_ID"
                fi
            else
                die "Unsupported Linux distribution: $OS_ID $OS_VERSION"
            fi
            ;;
    esac
}

install_packages() {
    log "2/9" "Installing required OS packages"

    if [[ "$PKG_FAMILY" == "debian" ]]; then
        "${PKG_UPDATE[@]}"
        "${PKG_INSTALL[@]}" ca-certificates curl unzip gnupg lsb-release nginx
    else
        "${PKG_UPDATE[@]}" || true
        "${PKG_INSTALL[@]}" ca-certificates curl unzip gnupg2 nginx
    fi

    ok "Required utilities and Nginx installed"
}

install_docker() {
    log "3/9" "Installing/verifying Docker and Docker Compose"

    if ! command_exists docker; then
        if [[ "$PKG_FAMILY" == "debian" ]]; then
            # Prefer distro packages; this is reliable for supported Ubuntu/Debian hosts.
            "${PKG_INSTALL[@]}" docker.io || {
                warn "docker.io package unavailable; using Docker's official installation script."
                curl -fsSL https://get.docker.com | sh
            }
        else
            # RHEL-family package names vary; Docker CE repositories are not assumed configured.
            "${PKG_INSTALL[@]}" docker || {
                warn "Native docker package unavailable; using Docker's official installation script."
                curl -fsSL https://get.docker.com | sh
            }
        fi
    fi

    systemctl enable --now docker
    docker version >/dev/null

    # Compose v2 is preferred because the RTVS package uses modern Docker tooling.
    if docker compose version >/dev/null 2>&1; then
        ok "Docker Compose v2 available: $(docker compose version --short 2>/dev/null || true)"
    else
        if [[ "$PKG_FAMILY" == "debian" ]]; then
            "${PKG_INSTALL[@]}" docker-compose-plugin || true
        else
            "${PKG_INSTALL[@]}" docker-compose-plugin || true
        fi

        if ! docker compose version >/dev/null 2>&1; then
            if command_exists docker-compose; then
                ok "Legacy docker-compose available"
            else
                die "Docker is installed, but Docker Compose is not available."
            fi
        else
            ok "Docker Compose v2 installed"
        fi
    fi

    # Allow the target user to run Docker without sudo after installation.
    usermod -aG docker "$TARGET_USER" || true
    ok "Docker service is enabled and running"
}

validate_domain() {
    local d="$1"
    [[ ${#d} -le 253 ]] || return 1
    [[ "$d" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || return 1
    [[ "$d" != *".."* ]] || return 1
    [[ "$d" != *"/"* && "$d" != *":"* && "$d" != *" "* ]] || return 1
}

prepare_rtv_files() {
    log "4/9" "Preparing RTVS package"

    [[ -f "$ZIP_FILE" ]] || die "RTVS_files.zip not found: $ZIP_FILE"

    # Do not destroy an existing installation automatically.
    if [[ -f "$SCRIPT_ROOT/run_all.sh" ]]; then
        ok "Existing RTVS installation found at $RTVS_ROOT; reusing it"
        return
    fi

    if [[ -e "$RTVS_ROOT" ]]; then
        local backup="${RTVS_ROOT}.backup.$(date +%Y%m%d-%H%M%S)"
        mv "$RTVS_ROOT" "$backup"
        warn "Existing incomplete RTVS directory moved to $backup"
    fi

    mkdir -p "$TARGET_HOME"
    unzip -q "$ZIP_FILE" -d "$TARGET_HOME"

    [[ -f "$SCRIPT_ROOT/run_all.sh" ]] || die "ZIP extracted, but expected $SCRIPT_ROOT/run_all.sh was not found."
    [[ -f "$SCRIPT_ROOT/default_args.sh" ]] || die "Expected default_args.sh was not found."
    [[ -f "$SCRIPT_ROOT/pull_all.sh" ]] || die "Expected pull_all.sh was not found."

    chown -R "$TARGET_USER":"$(id -gn "$TARGET_USER")" "$RTVS_ROOT"
    ok "RTVS package extracted to $SCRIPT_ROOT"
}

configure_domain() {
    log "5/9" "Configuring domain"

    printf '\nEnter the domain for this RTVS server.\n'
    printf 'Example: streaming.example.com\n'
    read -r -p "New domain: " NEW_DOMAIN

    NEW_DOMAIN="${NEW_DOMAIN,,}"
    validate_domain "$NEW_DOMAIN" || die "Invalid domain: $NEW_DOMAIN"

    # Replace only text files under the active RTVS source tree.
    # Exclude certificates, git metadata, and backup trees.
    local changed=0
    while IFS= read -r -d '' file; do
        if grep -Iq "$BASE_DOMAIN" "$file"; then
            sed -i "s/${BASE_DOMAIN}/${NEW_DOMAIN}/g" "$file"
            changed=$((changed + 1))
        fi
    done < <(
        find "$RTVS_DIR" -type f -print0 \
            ! -path '*/.git/*' \
            ! -path '*/rtvs_backup/*' \
            ! -name '*.pem' \
            ! -name '*.key'
    )

    # Ensure run_all.sh has the requested IPADDRESS explicitly.
    if grep -q '^export IPADDRESS=' "$SCRIPT_ROOT/run_all.sh"; then
        sed -i "s|^export IPADDRESS=.*$|export IPADDRESS=$NEW_DOMAIN|" "$SCRIPT_ROOT/run_all.sh"
    else
        printf '\nexport IPADDRESS=%s\n' "$NEW_DOMAIN" >> "$SCRIPT_ROOT/run_all.sh"
    fi

    # Preserve the HTTPS wrapper's certificate path convention.
    if [[ -f "$SCRIPT_ROOT/run_all_https.sh" ]]; then
        sed -i "s|/etc/letsencrypt/live/[^/]*/|/etc/letsencrypt/live/${NEW_DOMAIN}/|g" \
            "$SCRIPT_ROOT/run_all_https.sh"
        sed -i "s|^export BeianAddress=.*$|export BeianAddress=$NEW_DOMAIN|" \
            "$SCRIPT_ROOT/run_all_https.sh" || true
    fi

    chown -R "$TARGET_USER":"$(id -gn "$TARGET_USER")" "$RTVS_ROOT"

    printf '      Domain: %s -> %s\n' "$BASE_DOMAIN" "$NEW_DOMAIN"
    printf '      Source files changed: %s\n' "$changed"
    ok "Domain configuration completed"
}

configure_nginx() {
    log "6/9" "Creating host Nginx reverse-proxy configuration"

    mkdir -p "$NGINX_CONF_DIR"
    NGINX_CONF="$NGINX_CONF_DIR/${NEW_DOMAIN}.conf"

    cat > "$NGINX_CONF" <<EOF
server {
    listen 80;
    server_name ${NEW_DOMAIN};

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

    # Disable an old installer-managed config if it exists for another domain.
    # Do not touch unrelated Nginx configuration files.
    if [[ -d "$NGINX_CONF_DIR" ]]; then
        find "$NGINX_CONF_DIR" -maxdepth 1 -type f -name 'rtvs-installer-*.conf' \
            ! -name "rtvs-installer-${NEW_DOMAIN}.conf" -delete 2>/dev/null || true
    fi

    nginx -t
    systemctl enable --now nginx
    systemctl reload nginx

    ok "Nginx configured: $NGINX_CONF"
}

make_scripts_executable() {
    log "7/9" "Preparing RTVS scripts"
    find "$SCRIPT_ROOT" -type f -name '*.sh' -exec chmod +x {} +
    ok "RTVS shell scripts are executable"
}

start_rtvs() {
    log "8/9" "Starting RTVS"

    cd "$SCRIPT_ROOT"
    ./run_all.sh

    ok "RTVS startup script completed"
}

verify_installation() {
    log "9/9" "Verifying containers, ports, and HTTP endpoint"

    local failures=0

    echo
    echo "Docker containers:"
    docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'

    local required_containers=(
        "cvcluster-1"
        "gbsip-1"
        "tstgw808-1"
        "attachment-1"
        "sfu-mediasoup"
        "rtvsweb-publish-1"
        "nginx-rtmp-1"
    )

    echo
    echo "Required RTVS containers:"
    for c in "${required_containers[@]}"; do
        if docker ps --format '{{.Names}}' | grep -Fxq "$c"; then
            ok "$c is running"
        else
            warn "$c is NOT running"
            failures=$((failures + 1))
        fi
    done

    echo
    echo "Host port listeners:"
    ss -lntup 2>/dev/null | grep -E ':(80|6001|6003|6004|6005|6006|6007|6008|6010|6011|6012|6013|6015|6016|6017|6018|6019|6020|6021|6022|6024|6025|6028|6029|6030|6031|6032|6033|6034|6035|6036|9080|9081|9082|9300|17000|14001|14002|5060)\b' || true

    echo
    echo "Nginx local HTTP check:"
    if curl -fsS -I --max-time 10 -H "Host: $NEW_DOMAIN" "http://127.0.0.1/" >/tmp/rtvs_nginx_check.out 2>&1; then
        head -n 1 /tmp/rtvs_nginx_check.out
        ok "Nginx is proxying HTTP requests"
    else
        warn "Nginx HTTP check failed. DNS/firewall/backend may still need configuration."
        failures=$((failures + 1))
    fi

    echo
    echo "============================================================"
    if [[ "$failures" -eq 0 ]]; then
        echo "RTVS INSTALLATION COMPLETED SUCCESSFULLY"
    else
        echo "RTVS INSTALLATION COMPLETED WITH $failures VERIFICATION WARNING(S)"
    fi
    echo "Domain       : $NEW_DOMAIN"
    echo "RTVS path    : $SCRIPT_ROOT"
    echo "Nginx config : $NGINX_CONF_DIR/${NEW_DOMAIN}.conf"
    echo "============================================================"
    echo
    echo "Important:"
    echo "1. Point DNS for $NEW_DOMAIN to this server's public IP."
    echo "2. Allow only the required RTVS ports in the cloud firewall/security group."
    echo "3. HTTPS is not provisioned by this installer. If required, obtain a certificate"
    echo "   for $NEW_DOMAIN and then use run_all_https.sh."
    echo "4. Log out/in once if you want the docker group change to take effect for $TARGET_USER."
}

detect_os
log "1/9" "Detecting operating system"
ok "$OS_ID $OS_VERSION ($PKG_FAMILY package family)"

install_packages
install_docker
prepare_rtv_files
configure_domain
make_scripts_executable
configure_nginx
start_rtvs
verify_installation

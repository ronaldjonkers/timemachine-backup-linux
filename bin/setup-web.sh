#!/usr/bin/env bash
# ============================================================
# TimeMachine Backup - Web Dashboard Setup (Nginx + SSL + Auth)
# ============================================================
# Sets up the TimeMachine web dashboard for external access:
#   - Installs and configures Nginx as reverse proxy
#   - Obtains Let's Encrypt SSL certificate via certbot
#   - Creates HTTP Basic Auth credentials (bcrypt)
#   - Configures firewall rules (ufw/firewalld)
#
# Usage:
#   sudo tmctl setup-web
#   sudo tmctl setup-web --domain tm.example.com --email admin@example.com
#   sudo tmctl setup-web --remove
#
# The dashboard will be available at https://<domain>/
# API endpoints are also proxied and protected by auth.
# The /api/ssh-key/raw endpoint can optionally be left open
# for automated client installs.
#
# Supports: Debian/Ubuntu, RHEL/CentOS/Fedora
# ============================================================

set -euo pipefail

# Resolve symlinks to find real script directory
_src="$0"
while [[ -L "$_src" ]]; do
    _src_dir="$(cd -P "$(dirname "$_src")" && pwd)"
    _src="$(readlink "$_src")"
    [[ "$_src" != /* ]] && _src="$_src_dir/$_src"
done
SCRIPT_DIR="$(cd -P "$(dirname "$_src")" && pwd)"

source "${SCRIPT_DIR}/../lib/common.sh"
tm_load_config

: "${TM_API_PORT:=7600}"
: "${TM_API_BIND:=127.0.0.1}"

NGINX_CONF_DIR="/etc/nginx"
NGINX_SITE_NAME="timemachine"
HTPASSWD_FILE="/etc/nginx/.timemachine_htpasswd"

# ============================================================
# COLORS & HELPERS
# ============================================================

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'
BOLD=$'\033[1m'
NC=$'\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

require_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        error "This script must be run as root (use sudo)"
    fi
}

detect_os() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        echo "${ID}"
    else
        echo "unknown"
    fi
}

read_input() {
    local prompt="$1" default="$2" result
    if [[ -t 0 ]]; then
        read -r -p "${prompt}" result
    elif [[ -e /dev/tty ]]; then
        read -r -p "${prompt}" result < /dev/tty
    else
        result=""
    fi
    echo "${result:-${default}}"
}

read_password() {
    local prompt="$1" result
    if [[ -t 0 ]]; then
        read -r -s -p "${prompt}" result
        echo "" >&2
    elif [[ -e /dev/tty ]]; then
        read -r -s -p "${prompt}" result < /dev/tty
        echo "" >&2
    else
        result=""
    fi
    echo "${result}"
}

# ============================================================
# ARGUMENT PARSING
# ============================================================

DOMAIN=""
EMAIL=""
AUTH_USER=""
AUTH_PASS=""
OPEN_SSH_KEY=0
REMOVE_MODE=0

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --domain)    DOMAIN="$2"; shift 2 ;;
            --email)     EMAIL="$2"; shift 2 ;;
            --user)      AUTH_USER="$2"; shift 2 ;;
            --pass)      AUTH_PASS="$2"; shift 2 ;;
            --open-ssh-key) OPEN_SSH_KEY=1; shift ;;
            --remove|--uninstall) REMOVE_MODE=1; shift ;;
            *) warn "Unknown option: $1"; shift ;;
        esac
    done
}

# ============================================================
# INTERACTIVE PROMPTS
# ============================================================

prompt_config() {
    echo ""
    echo -e "${BOLD}TimeMachine Web Dashboard Setup${NC}"
    echo "============================================"
    echo ""
    echo -e "This will configure ${CYAN}Nginx${NC} + ${CYAN}Let's Encrypt SSL${NC} + ${CYAN}Basic Auth${NC}"
    echo -e "to expose the dashboard securely over HTTPS."
    echo ""

    # Domain
    if [[ -z "${DOMAIN}" ]]; then
        DOMAIN=$(read_input "  Domain name (e.g. tm.example.com): " "")
        [[ -z "${DOMAIN}" ]] && error "Domain name is required"
    fi
    info "Domain: ${DOMAIN}"

    # Email for certbot
    if [[ -z "${EMAIL}" ]]; then
        EMAIL=$(read_input "  Email for Let's Encrypt (e.g. admin@example.com): " "")
        [[ -z "${EMAIL}" ]] && error "Email is required for Let's Encrypt"
    fi
    info "Email: ${EMAIL}"

    # Auth username
    if [[ -z "${AUTH_USER}" ]]; then
        AUTH_USER=$(read_input "  Dashboard username: " "admin")
    fi
    info "Username: ${AUTH_USER}"

    # Auth password
    if [[ -z "${AUTH_PASS}" ]]; then
        AUTH_PASS=$(read_password "  Dashboard password: ")
        [[ -z "${AUTH_PASS}" ]] && error "Password is required"
        local confirm
        confirm=$(read_password "  Confirm password: ")
        [[ "${AUTH_PASS}" != "${confirm}" ]] && error "Passwords do not match"
    fi
    info "Password: ********"

    # Open SSH key endpoint?
    if [[ ${OPEN_SSH_KEY} -eq 0 ]]; then
        echo ""
        local answer
        answer=$(read_input "  Allow unauthenticated access to /api/ssh-key/raw? (for client installs) [y/N]: " "n")
        [[ "${answer}" =~ ^[Yy] ]] && OPEN_SSH_KEY=1
    fi
    if [[ ${OPEN_SSH_KEY} -eq 1 ]]; then
        info "SSH key endpoint: open (no auth)"
    else
        info "SSH key endpoint: protected (requires auth)"
    fi

    echo ""
}

# ============================================================
# INSTALL DEPENDENCIES
# ============================================================

install_deps() {
    local os
    os=$(detect_os)

    info "Installing Nginx and Certbot..."

    case "${os}" in
        ubuntu|debian)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq
            apt-get install -y -qq nginx certbot python3-certbot-nginx apache2-utils > /dev/null
            ;;
        centos|rhel|rocky|almalinux|fedora)
            if command -v dnf &>/dev/null; then
                dnf install -y -q nginx certbot python3-certbot-nginx httpd-tools
            else
                yum install -y -q nginx certbot python3-certbot-nginx httpd-tools
            fi
            ;;
        *)
            error "Unsupported OS: ${os}. Install nginx, certbot, and apache2-utils/httpd-tools manually."
            ;;
    esac

    # Ensure nginx is enabled
    systemctl enable nginx 2>/dev/null || true
    info "Dependencies installed"
}

# ============================================================
# CREATE HTPASSWD
# ============================================================

create_htpasswd() {
    info "Creating authentication credentials..."

    # Use htpasswd with bcrypt (-B)
    if command -v htpasswd &>/dev/null; then
        htpasswd -cbB "${HTPASSWD_FILE}" "${AUTH_USER}" "${AUTH_PASS}"
    else
        # Fallback: use openssl for password hash
        local hash
        hash=$(openssl passwd -apr1 "${AUTH_PASS}")
        echo "${AUTH_USER}:${hash}" > "${HTPASSWD_FILE}"
    fi

    chmod 640 "${HTPASSWD_FILE}"
    chown root:nginx "${HTPASSWD_FILE}" 2>/dev/null || \
    chown root:www-data "${HTPASSWD_FILE}" 2>/dev/null || true

    info "Credentials saved to ${HTPASSWD_FILE}"
}

# ============================================================
# CONFIGURE NGINX
# ============================================================

configure_nginx() {
    info "Configuring Nginx reverse proxy..."

    # Determine config path
    local site_conf=""
    if [[ -d "${NGINX_CONF_DIR}/sites-available" ]]; then
        # Debian/Ubuntu style
        site_conf="${NGINX_CONF_DIR}/sites-available/${NGINX_SITE_NAME}"
    elif [[ -d "${NGINX_CONF_DIR}/conf.d" ]]; then
        # RHEL/CentOS style
        site_conf="${NGINX_CONF_DIR}/conf.d/${NGINX_SITE_NAME}.conf"
    else
        error "Cannot find nginx config directory"
    fi

    # Build location block for optional open SSH key endpoint
    local ssh_key_location=""
    if [[ ${OPEN_SSH_KEY} -eq 1 ]]; then
        ssh_key_location="
    # SSH key endpoint — open for automated client installs
    location = /api/ssh-key/raw {
        auth_basic off;
        proxy_pass http://127.0.0.1:${TM_API_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
"
    fi

    # Write initial HTTP-only config (certbot will upgrade to HTTPS)
    cat > "${site_conf}" <<NGINX_EOF
# TimeMachine Backup - Nginx Reverse Proxy
# Generated by: tmctl setup-web
# Domain: ${DOMAIN}

server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    # Let's Encrypt challenge
    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    # Redirect all HTTP to HTTPS (certbot will add SSL block)
    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${DOMAIN};

    # SSL certificates (will be filled by certbot)
    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;

    # SSL hardening
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;

    # Security headers
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "DENY" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    # Basic Auth for all routes
    auth_basic "TimeMachine Dashboard";
    auth_basic_user_file ${HTPASSWD_FILE};
${ssh_key_location}
    # Proxy all requests to TimeMachine service
    location / {
        proxy_pass http://127.0.0.1:${TM_API_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        # WebSocket support (future)
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
NGINX_EOF

    # Enable site (Debian/Ubuntu)
    if [[ -d "${NGINX_CONF_DIR}/sites-available" ]]; then
        ln -sf "${site_conf}" "${NGINX_CONF_DIR}/sites-enabled/${NGINX_SITE_NAME}"
        # Remove default site if it exists
        rm -f "${NGINX_CONF_DIR}/sites-enabled/default"
    fi

    info "Nginx config written to ${site_conf}"
}

# ============================================================
# OBTAIN SSL CERTIFICATE
# ============================================================

obtain_ssl() {
    info "Obtaining Let's Encrypt SSL certificate..."

    # First, start nginx with just the HTTP block for the ACME challenge
    # We need a temporary config that doesn't reference the cert yet
    local site_conf=""
    if [[ -d "${NGINX_CONF_DIR}/sites-available" ]]; then
        site_conf="${NGINX_CONF_DIR}/sites-available/${NGINX_SITE_NAME}"
    else
        site_conf="${NGINX_CONF_DIR}/conf.d/${NGINX_SITE_NAME}.conf"
    fi

    # Write temporary HTTP-only config
    local tmp_conf="${site_conf}.tmp"
    cat > "${tmp_conf}" <<TMPEOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        return 200 'TimeMachine setup in progress...';
        add_header Content-Type text/plain;
    }
}
TMPEOF

    # Swap in temp config
    cp "${site_conf}" "${site_conf}.full"
    mv "${tmp_conf}" "${site_conf}"

    # Reload nginx with HTTP-only config
    mkdir -p /var/www/html
    nginx -t 2>/dev/null && systemctl reload nginx

    # Run certbot
    certbot certonly \
        --nginx \
        --non-interactive \
        --agree-tos \
        --email "${EMAIL}" \
        -d "${DOMAIN}" \
        --redirect 2>&1 | while IFS= read -r line; do
            echo "  ${line}"
        done

    local certbot_rc=${PIPESTATUS[0]}

    # Restore full config
    mv "${site_conf}.full" "${site_conf}"

    if [[ ${certbot_rc} -ne 0 ]]; then
        error "Certbot failed. Make sure DNS for ${DOMAIN} points to this server and port 80 is open."
    fi

    # Verify cert exists
    if [[ ! -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]]; then
        error "SSL certificate not found after certbot. Check certbot logs."
    fi

    info "SSL certificate obtained for ${DOMAIN}"

    # Setup auto-renewal timer
    if systemctl list-unit-files certbot.timer &>/dev/null; then
        systemctl enable certbot.timer 2>/dev/null || true
        systemctl start certbot.timer 2>/dev/null || true
        info "Certbot auto-renewal enabled"
    else
        # Add cron job for renewal
        if ! crontab -l 2>/dev/null | grep -q "certbot renew"; then
            (crontab -l 2>/dev/null; echo "0 3 * * * certbot renew --quiet --post-hook 'systemctl reload nginx'") | crontab -
            info "Certbot renewal cron job added"
        fi
    fi
}

# ============================================================
# CONFIGURE FIREWALL
# ============================================================

configure_firewall() {
    info "Configuring firewall..."

    if command -v ufw &>/dev/null; then
        ufw allow 80/tcp 2>/dev/null || true
        ufw allow 443/tcp 2>/dev/null || true
        info "UFW: ports 80 and 443 opened"
    elif command -v firewall-cmd &>/dev/null; then
        firewall-cmd --permanent --add-service=http 2>/dev/null || true
        firewall-cmd --permanent --add-service=https 2>/dev/null || true
        firewall-cmd --reload 2>/dev/null || true
        info "Firewalld: HTTP and HTTPS services enabled"
    else
        warn "No firewall detected. Make sure ports 80 and 443 are open."
    fi
}

# ============================================================
# BIND API TO LOCALHOST ONLY
# ============================================================

secure_api_bind() {
    # Ensure the TimeMachine API only listens on localhost
    # so it's only accessible through nginx
    local env_file="${TM_PROJECT_ROOT}/.env"

    if [[ -f "${env_file}" ]]; then
        if grep -q "^TM_API_BIND=" "${env_file}"; then
            sed -i.bak 's/^TM_API_BIND=.*/TM_API_BIND="127.0.0.1"/' "${env_file}" 2>/dev/null || \
            sed -i '' 's/^TM_API_BIND=.*/TM_API_BIND="127.0.0.1"/' "${env_file}"
            rm -f "${env_file}.bak"
        else
            echo 'TM_API_BIND="127.0.0.1"' >> "${env_file}"
        fi
    else
        echo '# TimeMachine API — bind to localhost (nginx proxies external traffic)' > "${env_file}"
        echo 'TM_API_BIND="127.0.0.1"' >> "${env_file}"
    fi

    info "API bind set to 127.0.0.1 (only accessible via nginx)"
}

# ============================================================
# FINALIZE
# ============================================================

finalize() {
    # Test nginx config
    if ! nginx -t 2>&1; then
        error "Nginx configuration test failed"
    fi

    # Reload nginx
    systemctl reload nginx
    info "Nginx reloaded"

    echo ""
    echo -e "${BOLD}============================================${NC}"
    echo -e "${GREEN}  Web dashboard setup complete!${NC}"
    echo -e "${BOLD}============================================${NC}"
    echo ""
    echo -e "  URL:      ${CYAN}https://${DOMAIN}/${NC}"
    echo -e "  Username: ${BOLD}${AUTH_USER}${NC}"
    echo -e "  Password: ${BOLD}********${NC}"
    echo ""
    if [[ ${OPEN_SSH_KEY} -eq 1 ]]; then
        echo -e "  SSH key (no auth): ${CYAN}https://${DOMAIN}/api/ssh-key/raw${NC}"
        echo ""
    fi
    echo -e "  SSL auto-renewal is configured via certbot."
    echo -e "  API is bound to localhost — external access only via nginx."
    echo ""
    echo -e "  To change the password:"
    echo -e "    ${CYAN}sudo htpasswd -B ${HTPASSWD_FILE} ${AUTH_USER}${NC}"
    echo ""
    echo -e "  To add another user:"
    echo -e "    ${CYAN}sudo htpasswd -B ${HTPASSWD_FILE} <username>${NC}"
    echo ""
    echo -e "  To remove web access:"
    echo -e "    ${CYAN}sudo tmctl setup-web --remove${NC}"
    echo ""
}

# ============================================================
# REMOVE
# ============================================================

remove_web() {
    info "Removing web dashboard external access..."

    # Remove nginx config
    local site_conf=""
    if [[ -d "${NGINX_CONF_DIR}/sites-available" ]]; then
        site_conf="${NGINX_CONF_DIR}/sites-available/${NGINX_SITE_NAME}"
        rm -f "${NGINX_CONF_DIR}/sites-enabled/${NGINX_SITE_NAME}"
        rm -f "${site_conf}"
    elif [[ -d "${NGINX_CONF_DIR}/conf.d" ]]; then
        site_conf="${NGINX_CONF_DIR}/conf.d/${NGINX_SITE_NAME}.conf"
        rm -f "${site_conf}"
    fi

    # Remove htpasswd
    rm -f "${HTPASSWD_FILE}"

    # Reload nginx
    if systemctl is-active nginx &>/dev/null; then
        nginx -t 2>/dev/null && systemctl reload nginx
    fi

    # Reset API bind
    local env_file="${TM_PROJECT_ROOT}/.env"
    if [[ -f "${env_file}" ]]; then
        sed -i.bak 's/^TM_API_BIND=.*/TM_API_BIND="0.0.0.0"/' "${env_file}" 2>/dev/null || \
        sed -i '' 's/^TM_API_BIND=.*/TM_API_BIND="0.0.0.0"/' "${env_file}"
        rm -f "${env_file}.bak"
    fi

    echo ""
    echo -e "${GREEN}Web dashboard external access removed.${NC}"
    echo -e "The dashboard is still available locally at http://localhost:${TM_API_PORT}/"
    echo ""
}

# ============================================================
# MAIN
# ============================================================

main() {
    require_root
    parse_args "$@"

    if [[ ${REMOVE_MODE} -eq 1 ]]; then
        remove_web
        exit 0
    fi

    prompt_config
    install_deps
    create_htpasswd
    configure_nginx
    obtain_ssl
    configure_firewall
    secure_api_bind
    finalize
}

main "$@"

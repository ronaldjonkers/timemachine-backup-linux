#!/usr/bin/env bash
# ============================================================
# TimeMachine Backup - Post-Update / Reconfigure
# ============================================================
# Idempotent: safe to run any number of times. Called automatically
# by 'tmctl update' (as root) and by install.sh. Ensures:
#   1. Python dependencies (fido2 for passkey login)
#   2. Portal security settings in .env (proxy key, portal domain,
#      localhost API bind) when nginx is configured
#   3. nginx config carries the proxy-key header and serves the
#      login/register pages
#   4. Service restart so everything is picked up
#
# Usage: post-update.sh [--deps-only] [--no-restart]
# ============================================================

_src="$0"
while [[ -L "$_src" ]]; do
    _src_dir="$(cd -P "$(dirname "$_src")" && pwd)"
    _src="$(readlink "$_src")"
    [[ "$_src" != /* ]] && _src="$_src_dir/$_src"
done
SCRIPT_DIR="$(cd -P "$(dirname "$_src")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${PROJECT_ROOT}/.env"

DEPS_ONLY=0
NO_RESTART=0
for arg in "$@"; do
    case "${arg}" in
        --deps-only)  DEPS_ONLY=1 ;;
        --no-restart) NO_RESTART=1 ;;
    esac
done

info() { echo "  [post-update] $*"; }
warn() { echo "  [post-update] WARNING: $*" >&2; }

# ============================================================
# 1. PYTHON DEPENDENCIES (fido2 for passkeys)
# ============================================================

# Echo the path/name of the newest Python >= 3.8 available on the host, or
# nothing. fido2 (passkeys) needs 3.8+; the system python3 is often 3.6 (e.g.
# CentOS/RHEL 7), so we look for a separately-installed newer interpreter,
# INCLUDING Software Collections paths that are not on PATH.
_best_python() {
    local best="" best_ver=0 cand ver
    local names="python3.13 python3.12 python3.11 python3.10 python3.9 python3.8 python3 python"
    local scl
    for scl in /opt/rh/rh-python3*/root/usr/bin/python3.* /opt/rh/rh-python3*/root/usr/bin/python3; do
        [[ -x "${scl}" ]] && names="${names} ${scl}"
    done
    for cand in ${names}; do
        command -v "${cand}" &>/dev/null || [[ -x "${cand}" ]] || continue
        ver=$("${cand}" -c 'import sys; print(sys.version_info[0]*100+sys.version_info[1])' 2>/dev/null) || continue
        if [[ -n "${ver}" && "${ver}" -ge 308 && "${ver}" -gt "${best_ver}" ]]; then
            best_ver="${ver}"; best="${cand}"
        fi
    done
    [[ -n "${best}" ]] && echo "${best}"
}

# Best-effort install of a modern Python (>=3.8) via the distro package
# manager. Leaves the system python3 untouched. Never fails the update.
_install_modern_python() {
    info "No Python 3.8+ found — trying to install one for passkeys (system python3 stays untouched)..."
    if command -v apt-get &>/dev/null; then
        apt-get update -qq 2>/dev/null || true
        for pkg in python3.11 python3.12 python3.10 python3.9 python3.8; do
            apt-get install -y -qq "${pkg}" "${pkg}-venv" 2>/dev/null && break || true
        done
    elif command -v dnf &>/dev/null; then
        for pkg in python3.11 python3.12 python3.9; do
            dnf install -y -q "${pkg}" 2>/dev/null && break || true
        done
    elif command -v yum &>/dev/null; then
        # RHEL/CentOS 7: modern Python comes from Software Collections
        yum install -y -q centos-release-scl 2>/dev/null || true
        yum install -y -q rh-python38 2>/dev/null || \
            yum install -y -q python38 2>/dev/null || true
    elif command -v zypper &>/dev/null; then
        for pkg in python311 python310 python39 python38; do
            zypper --non-interactive install "${pkg}" 2>/dev/null && break || true
        done
    fi
}

ensure_fido2() {
    local py
    py=$(_best_python)

    # Already have a passkey-capable Python with fido2 present? Record it and stop.
    if [[ -n "${py}" ]] && "${py}" -c 'import fido2' 2>/dev/null; then
        _upsert_env TM_PYTHON_BIN "${py}"
        info "fido2: already installed — passkeys enabled (${py})"
        return 0
    fi

    # No Python 3.8+ at all — try to install one, then look again.
    if [[ -z "${py}" ]]; then
        _install_modern_python
        py=$(_best_python)
    fi

    if [[ -z "${py}" ]]; then
        local cur
        cur=$(python3 -V 2>&1 | awk '{print $2}')
        info "Passkeys disabled: no Python 3.8+ available (system Python is ${cur:-unknown})."
        info "This is expected — the dashboard keeps working via Basic Auth."
        info "To enable passkeys later, install Python 3.8+ and re-run: sudo tmctl update"
        return 0
    fi

    info "Installing Python 'fido2' package for passkeys (${py})..."

    # Ensure pip for THIS interpreter (not necessarily the system python3).
    "${py}" -m pip --version &>/dev/null || "${py}" -m ensurepip --upgrade 2>/dev/null || true
    if ! "${py}" -m pip --version &>/dev/null; then
        if command -v apt-get &>/dev/null; then apt-get install -y -qq python3-pip 2>/dev/null || true
        elif command -v dnf &>/dev/null; then dnf install -y -q python3-pip 2>/dev/null || true
        elif command -v yum &>/dev/null; then yum install -y -q python3-pip 2>/dev/null || true
        fi
    fi

    # Install fido2 into the chosen interpreter (PEP 668 fallback for modern Debian/Ubuntu).
    "${py}" -m pip install -q fido2 2>/dev/null || \
        "${py}" -m pip install -q --break-system-packages fido2 2>/dev/null || true

    if "${py}" -c 'import fido2' 2>/dev/null; then
        _upsert_env TM_PYTHON_BIN "${py}"
        info "fido2: installed — passkeys enabled (API server will use ${py})"
    else
        info "Could not install fido2 for ${py}. Passkeys stay unavailable (dashboard uses Basic Auth)."
        info "Manual step: ${py} -m pip install fido2 && sudo tmctl update"
    fi
}

# ============================================================
# 2 + 3. PORTAL SETTINGS + NGINX CONFIG
# ============================================================

_upsert_env() {
    local key="$1" value="$2"
    touch "${ENV_FILE}"
    if grep -q "^${key}=" "${ENV_FILE}"; then
        sed -i.bak "s|^${key}=.*|${key}=\"${value}\"|" "${ENV_FILE}" 2>/dev/null || \
        sed -i '' "s|^${key}=.*|${key}=\"${value}\"|" "${ENV_FILE}"
        rm -f "${ENV_FILE}.bak"
    else
        echo "${key}=\"${value}\"" >> "${ENV_FILE}"
    fi
}

_env_get() {
    sed -n "s/^$1=//p" "${ENV_FILE}" 2>/dev/null | head -1 | tr -d '"' | tr -d "'"
}

find_nginx_conf() {
    local c
    for c in /etc/nginx/sites-available/timemachine /etc/nginx/conf.d/timemachine.conf; do
        [[ -f "${c}" ]] && { echo "${c}"; return 0; }
    done
    return 1
}

migrate_portal_config() {
    local conf
    conf=$(find_nginx_conf) || { info "No nginx config found — portal migration skipped (run 'tmctl setup-web' for the dashboard)"; return 0; }

    # --- .env: proxy key ---
    local proxy_key
    proxy_key=$(_env_get TM_PROXY_KEY)
    if [[ -z "${proxy_key}" ]]; then
        proxy_key=$(openssl rand -hex 32 2>/dev/null) || \
            proxy_key=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
        _upsert_env TM_PROXY_KEY "${proxy_key}"
        info "Generated API proxy key"
    fi

    # --- .env: portal domain (from nginx server_name) ---
    if [[ -z "$(_env_get TM_PORTAL_DOMAIN)" ]]; then
        local domain
        domain=$(grep -E '^\s*server_name\s' "${conf}" | head -1 | awk '{print $2}' | tr -d ';')
        if [[ -n "${domain}" && "${domain}" != "_" ]]; then
            _upsert_env TM_PORTAL_DOMAIN "${domain}"
            info "Portal domain set from nginx: ${domain}"
        else
            info "No real server_name in nginx config — set TM_PORTAL_DOMAIN in .env manually for passkeys"
        fi
    fi

    # --- .env: bind API to localhost (nginx proxies external traffic) ---
    if [[ "$(_env_get TM_API_BIND)" != "127.0.0.1" ]]; then
        _upsert_env TM_API_BIND "127.0.0.1"
        info "API bind set to 127.0.0.1"
    fi

    chmod 600 "${ENV_FILE}" 2>/dev/null || true

    # --- nginx: inject proxy-key header + serve login/register pages ---
    TM_PU_CONF="${conf}" TM_PU_KEY="${proxy_key}" python3 <<'PYEOF'
import os, re, sys

conf_path = os.environ['TM_PU_CONF']
key = os.environ['TM_PU_KEY']
src = open(conf_path).read()
orig = src

# 1. Remove any stale proxy-key headers with a DIFFERENT key, then add the
#    header after every proxy_pass to the local API that lacks it.
src = re.sub(r'\n(\s*)proxy_set_header X-TM-Proxy-Key "(?!' + re.escape(key) + r'")[^"]*";', '', src)

def add_header(match):
    line, indent = match.group(0), match.group(1)
    block_after = src[match.end():match.end() + 400]
    if 'X-TM-Proxy-Key' in block_after.split('}')[0]:
        return line
    return line + '\n' + indent + 'proxy_set_header X-TM-Proxy-Key "' + key + '";'

src = re.sub(r'(?m)^(\s*)proxy_pass http://127\.0\.0\.1:\d+;', add_header, src)

# 2. Static regex: make sure login.html / register.html are served
src = src.replace(
    r'^/(index\.html|style\.css|app\.js|favicon\.ico)$',
    r'^/(index\.html|login\.html|register\.html|style\.css|app\.js|favicon\.ico)$')

if src != orig:
    open(conf_path, 'w').write(src)
    print('  [post-update] nginx config updated (proxy key header / auth pages)')
else:
    print('  [post-update] nginx config already up to date')
PYEOF

    # --- reload nginx ---
    if nginx -t &>/dev/null; then
        systemctl reload nginx 2>/dev/null || nginx -s reload 2>/dev/null || true
        info "nginx reloaded"
    else
        warn "nginx config test failed — check: nginx -t"
    fi
}

# ============================================================
# SSH-KEY PORT FIREWALL (client onboarding)
# ============================================================
# Since v3.11 the full API is localhost-only and the SSH public key is
# served on a dedicated public port (TM_SSHKEY_PORT, default 7601). Make
# sure that port is open so new client servers can fetch the key.

open_sshkey_port() {
    local key_port
    key_port=$(_env_get TM_SSHKEY_PORT)
    key_port="${key_port:-7601}"
    [[ "${key_port}" == "0" ]] && return 0

    local bf_cmd=""
    if command -v binadit-firewall &>/dev/null; then
        bf_cmd="binadit-firewall"
    elif [[ -x /usr/local/sbin/binadit-firewall ]]; then
        bf_cmd="/usr/local/sbin/binadit-firewall"
    fi

    if [[ -n "${bf_cmd}" ]]; then
        if ! ${bf_cmd} config get TCP_PORTS 2>/dev/null | grep -qw "${key_port}"; then
            ${bf_cmd} config add TCP_PORTS "${key_port}" 2>/dev/null || true
            ${bf_cmd} restart 2>/dev/null || true
            info "Opened SSH-key port ${key_port} in binadit-firewall"
        fi
    elif command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -qi active; then
        if ! ufw status | grep -qw "${key_port}"; then
            ufw allow "${key_port}/tcp" comment "TimeMachine SSH-key" 2>/dev/null || true
            info "Opened SSH-key port ${key_port} in ufw"
        fi
    elif command -v firewall-cmd &>/dev/null && firewall-cmd --state 2>/dev/null | grep -qi running; then
        if ! firewall-cmd --list-ports 2>/dev/null | grep -qw "${key_port}/tcp"; then
            firewall-cmd --permanent --add-port="${key_port}/tcp" 2>/dev/null || true
            firewall-cmd --reload 2>/dev/null || true
            info "Opened SSH-key port ${key_port} in firewalld"
        fi
    else
        info "SSH-key endpoint on port ${key_port} — ensure this TCP port is open for client installs"
    fi
}

# ============================================================
# MAIN
# ============================================================

ensure_fido2

if [[ ${DEPS_ONLY} -eq 0 ]]; then
    # Make the SSH-key port discoverable in .env (the API defaults to 7601
    # even without it, but writing it lets users find and change it).
    if [[ -f "${ENV_FILE}" ]] && ! grep -q '^TM_SSHKEY_PORT=' "${ENV_FILE}"; then
        _upsert_env TM_SSHKEY_PORT 7601
        info "Added TM_SSHKEY_PORT=7601 to .env (public SSH-key endpoint)"
    fi

    migrate_portal_config
    open_sshkey_port

    if [[ ${NO_RESTART} -eq 0 ]] && command -v systemctl &>/dev/null && \
       systemctl is-enabled timemachine &>/dev/null; then
        systemctl restart timemachine 2>/dev/null || true
        sleep 1
        if systemctl is-active timemachine &>/dev/null; then
            info "TimeMachine service restarted"
        else
            warn "Service failed to restart — check: journalctl -u timemachine"
        fi
    fi
fi

exit 0

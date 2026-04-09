#!/bin/bash
set -euo pipefail

# ==============================================================================
# VPS Setup Script for Some Store (Medusa + Next.js Storefront)
# Run from LOCAL machine — connects to VPS via SSH as root
#
# What it does:
#   1. Creates deploy user with SSH key access
#   2. Updates system packages, installs dependencies
#   3. Installs Node.js + PM2
#   4. Installs and configures PostgreSQL (user with CREATEDB)
#   5. Installs and configures Redis (password protected)
#   6. Configures Nginx reverse proxy (API, storefront, admin)
#   7. Configures UFW firewall (SSH + Nginx)
#   8. Obtains SSL certificates via Certbot (optional)
#
# Prerequisites:
#   - Clean Ubuntu 22.04 VPS with root SSH access
#   - deploy/{prod_envs,stage_envs}/.env.setup-vps configured
#
# Usage:
#   ./deploy/setup-vps.sh <prod|stage>
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENV_ARG="${1:-}"
if [[ -z "$ENV_ARG" ]]; then
    echo -e "\033[1;31m[ERROR]\033[0m Usage: $0 <prod|stage>" >&2
    exit 1
fi

case "$ENV_ARG" in
    prod)  ENVS_DIR="prod_envs" ;;
    stage) ENVS_DIR="stage_envs" ;;
    *)
        echo -e "\033[1;31m[ERROR]\033[0m Invalid environment '$ENV_ARG'. Use 'prod' or 'stage'." >&2
        exit 1
        ;;
esac

ENV_FILE="${SCRIPT_DIR}/${ENVS_DIR}/.env.setup-vps"

# ========================= LOAD CONFIG ========================================

if [[ ! -f "$ENV_FILE" ]]; then
    echo -e "\033[1;31m[ERROR]\033[0m Config file not found: $ENV_FILE" >&2
    echo -e "\033[1;31m[ERROR]\033[0m Create it from the template in deploy/${ENVS_DIR}/" >&2
    exit 1
fi

set -a
source "$ENV_FILE"
set +a

# ==============================================================================

LOG_PREFIX="\033[1;36m[LOCAL]\033[0m"
log() { echo -e "${LOG_PREFIX} $1"; }
error() { echo -e "\033[1;31m[ERROR]\033[0m $1" >&2; exit 1; }

# --- Local pre-checks ---
[[ -z "${VPS_HOST:-}" ]] && error "VPS_HOST is not set in $ENV_FILE"
[[ -z "${STORE_DOMAIN:-}" ]] && error "STORE_DOMAIN is not set in $ENV_FILE"
[[ "${DEPLOY_PASSWORD:-}" == "change_me_deploy_password_2026" ]] && error "You must change DEPLOY_PASSWORD in $ENV_FILE"
[[ "${DB_PASSWORD:-}" == "change_me_db_password_2026" ]] && error "You must change DB_PASSWORD in $ENV_FILE"
[[ "${REDIS_PASSWORD:-}" == "change_me_redis_password_2026" ]] && error "You must change REDIS_PASSWORD in $ENV_FILE"
[[ "${API_DOMAIN:-}" == "api.yourdomain.com" ]] && error "You must set your real API_DOMAIN in $ENV_FILE"
[[ "${ADMIN_DOMAIN:-}" == "admin.yourdomain.com" ]] && error "You must set your real ADMIN_DOMAIN in $ENV_FILE"

# --- Read local public SSH key ---
LOCAL_PUBKEY_FILE="${VPS_SSH_KEY/#\~/$HOME}.pub"
if [[ -f "$LOCAL_PUBKEY_FILE" ]]; then
    AUTHORIZED_PUBLIC_KEY=$(cat "$LOCAL_PUBKEY_FILE")
    log "Found local SSH public key: ${LOCAL_PUBKEY_FILE}"
else
    AUTHORIZED_PUBLIC_KEY=""
    log "No local SSH public key found at ${LOCAL_PUBKEY_FILE}, skipping."
fi

SSH_KEY_PATH="${VPS_SSH_KEY/#\~/$HOME}"
SSH_CMD="ssh -o StrictHostKeyChecking=accept-new -i ${SSH_KEY_PATH} ${VPS_SSH_USER}@${VPS_HOST}"
SCP_CMD="scp -o StrictHostKeyChecking=accept-new -i ${SSH_KEY_PATH}"

log "Connecting to ${VPS_SSH_USER}@${VPS_HOST}..."
log "Running setup on remote VPS..."
echo ""

# ==============================================================================
# REMOTE EXECUTION — everything below runs on the VPS
# ==============================================================================

$SSH_CMD bash -s <<REMOTE_SCRIPT
set -euo pipefail

LOG_PREFIX="\033[1;36m[SETUP]\033[0m"
STEP_PREFIX="\033[1;33m[STEP]\033[0m"
SUCCESS="\033[1;32m[OK]\033[0m"
FAIL="\033[1;31m[FAIL]\033[0m"
WARN="\033[1;33m[WARN]\033[0m"

log()     { echo -e "\${LOG_PREFIX} \$1"; }
step()    { echo -e "\${STEP_PREFIX} \$1"; }
success() { echo -e "\${SUCCESS} \$1"; }
fail()    { echo -e "\${FAIL} \$1" >&2; exit 1; }
warn()    { echo -e "\${WARN} \$1"; }

# ========================= 1. DEPLOY USER =====================================
step "1/8 Creating deploy user '${DEPLOY_USER}'..."

DEPLOY_HOME="/home/${DEPLOY_USER}"
SSH_DIR="\${DEPLOY_HOME}/.ssh"

if id "${DEPLOY_USER}" &>/dev/null; then
    log "User '${DEPLOY_USER}' already exists, skipping creation."
else
    adduser --disabled-password --gecos "Deploy User" "${DEPLOY_USER}"
    echo "${DEPLOY_USER}:${DEPLOY_PASSWORD}" | chpasswd
    log "User '${DEPLOY_USER}' created."
fi

usermod -aG sudo "${DEPLOY_USER}"

# SSH access for deploy user
mkdir -p "\${SSH_DIR}"

# Authorized keys (so you can SSH as deploy from your local machine)
AUTHORIZED_FILE="\${SSH_DIR}/authorized_keys"
touch "\${AUTHORIZED_FILE}"

if [[ -f /root/.ssh/authorized_keys ]]; then
    cat /root/.ssh/authorized_keys >> "\${AUTHORIZED_FILE}"
fi

if [[ -n "${AUTHORIZED_PUBLIC_KEY}" ]]; then
    echo "${AUTHORIZED_PUBLIC_KEY}" >> "\${AUTHORIZED_FILE}"
fi

sort -u "\${AUTHORIZED_FILE}" -o "\${AUTHORIZED_FILE}"

chown -R "${DEPLOY_USER}:${DEPLOY_USER}" "\${SSH_DIR}"
chmod 700 "\${SSH_DIR}"
chmod 600 "\${AUTHORIZED_FILE}"

success "1/8 Deploy user ready."

# ========================= 2. SYSTEM UPDATE ===================================
step "2/8 Updating system packages..."

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y
apt-get install -y \
    curl \
    build-essential \
    nginx \
    certbot \
    python3-certbot-nginx \
    ufw \
    htop \
    unzip \
    software-properties-common \
    apt-transport-https \
    ca-certificates \
    gnupg \
    lsb-release

success "2/8 System updated."

# ========================= 3. NODE.JS ========================================
step "3/8 Installing Node.js ${NODE_VERSION}..."

if ! command -v node &>/dev/null || [[ ! "\$(node -v)" =~ v${NODE_VERSION} ]]; then
    curl -fsSL https://deb.nodesource.com/setup_${NODE_VERSION}.x | bash -
    apt-get install -y nodejs
fi

corepack enable
npm install -g pm2

success "3/8 Node.js \$(node -v) + PM2 installed."

# ========================= 4. POSTGRESQL ======================================
step "4/8 Installing and configuring PostgreSQL..."

if ! command -v psql &>/dev/null; then
    apt-get install -y postgresql postgresql-contrib
fi

systemctl enable postgresql
systemctl start postgresql

sudo -u postgres psql -tc "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'" | grep -q 1 || \
    sudo -u postgres psql -c "CREATE USER ${DB_USER} WITH PASSWORD '${DB_PASSWORD}' CREATEDB;"
sudo -u postgres psql -c "ALTER USER ${DB_USER} CREATEDB;" 2>/dev/null || true

PG_HBA=\$(sudo -u postgres psql -t -c "SHOW hba_file;" | xargs)
if ! grep -q "${DB_USER}" "\${PG_HBA}"; then
    sed -i "/^local.*all.*all/i local   ${DB_NAME}   ${DB_USER}   md5" "\${PG_HBA}"
    systemctl restart postgresql
fi

success "4/8 PostgreSQL configured: user=${DB_USER} (with CREATEDB)"

# ========================= 5. REDIS ==========================================
step "5/8 Installing and configuring Redis..."

if ! command -v redis-server &>/dev/null; then
    apt-get install -y redis-server
fi

sed -i "s/^# requirepass .*/requirepass ${REDIS_PASSWORD}/" /etc/redis/redis.conf
sed -i "s/^requirepass .*/requirepass ${REDIS_PASSWORD}/" /etc/redis/redis.conf
sed -i "s/^supervised .*/supervised systemd/" /etc/redis/redis.conf

systemctl enable redis-server
systemctl restart redis-server

success "5/8 Redis configured."

mkdir -p "${PROJECT_DIR}"
chown "${DEPLOY_USER}:${DEPLOY_USER}" "${PROJECT_DIR}"
log "Project directory ready at ${PROJECT_DIR}."

# ========================= 6. NGINX ==========================================
step "6/8 Configuring Nginx..."

rm -f /etc/nginx/sites-enabled/default

cat > "/etc/nginx/sites-available/${API_DOMAIN}" <<NGINXEOF
server {
    listen 80;
    server_name ${API_DOMAIN};

    client_max_body_size 50M;

    location = /app {
        return 301 https://${ADMIN_DOMAIN}/app;
    }

    location ^~ /app/ {
        return 301 https://${ADMIN_DOMAIN}\\\$request_uri;
    }

    location / {
        proxy_pass http://127.0.0.1:9000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \\\$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \\\$host;
        proxy_set_header X-Real-IP \\\$remote_addr;
        proxy_set_header X-Forwarded-For \\\$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \\\$scheme;
        proxy_cache_bypass \\\$http_upgrade;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }
}
NGINXEOF

cat > "/etc/nginx/sites-available/${STORE_DOMAIN}" <<NGINXEOF
server {
    listen 80;
    server_name ${STORE_DOMAIN};

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \\\$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \\\$host;
        proxy_set_header X-Real-IP \\\$remote_addr;
        proxy_set_header X-Forwarded-For \\\$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \\\$scheme;
        proxy_cache_bypass \\\$http_upgrade;
    }
}
NGINXEOF

cat > "/etc/nginx/sites-available/${ADMIN_DOMAIN}" <<NGINXEOF
server {
    listen 80;
    server_name ${ADMIN_DOMAIN};

    client_max_body_size 50M;

    location = / {
        return 301 https://${ADMIN_DOMAIN}/app;
    }

    location / {
        proxy_pass http://127.0.0.1:9000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \\\$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \\\$host;
        proxy_set_header X-Real-IP \\\$remote_addr;
        proxy_set_header X-Forwarded-For \\\$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \\\$scheme;
        proxy_cache_bypass \\\$http_upgrade;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }
}
NGINXEOF

ln -sf "/etc/nginx/sites-available/${API_DOMAIN}" /etc/nginx/sites-enabled/
ln -sf "/etc/nginx/sites-available/${STORE_DOMAIN}" /etc/nginx/sites-enabled/
ln -sf "/etc/nginx/sites-available/${ADMIN_DOMAIN}" /etc/nginx/sites-enabled/

nginx -t
systemctl enable nginx
systemctl restart nginx

success "6/8 Nginx configured for ${API_DOMAIN}, ${STORE_DOMAIN}, ${ADMIN_DOMAIN}."

# ========================= 7. FIREWALL =======================================
step "7/8 Configuring firewall (UFW)..."

ufw default deny incoming
ufw default allow outgoing
ufw allow OpenSSH
ufw allow 'Nginx Full'
ufw --force enable

success "7/8 Firewall enabled: SSH + Nginx allowed."

# ========================= 8. SSL ============================================
if [[ "${ENABLE_SSL}" == true ]]; then
    step "8/8 Obtaining SSL certificates..."

    certbot --nginx \
        -d "${API_DOMAIN}" \
        -d "${STORE_DOMAIN}" \
        -d "${ADMIN_DOMAIN}" \
        --non-interactive \
        --agree-tos \
        --email "${ADMIN_EMAIL}" \
        --redirect

    success "8/8 SSL certificates installed. Auto-renewal enabled."
else
    warn "8/8 Skipping SSL (ENABLE_SSL=false). Configure manually later with:"
    log "  sudo certbot --nginx -d ${API_DOMAIN} -d ${STORE_DOMAIN} -d ${ADMIN_DOMAIN}"
fi

# ========================= SUMMARY ============================================
echo ""
echo "============================================================================"
echo -e "\033[1;32m  VPS SETUP COMPLETE\033[0m"
echo "============================================================================"
echo ""
echo "  Deploy user:        ${DEPLOY_USER}"
echo "  Project directory:  ${PROJECT_DIR}"
echo "  PostgreSQL:         ${DB_NAME} (user: ${DB_USER})"
echo "  Redis:              localhost:6379 (password protected)"
echo "  Nginx:              ${API_DOMAIN} -> :9000"
echo "                      ${STORE_DOMAIN} -> :8000"
echo "                      ${ADMIN_DOMAIN} -> :9000"
echo ""
echo "============================================================================"
REMOTE_SCRIPT

#!/bin/bash
set -euo pipefail

# ==============================================================================
# Deploy Server Script (Medusa server + worker)
# Run from LOCAL machine — connects to VPS via SSH as deploy user
#
# What it does:
#   1. Builds Medusa server in Docker (Linux target)
#   2. Packages and uploads artifact to VPS
#   3. Ensures database exists, runs migrations
#   4. Generates ecosystem.server.config.js (PM2)
#   5. Starts medusa-server + medusa-worker via PM2
#
# Prerequisites:
#   - VPS provisioned via setup-vps.sh
#   - deploy/{prod_envs,stage_envs}/.env.setup-vps configured
#   - deploy/{prod_envs,stage_envs}/.env.deploy-server and .env.deploy-worker configured
#
# Usage:
#   ./deploy/deploy-server.sh <prod|stage>
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

if [[ ! -f "$ENV_FILE" ]]; then
    echo -e "\033[1;31m[ERROR]\033[0m Config file not found: $ENV_FILE" >&2
    echo -e "\033[1;31m[ERROR]\033[0m Create it from the template in deploy/${ENVS_DIR}/" >&2
    exit 1
fi

set -a
source "$ENV_FILE"
set +a

LOG_PREFIX="\033[1;36m[LOCAL]\033[0m"
log() { echo -e "${LOG_PREFIX} $1"; }
error() { echo -e "\033[1;31m[ERROR]\033[0m $1" >&2; exit 1; }

[[ -z "${VPS_HOST:-}" ]] && error "VPS_HOST is not set in $ENV_FILE"

SSH_CMD="ssh -o StrictHostKeyChecking=accept-new -i ${VPS_SSH_KEY/#\~/$HOME} ${DEPLOY_USER}@${VPS_HOST}"
SCP_CMD="scp -o StrictHostKeyChecking=accept-new -i ${VPS_SSH_KEY/#\~/$HOME}"

for cmd in docker rsync tar ssh scp; do
    command -v "$cmd" >/dev/null 2>&1 || error "Required command not found: $cmd"
done

PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
BUILD_CONTEXT_DIR="${TMP_ROOT}/workspace"
ARTIFACTS_DIR="${TMP_ROOT}/artifacts"
LOCAL_SERVER_ENV_FILE="${SCRIPT_DIR}/${ENVS_DIR}/.env.deploy-server"
LOCAL_WORKER_ENV_FILE="${SCRIPT_DIR}/${ENVS_DIR}/.env.deploy-worker"

SERVER_ARTIFACT_NAME="server-artifact.tar.gz"
SERVER_ARTIFACT_PATH="${ARTIFACTS_DIR}/${SERVER_ARTIFACT_NAME}"
SERVER_ENV_FILE_NAME=".env.deploy-server"
WORKER_ENV_FILE_NAME=".env.deploy-worker"
REMOTE_RELEASE_DIR="/tmp/some_store-release-$(date +%s)"

cleanup() {
    rm -rf "${TMP_ROOT}"
}
trap cleanup EXIT

if [[ ! -f "${LOCAL_SERVER_ENV_FILE}" ]]; then
    error "Config file not found: ${LOCAL_SERVER_ENV_FILE}. Create it in deploy/${ENVS_DIR}/"
fi

if [[ ! -f "${LOCAL_WORKER_ENV_FILE}" ]]; then
    error "Config file not found: ${LOCAL_WORKER_ENV_FILE}. Create it in deploy/${ENVS_DIR}/"
fi

log "Connecting to ${DEPLOY_USER}@${VPS_HOST}..."
log "Preparing local Linux build (server only)..."
echo ""

mkdir -p "${BUILD_CONTEXT_DIR}" "${ARTIFACTS_DIR}"

log "Preparing local build context..."
rsync -a \
    --exclude ".git" \
    --exclude "node_modules" \
    --exclude "**/node_modules" \
    --exclude "**/.next" \
    --exclude "**/.medusa" \
    --exclude ".env*" \
    --exclude "deploy/.env*" \
    "${PROJECT_ROOT}/" "${BUILD_CONTEXT_DIR}/"

log "Running Linux Docker build (server)..."
docker run --rm \
    -v "${BUILD_CONTEXT_DIR}:/workspace" \
    -w /workspace \
    node:20-bullseye \
    bash -lc '
set -euo pipefail
corepack enable
corepack prepare yarn@4.12.0 --activate

yarn --cwd /workspace/server install --immutable 2>/dev/null || yarn --cwd /workspace/server install
yarn --cwd /workspace/server build
cd /workspace/server/.medusa/server
yarn install
'

log "Packaging server artifact..."
tar -czf "${SERVER_ARTIFACT_PATH}" -C "${BUILD_CONTEXT_DIR}/server/.medusa/server" .

log "Uploading server artifact to VPS..."
$SSH_CMD "mkdir -p '${REMOTE_RELEASE_DIR}'"
$SCP_CMD "${SERVER_ARTIFACT_PATH}" "${DEPLOY_USER}@${VPS_HOST}:${REMOTE_RELEASE_DIR}/${SERVER_ARTIFACT_NAME}"
$SCP_CMD "${LOCAL_SERVER_ENV_FILE}" "${DEPLOY_USER}@${VPS_HOST}:${REMOTE_RELEASE_DIR}/${SERVER_ENV_FILE_NAME}"
$SCP_CMD "${LOCAL_WORKER_ENV_FILE}" "${DEPLOY_USER}@${VPS_HOST}:${REMOTE_RELEASE_DIR}/${WORKER_ENV_FILE_NAME}"

log "Activating server release on VPS..."
$SSH_CMD bash -s <<REMOTE_SCRIPT
set -euo pipefail

PROJECT_DIR="${PROJECT_DIR}"
REMOTE_RELEASE_DIR="${REMOTE_RELEASE_DIR}"

SERVER_DIR="\${PROJECT_DIR}/server"
SERVER_BUILD_DIR="\${SERVER_DIR}/.medusa/server"

ENV_SERVER="\${PROJECT_DIR}/.env.server"
ENV_WORKER="\${PROJECT_DIR}/.env.worker"
ENV_SERVER_SOURCE="\${REMOTE_RELEASE_DIR}/${SERVER_ENV_FILE_NAME}"
ENV_WORKER_SOURCE="\${REMOTE_RELEASE_DIR}/${WORKER_ENV_FILE_NAME}"

SERVER_ARTIFACT_NAME="${SERVER_ARTIFACT_NAME}"
SERVER_ENV_FILE_NAME="${SERVER_ENV_FILE_NAME}"
WORKER_ENV_FILE_NAME="${WORKER_ENV_FILE_NAME}"

LOG_PREFIX="\033[1;36m[DEPLOY]\033[0m"
STEP_PREFIX="\033[1;33m[STEP]\033[0m"
SUCCESS="\033[1;32m[OK]\033[0m"
FAIL="\033[1;31m[FAIL]\033[0m"
WARN="\033[1;33m[WARN]\033[0m"

log()     { echo -e "\${LOG_PREFIX} \$1"; }
step()    { echo -e "\${STEP_PREFIX} \$1"; }
success() { echo -e "\${SUCCESS} \$1"; }
fail()    { echo -e "\${FAIL} \$1" >&2; exit 1; }
warn()    { echo -e "\${WARN} \$1"; }

if [[ ! -f "\${ENV_SERVER_SOURCE}" ]]; then
    fail "Missing uploaded secrets file: \${ENV_SERVER_SOURCE}"
fi

if [[ ! -f "\${ENV_WORKER_SOURCE}" ]]; then
    fail "Missing uploaded secrets file: \${ENV_WORKER_SOURCE}"
fi

log "Generating .env.server (derived + secrets)..."
cat > "\${ENV_SERVER}" <<ENVEOF
DATABASE_URL=postgres://${DB_USER}:${DB_PASSWORD}@localhost:5432/${DB_NAME}
REDIS_URL=redis://:${REDIS_PASSWORD}@localhost:6379
STORE_CORS=https://${STORE_DOMAIN}
ADMIN_CORS=https://${ADMIN_DOMAIN}
AUTH_CORS=https://${STORE_DOMAIN},https://${API_DOMAIN},https://${ADMIN_DOMAIN}
WORKER_MODE=server
DISABLE_MEDUSA_ADMIN=false
PORT=9000
STORE_URL=https://${STORE_DOMAIN}
RESEND_FROM_EMAIL=no-reply@${STORE_DOMAIN}
DB_NAME=${DB_NAME}
MEDUSA_ADMIN_ONBOARDING_TYPE=nextjs
MEDUSA_ADMIN_ONBOARDING_NEXTJS_DIRECTORY=storefront
ENVEOF
cat "\${ENV_SERVER_SOURCE}" >> "\${ENV_SERVER}"

log "Generating .env.worker (derived + secrets)..."
cat > "\${ENV_WORKER}" <<ENVEOF
DATABASE_URL=postgres://${DB_USER}:${DB_PASSWORD}@localhost:5432/${DB_NAME}
REDIS_URL=redis://:${REDIS_PASSWORD}@localhost:6379
WORKER_MODE=worker
DISABLE_MEDUSA_ADMIN=true
PORT=9001
RESEND_FROM_EMAIL=no-reply@${STORE_DOMAIN}
ENVEOF
cat "\${ENV_WORKER_SOURCE}" >> "\${ENV_WORKER}"

step "1/5 Deploying server artifact..."
rm -rf "\${SERVER_BUILD_DIR}"
mkdir -p "\${SERVER_BUILD_DIR}"
tar -xzf "\${REMOTE_RELEASE_DIR}/\${SERVER_ARTIFACT_NAME}" -C "\${SERVER_BUILD_DIR}"
cp "\${ENV_SERVER}" "\${SERVER_BUILD_DIR}/.env"
success "1/5 Server artifact deployed."
echo ""

step "2/5 Ensuring database exists..."
cd "\${SERVER_BUILD_DIR}"
echo "${DB_NAME}" | npx medusa db:create 2>/dev/null || log "Database already exists, skipping creation."
success "2/5 Database ready."
echo ""

step "3/5 Running database migrations..."
npm run predeploy
success "3/5 Migrations completed."
echo ""

step "4/5 Configuring PM2..."

generate_env_block() {
    local envfile="\$1"
    while IFS='=' read -r key value; do
        [[ -z "\${key}" || "\${key}" =~ ^# ]] && continue
        echo "          \"\${key}\": \"\${value}\"," 
    done < "\${envfile}"
}

SERVER_ENV=\$(generate_env_block "\${ENV_SERVER}")
WORKER_ENV=\$(generate_env_block "\${ENV_WORKER}")

cat > "\${PROJECT_DIR}/ecosystem.server.config.js" <<PMEOF
module.exports = {
  apps: [
    {
      name: "medusa-server",
      cwd: "\${SERVER_BUILD_DIR}",
      script: "npm",
      args: "run start",
      env: {
          NODE_ENV: "production",
\${SERVER_ENV}
      },
    },
    {
      name: "medusa-worker",
      cwd: "\${SERVER_BUILD_DIR}",
      script: "npm",
      args: "run start",
      env: {
          NODE_ENV: "production",
\${WORKER_ENV}
      },
    },
  ],
};
PMEOF

success "4/5 PM2 config generated."
echo ""

step "5/5 Starting services..."
cd "\${PROJECT_DIR}"

pm2 delete medusa-server 2>/dev/null || true
pm2 delete medusa-worker 2>/dev/null || true
pm2 start ecosystem.server.config.js

pm2 save
log "Waiting for server to become ready..."
MAX_RETRIES=30
RETRY=0
until curl -sf http://localhost:9000/health > /dev/null 2>&1; do
    RETRY=\$((RETRY + 1))
    if [[ \${RETRY} -ge \${MAX_RETRIES} ]]; then
        warn "Medusa server did not start within \$((MAX_RETRIES * 3)) seconds"
        break
    fi
    sleep 3
done

if curl -sf http://localhost:9000/health > /dev/null 2>&1; then
    success "5/5 Medusa server: healthy"
else
    warn "Medusa server not responding yet (may still be starting)"
fi

rm -rf "\${REMOTE_RELEASE_DIR}"

echo ""
echo "============================================================================"
echo -e "\033[1;32m  SERVER DEPLOY COMPLETE\033[0m"
echo "============================================================================"
echo ""
pm2 status
echo ""
REMOTE_SCRIPT

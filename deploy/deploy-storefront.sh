#!/bin/bash
set -euo pipefail

# ==============================================================================
# Deploy Storefront Script (Next.js storefront)
# Run from LOCAL machine — connects to VPS via SSH as deploy user
#
# What it does:
#   1. Checks Medusa API availability (required for build)
#   2. Builds Next.js storefront in Docker (Linux target, standalone output)
#   3. Packages standalone + static + public into artifact
#   4. Uploads and deploys artifact to VPS
#   5. Generates ecosystem.storefront.config.js (PM2)
#   6. Starts storefront via PM2
#
# Prerequisites:
#   - VPS provisioned via setup-vps.sh
#   - Medusa server deployed and running (deploy-server.sh)
#   - deploy/{prod_envs,stage_envs}/.env.setup-vps and .env.deploy-storefront configured
#
# Usage:
#   ./deploy/deploy-storefront.sh <prod|stage>
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
[[ -z "${API_DOMAIN:-}" ]] && error "API_DOMAIN is not set in $ENV_FILE"
[[ -z "${STORE_DOMAIN:-}" ]] && error "STORE_DOMAIN is not set in $ENV_FILE"

SSH_CMD="ssh -o StrictHostKeyChecking=accept-new -i ${VPS_SSH_KEY/#\~/$HOME} ${DEPLOY_USER}@${VPS_HOST}"
SCP_CMD="scp -o StrictHostKeyChecking=accept-new -i ${VPS_SSH_KEY/#\~/$HOME}"

for cmd in docker rsync tar ssh scp curl; do
    command -v "$cmd" >/dev/null 2>&1 || error "Required command not found: $cmd"
done

PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
BUILD_CONTEXT_DIR="${TMP_ROOT}/workspace"
ARTIFACTS_DIR="${TMP_ROOT}/artifacts"
STOREFRONT_STAGE_DIR="${TMP_ROOT}/storefront-stage"
LOCAL_STOREFRONT_ENV_FILE="${SCRIPT_DIR}/${ENVS_DIR}/.env.deploy-storefront"

STOREFRONT_ARTIFACT_NAME="storefront-artifact.tar.gz"
STOREFRONT_ARTIFACT_PATH="${ARTIFACTS_DIR}/${STOREFRONT_ARTIFACT_NAME}"
STOREFRONT_ENV_FILE_NAME=".env.deploy-storefront"
REMOTE_RELEASE_DIR="/tmp/some_store-release-$(date +%s)"

cleanup() {
    rm -rf "${TMP_ROOT}"
}
trap cleanup EXIT

if [[ ! -f "${LOCAL_STOREFRONT_ENV_FILE}" ]]; then
    error "Config file not found: ${LOCAL_STOREFRONT_ENV_FILE}. Create it in deploy/${ENVS_DIR}/"
fi

log "Connecting to ${DEPLOY_USER}@${VPS_HOST}..."
log "Checking Medusa API availability before storefront build..."

if ! curl -fsS "https://${API_DOMAIN}/health" >/dev/null; then
    error "Medusa API is not available at https://${API_DOMAIN}/health. Aborting storefront build."
fi

log "Medusa API is available. Preparing local Linux build (storefront only)..."
echo ""

mkdir -p "${BUILD_CONTEXT_DIR}" "${ARTIFACTS_DIR}" "${STOREFRONT_STAGE_DIR}"

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

log "Running Linux Docker build (storefront)..."
docker run --rm \
    --env-file "${LOCAL_STOREFRONT_ENV_FILE}" \
    -e MEDUSA_BACKEND_URL="https://${API_DOMAIN}" \
    -e NEXT_PUBLIC_BASE_URL="https://${STORE_DOMAIN}" \
    -v "${BUILD_CONTEXT_DIR}:/workspace" \
    -w /workspace \
    node:20-bullseye \
    bash -lc '
set -euo pipefail
corepack enable
corepack prepare yarn@4.12.0 --activate

cd /workspace

yarn --cwd /workspace/storefront install --immutable 2>/dev/null || yarn --cwd /workspace/storefront install
cd /workspace/storefront
NODE_OPTIONS="--max-old-space-size=1536" yarn build
'

log "Packaging storefront artifact..."
STANDALONE_DIR="${BUILD_CONTEXT_DIR}/storefront/.next/standalone"
cp -R "${BUILD_CONTEXT_DIR}/storefront/.next/static" "${STANDALONE_DIR}/.next/"
if [[ -d "${BUILD_CONTEXT_DIR}/storefront/public" ]]; then
    cp -R "${BUILD_CONTEXT_DIR}/storefront/public" "${STANDALONE_DIR}/"
fi
tar -czf "${STOREFRONT_ARTIFACT_PATH}" -C "${STANDALONE_DIR}" .

log "Uploading storefront artifact to VPS..."
$SSH_CMD "mkdir -p '${REMOTE_RELEASE_DIR}'"
$SCP_CMD "${STOREFRONT_ARTIFACT_PATH}" "${DEPLOY_USER}@${VPS_HOST}:${REMOTE_RELEASE_DIR}/${STOREFRONT_ARTIFACT_NAME}"
$SCP_CMD "${LOCAL_STOREFRONT_ENV_FILE}" "${DEPLOY_USER}@${VPS_HOST}:${REMOTE_RELEASE_DIR}/${STOREFRONT_ENV_FILE_NAME}"

log "Activating storefront release on VPS..."
$SSH_CMD bash -s <<REMOTE_SCRIPT
set -euo pipefail

PROJECT_DIR="${PROJECT_DIR}"
REMOTE_RELEASE_DIR="${REMOTE_RELEASE_DIR}"

STOREFRONT_DIR="\${PROJECT_DIR}/storefront"
ENV_STOREFRONT="\${PROJECT_DIR}/.env.storefront"
ENV_STOREFRONT_SOURCE="\${REMOTE_RELEASE_DIR}/${STOREFRONT_ENV_FILE_NAME}"

STOREFRONT_ARTIFACT_NAME="${STOREFRONT_ARTIFACT_NAME}"
STOREFRONT_ENV_FILE_NAME="${STOREFRONT_ENV_FILE_NAME}"

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

if [[ ! -f "\${ENV_STOREFRONT_SOURCE}" ]]; then
    fail "Missing uploaded secrets file: \${ENV_STOREFRONT_SOURCE}"
fi

log "Generating .env.storefront (derived + secrets)..."
cat > "\${ENV_STOREFRONT}" <<ENVEOF
MEDUSA_BACKEND_URL=https://${API_DOMAIN}
NEXT_PUBLIC_BASE_URL=https://${STORE_DOMAIN}
ENVEOF
cat "\${ENV_STOREFRONT_SOURCE}" >> "\${ENV_STOREFRONT}"

step "1/3 Deploying storefront artifact..."
rm -rf "\${STOREFRONT_DIR}"
mkdir -p "\${STOREFRONT_DIR}"
tar -xzf "\${REMOTE_RELEASE_DIR}/\${STOREFRONT_ARTIFACT_NAME}" -C "\${STOREFRONT_DIR}"
success "1/3 Storefront artifact deployed."
echo ""

step "2/3 Configuring PM2..."

generate_env_block() {
    local envfile="\$1"
    while IFS='=' read -r key value; do
        [[ -z "\${key}" || "\${key}" =~ ^# ]] && continue
        echo "          \"\${key}\": \"\${value}\"," 
    done < "\${envfile}"
}

STOREFRONT_ENV=\$(generate_env_block "\${ENV_STOREFRONT}")

cat > "\${PROJECT_DIR}/ecosystem.storefront.config.js" <<PMEOF
module.exports = {
  apps: [
    {
      name: "storefront",
      cwd: "\${STOREFRONT_DIR}",
      script: "server.js",
      env: {
          NODE_ENV: "production",
          PORT: "8000",
\${STOREFRONT_ENV}
      },
    },
  ],
};
PMEOF

success "2/3 PM2 config generated."
echo ""

step "3/3 Starting storefront..."
cd "\${PROJECT_DIR}"

pm2 delete storefront 2>/dev/null || true
pm2 start ecosystem.storefront.config.js

pm2 save
log "Waiting for storefront to become ready..."
MAX_RETRIES=30
RETRY=0
until curl -sf http://localhost:8000 > /dev/null 2>&1; do
    RETRY=\$((RETRY + 1))
    if [[ \${RETRY} -ge \${MAX_RETRIES} ]]; then
        warn "Storefront did not start within \$((MAX_RETRIES * 3)) seconds"
        break
    fi
    sleep 3
done

if curl -sf http://localhost:8000 > /dev/null 2>&1; then
    success "3/3 Storefront: healthy"
else
    warn "Storefront not responding yet (may still be starting)"
fi

rm -rf "\${REMOTE_RELEASE_DIR}"

echo ""
echo "============================================================================"
echo -e "\033[1;32m  STOREFRONT DEPLOY COMPLETE\033[0m"
echo "============================================================================"
echo ""
pm2 status
echo ""
REMOTE_SCRIPT

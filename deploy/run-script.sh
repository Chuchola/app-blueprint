#!/bin/bash
set -euo pipefail

# ==============================================================================
# Run Script — compile a local server/src/scripts/*.ts and execute on remote VPS
# Run from LOCAL machine — connects to VPS via SSH as deploy user
#
# What it does:
#   1. Compiles local .ts → .js using the server's TypeScript toolchain
#   2. Uploads compiled .js to VPS into the server build's src/scripts/
#   3. Ensures Medusa server is running (health check)
#   4. Runs the script via `npx medusa exec`
#
# Prerequisites:
#   - VPS provisioned via setup-vps.sh
#   - Server deployed via deploy-server.sh
#   - deploy/{prod_envs,stage_envs}/.env.setup-vps configured
#   - Server dependencies installed (yarn install in server/)
#
# Usage:
#   ./deploy/run-script.sh <prod|stage> <script-name> [args...]
#
# Examples:
#   ./deploy/run-script.sh stage add-brand
#   ./deploy/run-script.sh prod seed-admin-user
#   ./deploy/run-script.sh stage my-script arg1 arg2
#
# The script-name corresponds to a file in server/src/scripts/<name>.ts
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENV_ARG="${1:-}"
SCRIPT_NAME="${2:-}"

if [[ -z "$ENV_ARG" || -z "$SCRIPT_NAME" ]]; then
    echo -e "\033[1;31m[ERROR]\033[0m Usage: $0 <prod|stage> <script-name> [args...]" >&2
    echo -e "\033[1;31m[ERROR]\033[0m Example: $0 stage add-brand" >&2
    echo -e "\033[1;31m[ERROR]\033[0m Example: $0 prod seed-admin-user" >&2
    exit 1
fi

shift 2
SCRIPT_ARGS="${*:-}"

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

# --- Check local script exists ---
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SERVER_DIR="${PROJECT_ROOT}/server"
LOCAL_SCRIPT="${SERVER_DIR}/src/scripts/${SCRIPT_NAME}.ts"

if [[ ! -f "$LOCAL_SCRIPT" ]]; then
    error "Local script not found: ${LOCAL_SCRIPT}"
fi

# --- Pre-checks ---
[[ -z "${VPS_HOST:-}" ]] && error "VPS_HOST is not set in $ENV_FILE"
[[ -z "${DEPLOY_USER:-}" ]] && error "DEPLOY_USER is not set in $ENV_FILE"
[[ -z "${VPS_SSH_KEY:-}" ]] && error "VPS_SSH_KEY is not set in $ENV_FILE"
[[ -z "${PROJECT_DIR:-}" ]] && error "PROJECT_DIR is not set in $ENV_FILE"

SSH_KEY_PATH="${VPS_SSH_KEY/#\~/$HOME}"
SSH_CMD="ssh -o StrictHostKeyChecking=accept-new -i ${SSH_KEY_PATH} ${DEPLOY_USER}@${VPS_HOST}"
SCP_CMD="scp -o StrictHostKeyChecking=accept-new -i ${SSH_KEY_PATH}"

if [[ ! -f "$SSH_KEY_PATH" ]]; then
    error "SSH key not found: $SSH_KEY_PATH"
fi

log "Local script: ${LOCAL_SCRIPT}"
log "Target: ${DEPLOY_USER}@${VPS_HOST}"
log "Script: ${SCRIPT_NAME}"
[[ -n "${SCRIPT_ARGS}" ]] && log "Args: ${SCRIPT_ARGS}"
echo ""

# ========================= COMPILE LOCALLY ====================================

COMPILED_DIR="$(mktemp -d)"
trap 'rm -rf "${COMPILED_DIR}"' EXIT

log "Compiling ${SCRIPT_NAME}.ts → .js..."

yarn --cwd "${SERVER_DIR}" tsc \
    --outDir "${COMPILED_DIR}" \
    --rootDir "${SERVER_DIR}" \
    --module Node16 \
    --moduleResolution Node16 \
    --target ES2021 \
    --esModuleInterop \
    --skipLibCheck \
    --declaration false \
    --sourceMap false \
    "${LOCAL_SCRIPT}"

COMPILED_JS="${COMPILED_DIR}/src/scripts/${SCRIPT_NAME}.js"

if [[ ! -f "$COMPILED_JS" ]]; then
    error "Compilation produced no output: ${COMPILED_JS}"
fi

success() { echo -e "\033[1;32m[OK]\033[0m $1"; }
success "Compiled successfully."
echo ""

# ========================= UPLOAD TO VPS ======================================

log "Uploading ${SCRIPT_NAME}.js to VPS..."
$SCP_CMD "$COMPILED_JS" "${DEPLOY_USER}@${VPS_HOST}:/tmp/${SCRIPT_NAME}.js"
log "Upload complete."
echo ""

# ==============================================================================
# REMOTE EXECUTION — everything below runs on the VPS
# ==============================================================================

$SSH_CMD bash -s <<REMOTE_SCRIPT
set -euo pipefail

LOG_PREFIX="\033[1;36m[RUN]\033[0m"
STEP_PREFIX="\033[1;33m[STEP]\033[0m"
SUCCESS="\033[1;32m[OK]\033[0m"
FAIL="\033[1;31m[FAIL]\033[0m"

log()     { echo -e "\${LOG_PREFIX} \$1"; }
step()    { echo -e "\${STEP_PREFIX} \$1"; }
success() { echo -e "\${SUCCESS} \$1"; }
fail()    { echo -e "\${FAIL} \$1" >&2; exit 1; }

PROJECT_DIR="${PROJECT_DIR}"
SERVER_BUILD_DIR="\${PROJECT_DIR}/server/.medusa/server"
SCRIPT_NAME="${SCRIPT_NAME}"
SCRIPT_ARGS="${SCRIPT_ARGS}"

if [[ ! -d "\${SERVER_BUILD_DIR}" ]]; then
    fail "Server build directory not found: \${SERVER_BUILD_DIR}. Deploy the server first."
fi

mkdir -p "\${SERVER_BUILD_DIR}/src/scripts"
cp "/tmp/\${SCRIPT_NAME}.js" "\${SERVER_BUILD_DIR}/src/scripts/\${SCRIPT_NAME}.js"
rm -f "/tmp/\${SCRIPT_NAME}.js"

step "1/2 Checking Medusa server..."
if ! curl -sf http://127.0.0.1:9000/health > /dev/null 2>&1; then
    log "Server not running. Starting medusa-server..."
    pm2 start "\${PROJECT_DIR}/ecosystem.server.config.js" --only medusa-server 2>/dev/null || \
    pm2 restart medusa-server 2>/dev/null || \
    fail "Could not start medusa-server"

    MAX_RETRIES=30
    RETRY=0
    until curl -sf http://127.0.0.1:9000/health > /dev/null 2>&1; do
        RETRY=\$((RETRY + 1))
        if [[ \${RETRY} -ge \${MAX_RETRIES} ]]; then
            fail "Medusa server did not start within \$((MAX_RETRIES * 3)) seconds"
        fi
        sleep 3
    done
fi
success "1/2 Medusa server is running."
echo ""

step "2/2 Running script: \${SCRIPT_NAME}..."
echo ""

cd "\${SERVER_BUILD_DIR}"

if [[ -n "\${SCRIPT_ARGS}" ]]; then
    npx medusa exec "\${SERVER_BUILD_DIR}/src/scripts/\${SCRIPT_NAME}.js" \${SCRIPT_ARGS}
else
    npx medusa exec "\${SERVER_BUILD_DIR}/src/scripts/\${SCRIPT_NAME}.js"
fi

echo ""
success "Script '\${SCRIPT_NAME}' completed successfully."
REMOTE_SCRIPT

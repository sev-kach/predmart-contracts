#!/bin/bash
# contracts/deploy.sh
# Wrapper script for forge deployments - loads env from project/ directory
#
# Usage:
#   ./deploy.sh testnet deployLendingPool  # Deploy lending pool on Polygon Amoy
#   ./deploy.sh mainnet deployLendingPool  # Deploy lending pool on Polygon Mainnet
#   ./deploy.sh testnet deployMocks        # Deploy mock USDC + CTF on testnet
#   ./deploy.sh mainnet upgradeToV8        # Upgrade to v0.8.0 with meta-transaction relayer
#   ./deploy.sh mainnet upgradePool        # Generic upgrade (no reinit)
#   ./deploy.sh testnet showAddresses      # Show configured addresses
#   ./deploy.sh mainnet verify <ADDRESS>   # Retry verification for an already-deployed impl
#
# NOTE: Do NOT create a .env file in this contracts/ directory.
#       All env variables come from project/.env.* files (single source of truth).
#
# VERIFICATION NOTES:
#   - foundry.toml MUST use solc >= 0.8.27 for via_ir verification to work.
#     Solc 0.8.24 has a non-determinism bug in the via_ir Yul pipeline where AST IDs
#     affect generated identifiers, causing bytecode mismatch on Polygonscan.
#     Fixed in solc 0.8.27 (deterministic Yul subobject order).
#   - deploy.sh always runs `forge clean` before deployment to avoid stale artifacts.
#   - If verification fails, use: ./deploy.sh mainnet verify <IMPL_ADDRESS>
#     This retries verification without redeploying (no gas cost).
#   - Build artifacts are cached in deploy_cache/ after each deployment for retry.
#
# UPGRADE CHECKLIST (when user says "upgrade now"):
#   1. Run upgrade on BOTH testnet and mainnet
#   2. Verify on Polygonscan (mainnet auto-verifies via --verify flag)
#   3. Update backend ABI:  copy compiled out/PredmartLendingPool.sol/PredmartLendingPool.json
#      -> extract "abi" array -> write to project/blockchain/lending_pool_abi.json
#   4. Update frontend ABI: add new functions/errors/events to
#      predmart-frontend/src/contracts/lendingPool.js
#   5. Redeploy backend + frontend after ABI updates

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")/project"
CACHE_DIR="$SCRIPT_DIR/deploy_cache"

# Validate args
if [ $# -lt 2 ]; then
    echo "Usage: $0 <network> <function> [args...]"
    echo "  network: testnet or mainnet"
    echo "  function: deployLendingPool, upgradePool, showAddresses, verify <address>, etc."
    exit 1
fi

NETWORK=$1
FUNCTION=$2
shift 2

# Map network to forge rpc name
case $NETWORK in
    testnet)
        RPC_NAME="polygon_amoy"
        ;;
    mainnet)
        RPC_NAME="polygon_mainnet"
        ;;
    *)
        echo "Error: Unknown network '$NETWORK'. Use 'testnet' or 'mainnet'."
        exit 1
        ;;
esac

# Helper to extract env value (handles unquoted values with special chars)
get_env_value() {
    local file=$1
    local key=$2
    grep "^${key}=" "$file" 2>/dev/null | head -1 | cut -d'=' -f2-
}

# All env variables come from project/.env (single source of truth)
ENV_FILE="$PROJECT_DIR/.env"

# Load variables from env
export ADMIN_WALLET_PRIVATE_KEY=$(get_env_value "$ENV_FILE" "ADMIN_WALLET_PRIVATE_KEY")
export POLYGONSCAN_API_KEY=$(get_env_value "$ENV_FILE" "POLYGONSCAN_API_KEY")
export PLATFORM_WALLET=$(get_env_value "$ENV_FILE" "PLATFORM_WALLET")

# Load RPC_URLS from env
RPC_URLS=$(get_env_value "$ENV_FILE" "RPC_URLS")

if [ "$NETWORK" = "testnet" ]; then
    FIRST_RPC=$(get_env_value "$ENV_FILE" "AMOY_RPC_URL")
    if [ -z "$FIRST_RPC" ]; then echo "Error: AMOY_RPC_URL not found in $ENV_FILE"; exit 1; fi
    export POLYGON_AMOY_RPC_URL="$FIRST_RPC"
    # Load mock token addresses from env file (set after deployMocks)
    export MOCK_USDC="${MOCK_USDC:-$(get_env_value "$ENV_FILE" "MOCK_USDC")}"
    export MOCK_CTF="${MOCK_CTF:-$(get_env_value "$ENV_FILE" "MOCK_CTF")}"
else
    RPC_URLS=$(get_env_value "$ENV_FILE" "RPC_URLS")
    if [ -z "$RPC_URLS" ]; then echo "Error: RPC_URLS not found in $ENV_FILE"; exit 1; fi
    IFS=',' read -ra RPC_ARRAY <<< "$RPC_URLS"
    FIRST_RPC="${RPC_ARRAY[0]}"
    export POLYGON_MAINNET_RPC_URL="$FIRST_RPC"
fi

echo "========================================"
echo "PredMart Contract Deployment"
echo "========================================"
echo "Network: $NETWORK ($RPC_NAME)"
echo "RPC URL: $FIRST_RPC"
echo "Function: $FUNCTION"
echo "========================================"
echo ""

cd "$SCRIPT_DIR"

# ─── Special case: retry verification without redeploying (no gas cost) ───
if [ "$FUNCTION" = "verify" ]; then
    ADDRESS=$1
    if [ -z "$ADDRESS" ]; then
        echo "Error: Usage: $0 $NETWORK verify <CONTRACT_ADDRESS>"
        exit 1
    fi

    # Restore cached build artifacts if available
    if [ -d "$CACHE_DIR/out" ]; then
        echo "Restoring cached build artifacts from deploy_cache/..."
        cp -r "$CACHE_DIR/out" "$SCRIPT_DIR/out"
    else
        echo "No cached build — building from source..."
        forge clean
        forge build
    fi

    echo "Retrying verification for $ADDRESS (no gas cost)..."
    forge verify-contract "$ADDRESS" \
        src/PredmartLendingPool.sol:PredmartLendingPool \
        --chain polygon \
        --etherscan-api-key "$POLYGONSCAN_API_KEY" \
        --watch
    exit $?
fi

# Clean stale artifacts before deploying — via_ir metadata includes file paths,
# so deleted source files in out/ cause bytecode mismatch on Polygonscan verification.
# CRITICAL: solc must be >= 0.8.27 for deterministic via_ir output.
if [[ "$FUNCTION" != "showAddresses" ]]; then
    echo "Cleaning build artifacts..."
    forge clean
fi

# Build command
CMD="forge script script/Deploy.s.sol --sig \"${FUNCTION}($*)\" --rpc-url $RPC_NAME --broadcast"

# Add --verify only for mainnet deployments (skip for testnet and read-only functions)
if [[ "$NETWORK" = "mainnet" && "$FUNCTION" != "showAddresses" ]]; then
    CMD="$CMD --verify"
fi

echo "Running: $CMD"
echo ""

eval $CMD
DEPLOY_EXIT=$?

# Cache build artifacts after deployment so verification can be retried without gas
if [[ "$FUNCTION" != "showAddresses" ]]; then
    mkdir -p "$CACHE_DIR"
    cp -r "$SCRIPT_DIR/out" "$CACHE_DIR/out"
    echo ""
    echo "Build artifacts cached in deploy_cache/ for verification retry."
    echo "If verification failed, retry with: ./deploy.sh $NETWORK verify <ADDRESS>"
fi

exit $DEPLOY_EXIT

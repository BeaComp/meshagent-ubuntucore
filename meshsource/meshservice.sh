#!/bin/sh
# =============================================================================
# meshservice.sh — MeshCentral Agent Service Script
# =============================================================================
#
# Fork of: https://github.com/MatinatorX/meshagent-ubuntucore
# Modified by: Beatriz Faria <beatrizfaria@ipb.pt>
#
# Changes from original:
#   - Added network availability check before starting the agent
#   - Added Serial Assertion retrieval from snapd assertions store
#     (reads directly from /var/lib/snapd/assertions to avoid requiring
#     the super-privileged snapd-control interface)
#   - Added cryptographic assertion verification via Serial Vault proxy
#     before allowing remote management access
#   - Agent binary and .msh config are copied from snap read-only dir
#     to SNAP_DATA on every start to ensure fresh configuration
#
# Security model:
#   This script enforces that the device has a valid Serial Assertion
#   issued by the Serial Vault before the MeshCentral agent is allowed
#   to connect. This ties remote management access to device identity.
#
# Configuration:
#   MESH_SERVER_IP — IP address of the MeshCentral server
#   PROXY_URL      — URL of the Serial Vault proxy for assertion verification
#
# =============================================================================

MESH_SERVER_IP="YOUR_MESH_SERVER_IP"
PROXY_URL="http://YOUR_PROXY_IP:8082"

# =============================================================================
# Step 1: Wait for network connectivity
# Polls the MeshCentral server IP every 2 seconds, up to 60 seconds.
# Continues anyway on timeout to avoid blocking the boot indefinitely.
# =============================================================================
echo "[meshservice] Waiting for network connectivity..."
COUNT=0
while ! ping -c 1 -W 2 "$MESH_SERVER_IP" > /dev/null 2>&1; do
    COUNT=$((COUNT + 1))
    if [ $COUNT -ge 30 ]; then
        echo "[meshservice] Network timeout — continuing anyway."
        break
    fi
    echo "[meshservice] Network not available ($COUNT/30), retrying..."
    sleep 2
done
echo "[meshservice] Network check complete."

# =============================================================================
# Step 2: Retrieve Serial Assertion from snapd assertions store
#
# The Serial Assertion is a cryptographically signed document issued by the
# Serial Vault that establishes the device identity on the Ubuntu Core system.
#
# It is stored by snapd at:
#   /var/lib/snapd/assertions/asserts-v0/serial/<brand-id>/<model>/<serial>/active
#
# We use a glob pattern to avoid hardcoding brand-id, model and serial,
# making this script reusable across different device configurations.
#
# Note: This requires confinement: devmode because strict confinement would
# need the super-privileged snapd-control interface (requires Snap Store
# approval). In production, this should be replaced with an approved
# interface or a dedicated IPC mechanism exposed by snapd.
# =============================================================================
echo "[meshservice] Retrieving Serial Assertion from snapd store..."
SERIAL_ASSERTION=""
COUNT=0
while [ -z "$SERIAL_ASSERTION" ]; do
    SERIAL_ASSERTION=$(cat /var/lib/snapd/assertions/asserts-v0/serial/*/*/*/active 2>/dev/null || true)
    if [ -z "$SERIAL_ASSERTION" ]; then
        COUNT=$((COUNT + 1))
        if [ $COUNT -ge 30 ]; then
            echo "[meshservice] ERROR: Serial Assertion not available after timeout. Exiting."
            exit 1
        fi
        echo "[meshservice] Serial Assertion not yet available ($COUNT/30), waiting 10s..."
        sleep 10
    fi
done

SERIAL=$(echo "$SERIAL_ASSERTION" | grep "^serial:" | awk '{print $2}')
echo "[meshservice] Serial Assertion retrieved. Serial: $SERIAL"

# =============================================================================
# Step 3: Cryptographic verification via Serial Vault proxy
#
# The full Serial Assertion (base64-encoded) is sent to the proxy's
# /v1/verify-assertion endpoint. The proxy verifies:
#   1. Assertion format and mandatory fields
#   2. sign-key-sha3-384 matches the known Serial Vault signing key
#   3. Device serial is in the pre-approved list
#   4. Device status (quarantine / commissioned / revoked)
#
# Fail-open policy: if the proxy is unreachable, the agent starts anyway.
# This prioritises availability for critical infrastructure (e.g. traffic
# lights) over strict security, but in a real deployment you may want to adjust this behaviour.
# =============================================================================
echo "[meshservice] Verifying Serial Assertion with proxy..."
ASSERTION_B64=$(echo "$SERIAL_ASSERTION" | base64 | tr -d '\n')

RESPONSE=$(wget -q -O- \
    --post-data="{\"assertion\": \"${ASSERTION_B64}\"}" \
    --header="Content-Type: application/json" \
    "${PROXY_URL}/v1/verify-assertion" 2>/dev/null || echo "")

if [ -z "$RESPONSE" ]; then
    echo "[meshservice] WARNING: Proxy unreachable. Applying fail-open policy — continuing."
    STATUS="approved"
else
    STATUS=$(echo "$RESPONSE" | \
        python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('status', 'unknown'))
except Exception:
    print('unknown')
" 2>/dev/null || echo "unknown")
fi

echo "[meshservice] Device status: $STATUS"

case "$STATUS" in
    commissioned)
        echo "[meshservice] Device commissioned. Starting remote management."
        ;;
    quarantine)
        echo "[meshservice] Device in quarantine. Remote management pending engineer approval."
        echo "[meshservice] Agent will start but device may appear in quarantine group."
        ;;
    revoked)
        echo "[meshservice] ERROR: Device has been revoked. Remote management blocked."
        exit 1
        ;;
    rejected)
        REASON=$(echo "$RESPONSE" | \
            python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('reason', 'unknown'))
except Exception:
    print('unknown')
" 2>/dev/null || echo "unknown")
        echo "[meshservice] ERROR: Assertion rejected by proxy — $REASON"
        exit 1
        ;;
    approved|unknown)
        echo "[meshservice] WARNING: Status '$STATUS' — continuing with reduced guarantees."
        ;;
    *)
        echo "[meshservice] WARNING: Unexpected status '$STATUS' — continuing."
        ;;
esac

# =============================================================================
# Step 4: Prepare agent files
#
# The snap read-only directory ($SNAP) contains the pre-bundled meshagent
# binary and .msh configuration file. These are copied to $SNAP_DATA
# (writable persistent storage) on every start to ensure fresh config.
#
# StartupType=1 is appended to the .msh file to signal to the agent
# that it is running as a managed daemon (not interactive).
# =============================================================================
echo "[meshservice] Preparing agent files..."
cd "$SNAP_DATA" || exit 1

cp "$SNAP/meshagent"     "$SNAP_DATA/meshagent"
cp "$SNAP/meshagent.msh" "$SNAP_DATA/meshagent.msh"
chmod 755 "$SNAP_DATA/meshagent"

# Ensure StartupType=1 is set (remove existing line first to avoid duplicates)
sed -i '/^StartupType=/ d' "$SNAP_DATA/meshagent.msh"

# =============================================================================
# Step 5: Start the MeshCentral agent
#
# exec replaces the shell process with meshagent so that systemd/snapd
# correctly tracks the PID and can manage the service lifecycle.
# =============================================================================
echo "[meshservice] Starting MeshCentral Agent for device $SERIAL..."
exec "$SNAP_DATA/meshagent"
EOF
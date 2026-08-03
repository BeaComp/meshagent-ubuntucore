#!/bin/sh
# =============================================================================
# meshservice.sh — MeshCentral Agent Service Script
# =============================================================================
#
# The meshagent binary and meshagent.msh are NOT bundled in this snap.
# They are provided at runtime by the gadget snap via the content interface
# (slot: meshagent-bin), which exposes:
#   $SNAP/gadget-bin/meshagent      — the agent binary
#   $SNAP/gadget-bin/meshagent.msh  — the agent configuration
#
# =============================================================================

GADGET_BIN="$SNAP/gadget-bin"
GADGET_DIRECT="/snap/pi/current/meshagent-bin"

# =============================================================================
# Step 0: Waiting serial assertion (commissioning)
# =============================================================================
echo "Waiting serial assertion..."
SERIAL_ASSERTION=""
COUNT=0
while [ -z "$SERIAL_ASSERTION" ]; do
    SERIAL_ASSERTION=$(snap known serial 2>/dev/null)
    if [ -z "$SERIAL_ASSERTION" ]; then
        COUNT=$((COUNT + 1))
        [ $COUNT -ge 6 ] && { echo "Serial Assertion ainda indisponível — o systemd irá reiniciar."; exit 1; }
        echo "Serial Assertion não disponível ($COUNT/6)..."
        sleep 10
    fi
done

# =============================================================================
# Step 1: Locate binary from gadget snap
# Preferred: content interface ($SNAP/gadget-bin) — active when plug is connected
# Fallback:  direct path (/snap/pi/current) — works in devmode when plug is not
#            auto-connected due to missing snap-declaration policy
# =============================================================================
if [ -f "$GADGET_BIN/meshagent" ] && [ -x "$GADGET_BIN/meshagent" ]; then
    echo "[meshservice] Using content interface: $GADGET_BIN"
    MESHAGENT_BIN="$GADGET_BIN/meshagent"
    MESHAGENT_MSH="$GADGET_BIN/meshagent.msh"
elif [ -f "$GADGET_DIRECT/meshagent" ] && [ -x "$GADGET_DIRECT/meshagent" ]; then
    echo "[meshservice] Content interface not connected — using direct gadget path (devmode)"
    MESHAGENT_BIN="$GADGET_DIRECT/meshagent"
    MESHAGENT_MSH="$GADGET_DIRECT/meshagent.msh"
else
    echo "[meshservice] ERROR: meshagent binary not found."
    echo "[meshservice]   Tried: $GADGET_BIN/meshagent"
    echo "[meshservice]   Tried: $GADGET_DIRECT/meshagent"
    exit 1
fi

# =============================================================================
# Step 2: Wait for network connectivity
# =============================================================================
MESH_HOST=$(grep "^MeshServer=" "$MESHAGENT_MSH" | sed 's|^MeshServer=||' | sed 's|wss\?://||' | cut -d/ -f1 | cut -d: -f1)

echo "[meshservice] Waiting for network connectivity ($MESH_HOST)..."
COUNT=0
while ! ping -c 1 -W 2 "$MESH_HOST" > /dev/null 2>&1; do
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
# Step 3: Prepare agent files
# =============================================================================
echo "[meshservice] Preparing agent files..."
cd "$SNAP_DATA" || exit 1

cp "$MESHAGENT_BIN" "$SNAP_DATA/meshagent"
chmod 755 "$SNAP_DATA/meshagent"

# Use .msh from gadget if available; otherwise keep existing SNAP_DATA/.msh
if [ -f "$MESHAGENT_MSH" ]; then
    NEW_MSH=$(cat "$MESHAGENT_MSH")
    OLD_MSH=$(cat "$SNAP_DATA/meshagent.msh" 2>/dev/null || true)
    if [ "$NEW_MSH" != "$OLD_MSH" ]; then
        echo "[meshservice] Config changed — deleting meshagent.db"
        rm -f "$SNAP_DATA/meshagent.db"
    fi
    cp "$MESHAGENT_MSH" "$SNAP_DATA/meshagent.msh"
elif [ ! -f "$SNAP_DATA/meshagent.msh" ]; then
    echo "[meshservice] ERROR: no meshagent.msh found in gadget slot or SNAP_DATA."
    exit 1
else
    echo "[meshservice] Using existing meshagent.msh from SNAP_DATA."
fi

echo "[meshservice] meshagent.msh:"
cat "$SNAP_DATA/meshagent.msh"

# =============================================================================
# Step 3.5: Auto-connect the telemetry snap's device-identity content interface
#
# O snapd NÃO auto-conecta este content interface no seeding (a ligação do
# gadget.yaml é ignorada porque o slot do gadget ainda não está registado no
# momento do auto-connect — "gadget connections: ignoring missing slot").
# O default-provider resolveria isto, mas exige construir o snap em arm64
# (o gadget "pi" não existe para a arch de build amd64).
#
# Como este meshagent corre em devmode e como root, liga o interface em nome
# do sistema. Idempotente: se já estiver ligado, é um no-op.
if snap list iot-telemetry >/dev/null 2>&1; then
    echo "[meshservice] Connecting iot-telemetry:device-identity to pi:device-identity..."
    snap connect iot-telemetry:device-identity pi:device-identity 2>/dev/null \
        && echo "[meshservice] device-identity connected." \
        || echo "[meshservice] device-identity connect skipped (já ligado ou indisponível)."
fi

# =============================================================================
# Step 4: Start the MeshCentral agent
# =============================================================================
echo "[meshservice] Starting MeshCentral Agent..."
exec "$SNAP_DATA/meshagent"

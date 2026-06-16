#!/bin/sh
# Mesh Agent Service Script

MESH_SERVER=$(snapctl get mesh-server 2>/dev/null)
MESH_ID=$(snapctl get mesh-id 2>/dev/null)
SERVER_ID=$(snapctl get server-id 2>/dev/null)
EXPECTED_BRAND=$(snapctl get expected-brand-id 2>/dev/null)
EXPECTED_MODEL=$(snapctl get expected-model 2>/dev/null)

if [ -z "$MESH_SERVER" ] || [ -z "$MESH_ID" ] || [ -z "$SERVER_ID" ]; then
    echo "Erro: configuração incompleta. Execute:"
    echo "  snap set meshagent-ubuntucore mesh-server=https://seu-servidor"
    echo "  snap set meshagent-ubuntucore mesh-id=0xSEU_MESH_ID"
    echo "  snap set meshagent-ubuntucore server-id=SEU_SERVER_ID"
    echo "  snap set meshagent-ubuntucore expected-brand-id=mybrand # recomendado"
    echo "  snap set meshagent-ubuntucore expected-model=my-model   # recomendado"
    exit 1
fi

# ── Content interface check ────────────────────────────────
# O binário vem do gadget snap via content interface, não está bundled
# neste snap. O gadget expõe um slot "meshagent-bin" que é montado em
# $SNAP/gadget-bin/ quando o plug gadget-meshagent-bin está conectado.
GADGET_BIN="$SNAP/gadget-bin"
MESHAGENT_BIN="$GADGET_BIN/meshagent"

if [ ! -f "$MESHAGENT_BIN" ]; then
    echo "Erro: binário meshagent não encontrado em $MESHAGENT_BIN"
    echo "O content plug 'gadget-meshagent-bin' não está conectado."
    echo "Execute:"
    echo "  snap connect meshagent-ubuntucore:gadget-meshagent-bin <gadget>:meshagent-bin"
    exit 1
fi

if [ ! -x "$MESHAGENT_BIN" ]; then
    echo "Erro: $MESHAGENT_BIN não tem permissão de execução."
    echo "Verifique as permissões do binário no gadget snap."
    exit 1
fi

MESH_HOST=$(echo "$MESH_SERVER" | sed 's|https\?://||' | cut -d/ -f1 | cut -d: -f1)

echo "Aguardando rede..."
COUNT=0
while ! ping -c 1 -W 2 "$MESH_HOST" > /dev/null 2>&1; do
    COUNT=$((COUNT + 1))
    [ $COUNT -ge 30 ] && { echo "Timeout — a continuar."; break; }
    sleep 2
done
echo "Rede OK."

# ── Serial Assertion ───────────────────────────────────────
# Usa "snap known serial" para que o snapd valide a cadeia de assinaturas
# antes de devolver a assertion. Ler os ficheiros raw em
# /var/lib/snapd/assertions/ contornaria essa verificação criptográfica.
echo "Obtendo Serial Assertion verificada..."
SERIAL_ASSERTION=""
COUNT=0
while [ -z "$SERIAL_ASSERTION" ]; do
    SERIAL_ASSERTION=$(snap known serial 2>/dev/null)
    if [ -z "$SERIAL_ASSERTION" ]; then
        COUNT=$((COUNT + 1))
        [ $COUNT -ge 30 ] && { echo "Timeout Serial Assertion."; exit 1; }
        echo "Serial Assertion não disponível ($COUNT/30)..."
        sleep 10
    fi
done

SERIAL=$(echo "$SERIAL_ASSERTION"          | awk '/^serial:/{print $2}')
BRAND_ID=$(echo "$SERIAL_ASSERTION"        | awk '/^brand-id:/{print $2}')
MODEL=$(echo "$SERIAL_ASSERTION"           | awk '/^model:/{print $2}')
# Hash criptográfico da chave assimétrica única do dispositivo.
# Em hardware com TPM esta chave nunca abandona o chip, tornando-a muito
# mais difícil de falsificar do que o número de série sozinho.
DEVICE_KEY_HASH=$(echo "$SERIAL_ASSERTION" | awk '/^device-key-sha3-384:/{print $2}')

# ── Verificação de brand-id e model ───────────────────────
# Se configurados, garantem que o snap só corre em dispositivos da família
# autorizada. Impede que uma assertion de outro modelo seja aceite.
if [ -n "$EXPECTED_BRAND" ] && [ "$BRAND_ID" != "$EXPECTED_BRAND" ]; then
    echo "ERRO DE SEGURANÇA: brand-id '${BRAND_ID}' != esperado '${EXPECTED_BRAND}'. A terminar."
    exit 1
fi

if [ -n "$EXPECTED_MODEL" ] && [ "$MODEL" != "$EXPECTED_MODEL" ]; then
    echo "ERRO DE SEGURANÇA: model '${MODEL}' != esperado '${EXPECTED_MODEL}'. A terminar."
    exit 1
fi

echo "Identidade verificada: serial=${SERIAL} brand=${BRAND_ID} model=${MODEL}"
echo "Device key hash: ${DEVICE_KEY_HASH}"

# Usa serial como nome do dispositivo no MeshCentral se mesh-name não definido.
MESH_NAME=${"$SERIAL"}

cd "$SNAP_DATA" || exit 1

echo "Copiando binário do gadget snap..."
cp "$MESHAGENT_BIN" "$SNAP_DATA/meshagent"
chmod 755 "$SNAP_DATA/meshagent"

echo "Gerando configuração do agente..."
printf 'MeshName=%s\nMeshType=2\nMeshID=%s\nServerID=%s\nMeshServer=%s\nignoreProxyFile=1\nStartupType=1\n' \
    "$MESH_NAME" "$MESH_ID" "$SERVER_ID" "$MESH_SERVER" > "$SNAP_DATA/meshagent.msh"

echo "Iniciando o Mesh Agent..."
exec "$SNAP_DATA/meshagent"

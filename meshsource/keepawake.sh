#!/bin/bash
# Mantém a WiFi acordada para evitar quedas de SSH/ligação no Ubuntu Core.
#
# O Ubuntu Core não inclui `iw`, por isso não dá para desligar o power-save
# 802.11 diretamente. Em vez disso: (1) desligamos a gestão de energia do
# barramento SDIO da WiFi e (2) mantemos tráfego periódico para o gateway,
# o que impede a rádio de adormecer (que é o que derruba o SSH).
set -u

# 1) Barramento SDIO da WiFi sempre ligado (best-effort; ignora se não existir).
for d in /sys/class/net/wl*/device/power/control; do
    echo on > "$d" 2>/dev/null || true
done

# 2) Keepalive: 1 ping ao gateway a cada 2 s -> a rádio nunca fica ociosa.
while true; do
    GW=$(ip route 2>/dev/null | awk '/default/{print $3; exit}')
    [ -z "$GW" ] && GW=192.168.1.1
    ping -c1 -W1 "$GW" >/dev/null 2>&1 || true
    sleep 2
done

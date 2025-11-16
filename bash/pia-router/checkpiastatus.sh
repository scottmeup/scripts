#!/usr/bin/env bash
CURRENT_STATUS=$(piactl get connectionstate)

if [[ "$CURRENT_STATUS" == "Connected" ]]; then
    echo "VPN connected."
    exit 0
else
    echo "VPN disconnected. Disabling IP forwarding."
    sysctl -w net.ipv4.ip_forward=0
    exit 1
fi

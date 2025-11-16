#!/usr/bin/env bash

TARGET="8.8.8.8"  # Target IP for traceroute (Google DNS)
NON_EXPECTED_HOP="192.168.1.1"  # Non-expected first hop IP: usually the non-VPN default gateway

FIRST_HOP=$(traceroute -m 1 -n "$TARGET" 2>/dev/null | awk 'NR==2 {print $2}')

if [[ "$FIRST_HOP" == "$NON_EXPECTED_HOP" ]]; then
    echo " ^|^e First hop is $NON_EXPECTED_HOP(not as expected). Disabling IP forwarding"
    sysctl -w net.ipv4.ip_forward=0
    exit 1
else
    echo " ^}^l First hop is FIRSTHOP(notFIRST_HOP (not NON_EXPECTED_HOP)!"
    exit 0
fi

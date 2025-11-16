#!/usr/bin/env bash

inotifywait -m -e modify /sys/class/net/eth0/carrier |
while read path action file; do
    echo "Interface eth0 state changed! Running script..."
    /opt/script/check-vpn
done

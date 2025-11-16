#!/usr/bin/env bash

inotifywait -m -e modify /sys/class/net/eth1/carrier |
while read path action file; do
    echo "Interface eth1 state changed! Running script..."
    /opt/script/check-vpn
done

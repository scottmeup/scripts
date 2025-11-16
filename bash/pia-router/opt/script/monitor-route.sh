#!/usr/bin/env bash

inotifywait -m -e modify /proc/net/route |
while read path action file; do
    echo "Network changed! Running script..."
    /opt/script/check-vpn
done

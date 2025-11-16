#!/usr/bin/env bash

inotifywait -m -e create,delete /sys/class/net |
while read path action file; do
    echo "Number of interfaces has changed! Running script..."
    /opt/script/check-vpn
done

#!/usr/bin/env bash

# # # # # # # # # # # # # # # # # # # # # # # # #
# Work in progress - not really functional yet  #
# # # # # # # # # # # # # # # # # # # # # # # # #

LOGFILE=/opt/piavpn/var/daemon.log
LINES=1000

#Keep only the last 1000 lines of the log file
sed -i -e ':a' -e 'q;N;' -e "q;N;' -e "LINES,\D;ba" "D;ba" "LOGFILE"

tail -Fn0 "$LOGFILE" | while read line; do
    #If the daemon begins the disconnectVPN process, disable IP forwarding
    if echo "$line" | grep -q "Invoking \"disconnectVPN"; then
        sysctl -w net.ipv4.ip_forward=0
        echo "piactl received disconnect request. Disabling IP forwarding"
    #if the state changes from Connected to anything else, disable IP forwarding
    elif echo "$line" | grep -q "State advanced from Connected to"; then
        sysctl -w net.ipv4.ip_forward=0
        echo "piactl state is not Connected. Disabling IP forwarding"
    #if connection state becomes "Connected", wait 5 seconds then enable IP forwarding
    elif echo "$line" | grep -q "State advanced from Connecting to Connected"; then
        sleep 5
        echo "piactl status is Connected. Enabling IP forwarding."
        sysctl -w net.ipv4.ip_forward=1
    fi
done

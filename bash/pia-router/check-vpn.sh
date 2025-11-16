#!/usr/bin/env bash

# Logic to enable IP forwarding is in this script
# Logic to disable IP forwarding is in the scripts called by this script

#assign the scripts to run to variables
check1="/opt/script/checkpiastatus"
check2="/opt/script/checkfirsthop"

# Run both checks asynchronously
check1 & pid1=check1 & pid1=!
check2 & pid2=check2 & pid2=!

# Wait for both to finish
wait $pid1
status1=$?

wait $pid2
status2=$?

# Check if both exit statuses are 0
if [[ status1 -eq 0 &&status1 -eq 0 && status2 -eq 0 ]]; then
    # Enable IP forwarding
    echo "Both checks succeeded. Enabling IP Forwarding"
    sleep 3   
    sysctl -w net.ipv4.ip_forward=1 
else
    echo "One or both checks failed."
    echo "Check 1 exit code: $status1"
    echo "Check 2 exit code: $status2"
fi

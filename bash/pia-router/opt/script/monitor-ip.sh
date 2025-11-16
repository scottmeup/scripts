#!/usr/bin/env bash

# Monitor IP address, route, and link changes
ip monitor address route link | while read line; do
    /opt/script/check-vpn
done

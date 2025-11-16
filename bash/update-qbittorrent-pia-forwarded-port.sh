#!/usr/bin/env bash

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# Update qBittorrent with active forwarded port from piactl # 
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

#qBittorrent Web UI config
WEBUI_HOST=localhost
WEBUI_PORT=8080

#read PIA forwarded port
FORWARDED_PORT=$(piactl get portforward)

curl -k -i -X POST -d "json={\"random_port\": false}" "http://${WEBUI_HOST}:${WEBUI_PORT}/api/v2/app/setPreferences"
curl -k -i -X POST -d "json={\"listen_port\": ${FORWARDED_PORT}}" "http://${WEBUI_HOST}:${WEBUI_PORT}/api/v2/app/setPreferences"

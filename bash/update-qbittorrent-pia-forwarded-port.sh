#!/usr/bin/env bash

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# Update qBittorrent on localhost with active forwarded port from piactl  # 
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

#qBittorrent Web UI port
WEBUI_PORT=8080 

#read PIA forwarded port
forwarded_port=$(piactl get portforward)

curl -k -i -X POST -d "json={\"random_port\": false}" "http://localhost:${WEBUI_PORT}/api/v2/app/setPreferences"
curl -k -i -X POST -d "json={\"listen_port\": {forwarded_port}}" "http://localhost:{forwarded_port}}" "http://localhost:{WEBUI_PORT}/api/v2/app/setPreferences"

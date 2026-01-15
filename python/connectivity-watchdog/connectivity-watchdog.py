#!/usr/bin/env python3

import asyncio
import socket
import ssl
import time
import threading

import paho.mqtt.client as mqtt
import websockets

from pyroute2 import IPRoute
from pyroute2.netlink.rtnl import (
    RTMGRP_LINK,
    RTMGRP_IPV4_ROUTE,
    RTMGRP_NEIGH,
)

# ======================
# TCP keepalive settings
# ======================
TCP_KEEPIDLE = 15     # seconds before first probe
TCP_KEEPINTVL = 5     # seconds between probes
TCP_KEEPCNT = 3       # probes before failure

def enable_tcp_keepalive(sock: socket.socket):
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
    sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPIDLE, TCP_KEEPIDLE)
    sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPINTVL, TCP_KEEPINTVL)
    sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPCNT, TCP_KEEPCNT)


# ======================
# MQTT connections
# ======================
def start_mqtt(name, host, port):
    def on_connect(client, userdata, flags, rc):
        print(f"[MQTT:{name}] connected (rc={rc})")

    def on_disconnect(client, userdata, rc):
        print(f"[MQTT:{name}] disconnected (rc={rc})")

    client = mqtt.Client(client_id=f"watchdog-{name}-{int(time.time())}")
    client.on_connect = on_connect
    client.on_disconnect = on_disconnect

    client.tls_set(cert_reqs=ssl.CERT_REQUIRED)
    client.connect_async(host, port, keepalive=30)

    # Patch socket after creation
    def on_socket_open(client, userdata, sock):
        enable_tcp_keepalive(sock)

    client.on_socket_open = on_socket_open

    client.loop_start()
    return client


# ======================
# WebSocket connection
# ======================
async def websocket_task():
    uri = "wss://echo.websocket.events"

    ssl_ctx = ssl.create_default_context()

    while True:
        try:
            async with websockets.connect(uri, ssl=ssl_ctx) as ws:
                sock = ws.transport.get_extra_info("socket")
                if sock:
                    enable_tcp_keepalive(sock)

                print("[WS] connected")

                # Do nothing — no polling — just wait for disconnect
                await ws.wait_closed()
                print("[WS] disconnected")

        except Exception as e:
            print(f"[WS] error: {e}")

        await asyncio.sleep(1)


# ======================
# Netlink monitoring
# ======================
def netlink_monitor():
    ipr = IPRoute()
    ipr.bind(RTMGRP_LINK | RTMGRP_IPV4_ROUTE | RTMGRP_NEIGH)

    print("[NETLINK] monitoring started")

    while True:
        msgs = ipr.get()
        for msg in msgs:
            event = msg.get("event", "unknown")
            if msg["header"]["type"] in ("RTM_NEWLINK", "RTM_DELLINK"):
                print(f"[NETLINK] link event: {event}")
            elif msg["header"]["type"] in ("RTM_NEWROUTE", "RTM_DELROUTE"):
                print(f"[NETLINK] route event: {event}")
            elif msg["header"]["type"] in ("RTM_NEWNEIGH", "RTM_DELNEIGH"):
                print(f"[NETLINK] neighbor event: {event}")


# ======================
# Main
# ======================
def main():
    # Start MQTT connections
    mqtt_clients = [
        start_mqtt("emqx", "broker.emqx.io", 8883),
        start_mqtt("mosquitto", "test.mosquitto.org", 8883),
    ]

    # Start netlink monitor thread
    t = threading.Thread(target=netlink_monitor, daemon=True)
    t.start()

    # Start websocket loop
    asyncio.run(websocket_task())


if __name__ == "__main__":
    main()

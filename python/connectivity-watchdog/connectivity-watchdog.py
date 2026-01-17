#!/usr/bin/env python3

import asyncio
import socket
import ssl
import time
import threading
from typing import List, Optional
from enum import Enum

import paho.mqtt.client as mqtt
import websockets

from pyroute2 import IPRoute
from pyroute2.netlink.rtnl import (
    RTMGRP_LINK,
    RTMGRP_IPV4_ROUTE,
    RTMGRP_NEIGH,
)

# ======================
# Verbosity levels
# ======================
class Verbosity(Enum):
    LOW = 0      # Only critical state changes (connected/disconnected)
    MEDIUM = 1   # Default - includes status summary and state changes
    HIGH = 2     # Everything including connection attempts, pings, socket events

# ======================
# TCP keepalive settings
# ======================
TCP_KEEPIDLE = 15     # seconds before first probe
TCP_KEEPINTVL = 5     # seconds between probes
TCP_KEEPCNT = 3       # probes before failure

# Variable to keep track of intial status having been displayed for cleaner output
STATUS_SUMMARY_WILL_BE_DISPLAYED_LATER = True


def enable_tcp_keepalive(sock: socket.socket):
    """Enable TCP keepalive on a socket."""
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
    sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPIDLE, TCP_KEEPIDLE)
    sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPINTVL, TCP_KEEPINTVL)
    sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPCNT, TCP_KEEPCNT)


# ======================
# MQTT Connection Manager
# ======================
class MQTTConnection:
    """Manages a single MQTT connection with automatic reconnection."""
    
    def __init__(self, name: str, host: str, port: int, keepalive: int = 30, on_state_change=None, verbosity: Verbosity = Verbosity.MEDIUM):
        self.name = name
        self.host = host
        self.port = port
        self.keepalive = keepalive
        self.client: Optional[mqtt.Client] = None
        self.on_state_change = on_state_change
        self.verbosity = verbosity
        self.connected = False
        self.connection_time: Optional[float] = None
        self.disconnect_time: Optional[float] = None
        self.connect_count = 0
        self.disconnect_count = 0
        self.last_connect_attempt: Optional[float] = None
        self.connection_state = "initializing"  # initializing, connecting, connected, disconnected, error
        
    def _notify_state_change(self, state: str, reason: str = ""):
        """Notify about state changes."""
        self.connection_state = state
        if self.on_state_change:
            self.on_state_change(self.name, state, reason, self.get_stats())
        
    def get_stats(self) -> dict:
        """Get connection statistics."""
        return {
            "state": self.connection_state,
            "connected": self.connected,
            "connection_time": self.connection_time,
            "disconnect_time": self.disconnect_time,
            "last_connect_attempt": self.last_connect_attempt,
            "connect_count": self.connect_count,
            "disconnect_count": self.disconnect_count,
            "uptime": time.time() - self.connection_time if self.connected and self.connection_time else 0
        }
        
    def start(self):
        """Start the MQTT connection."""
        def on_connect(client, userdata, flags, reasonCode, properties):
            self.connected = True
            self.connection_time = time.time()
            self.connect_count += 1
            reason_str = str(reasonCode)
            global STATUS_SUMMARY_WILL_BE_DISPLAYED_LATER
            if (STATUS_SUMMARY_WILL_BE_DISPLAYED_LATER == False) & (self.verbosity.value >= Verbosity.MEDIUM.value):
                print(f"[MQTT:{self.name}] connected ({reason_str})")
            self._notify_state_change("connected", reason_str)

        def on_disconnect(client, userdata, reasonCode, properties):
            self.connected = False
            self.disconnect_time = time.time()
            self.disconnect_count += 1
            reason_str = str(reasonCode)
            global STATUS_SUMMARY_WILL_BE_DISPLAYED_LATER
            if (STATUS_SUMMARY_WILL_BE_DISPLAYED_LATER == False) & (self.verbosity.value >= Verbosity.MEDIUM.value):
                print(f"[MQTT:{self.name}] disconnected ({reason_str})")
            self._notify_state_change("disconnected", reason_str)

        def on_socket_open(client, userdata, sock):
            enable_tcp_keepalive(sock)
            if (STATUS_SUMMARY_WILL_BE_DISPLAYED_LATER == False) & (self.verbosity.value >= Verbosity.HIGH.value):
                print(f"[MQTT:{self.name}] socket opened")
            self._notify_state_change("socket_opened")

        def on_socket_close(client, userdata, sock):
            if (STATUS_SUMMARY_WILL_BE_DISPLAYED_LATER == False) & (self.verbosity.value >= Verbosity.HIGH.value):
                print(f"[MQTT:{self.name}] socket closed")
            self._notify_state_change("socket_closed")
            
        def on_connect_fail(client, userdata):
            if (STATUS_SUMMARY_WILL_BE_DISPLAYED_LATER == False) & (self.verbosity.value > Verbosity.MEDIUM.value):
                print(f"[MQTT:{self.name}] connection failed")
            self._notify_state_change("connection_failed", "Failed to establish connection")

        self.client = mqtt.Client(
            client_id=f"watchdog-{self.name}-{int(time.time())}",
            protocol=mqtt.MQTTv5,
            callback_api_version=mqtt.CallbackAPIVersion.VERSION2
        )

        self.client.on_connect = on_connect
        self.client.on_disconnect = on_disconnect
        self.client.on_socket_open = on_socket_open
        self.client.on_socket_close = on_socket_close
        self.client.on_connect_fail = on_connect_fail

        self.client.tls_set(cert_reqs=ssl.CERT_REQUIRED)
        
        self.last_connect_attempt = time.time()
        if self.verbosity.value >= Verbosity.HIGH.value:
            self._notify_state_change("connecting", f"Attempting connection to {self.host}:{self.port}")
        
        try:
            self.client.connect_async(self.host, self.port, keepalive=self.keepalive)
            self.client.loop_start()
        except Exception as e:
            if self.verbosity.value >= Verbosity.MEDIUM.value:
                print(f"[MQTT:{self.name}] failed to start: {e}")
            self._notify_state_change("error", str(e))
        
    def stop(self):
        """Stop the MQTT connection."""
        if self.client:
            self.client.loop_stop()
            self.client.disconnect()


# ======================
# WebSocket Connection Manager
# ======================
class WebSocketConnection:
    """Manages a WebSocket connection with keepalive pings."""
    
    def __init__(self, uri: str = "wss://echo.websocket.org", ping_interval: int = 20, on_state_change=None, verbosity: Verbosity = Verbosity.MEDIUM):
        self.uri = uri
        self.ping_interval = ping_interval
        self.running = False
        self.on_state_change = on_state_change
        self.verbosity = verbosity
        self.connected = False
        self.connection_time: Optional[float] = None
        self.disconnect_time: Optional[float] = None
        self.connect_count = 0
        self.disconnect_count = 0
        self.connection_state = "initializing"
        
    def _notify_state_change(self, state: str, reason: str = ""):
        """Notify about state changes."""
        self.connection_state = state
        if self.on_state_change:
            self.on_state_change("websocket", state, reason, self.get_stats())
            
    def get_stats(self) -> dict:
        """Get connection statistics."""
        return {
            "state": self.connection_state,
            "connected": self.connected,
            "connection_time": self.connection_time,
            "disconnect_time": self.disconnect_time,
            "connect_count": self.connect_count,
            "disconnect_count": self.disconnect_count,
            "uptime": time.time() - self.connection_time if self.connected and self.connection_time else 0
        }
        
    async def run(self):
        """Run the WebSocket connection with automatic reconnection."""
        self.running = True
        ssl_ctx = ssl.create_default_context()
        
        if self.verbosity.value >= Verbosity.HIGH.value:
            self._notify_state_change("connecting", f"Attempting connection to {self.uri}")

        while self.running:
            try:
                async with websockets.connect(self.uri, ssl=ssl_ctx, ping_interval=None) as ws:
                    sock = ws.transport.get_extra_info("socket")
                    if sock:
                        enable_tcp_keepalive(sock)

                    self.connected = True
                    self.connection_time = time.time()
                    self.connect_count += 1
                    self._notify_state_change("connected")

                    # Send periodic pings to keep connection alive
                    async def send_pings():
                        try:
                            while True:
                                await asyncio.sleep(self.ping_interval)
                                await ws.ping()
                                if self.verbosity.value >= Verbosity.HIGH.value:
                                    print("[WS] ping sent")
                        except Exception as e:
                            if self.verbosity.value >= Verbosity.HIGH.value:
                                print(f"[WS] ping error: {e}")

                    # Run ping task and wait for disconnect
                    ping_task = asyncio.create_task(send_pings())
                    
                    try:
                        await ws.wait_closed()
                    finally:
                        ping_task.cancel()
                        try:
                            await ping_task
                        except asyncio.CancelledError:
                            pass
                    
                    self.connected = False
                    self.disconnect_time = time.time()
                    self.disconnect_count += 1
                    if self.verbosity.value >= Verbosity.MEDIUM.value:
                        print("[WS] disconnected")
                    self._notify_state_change("disconnected")

            except Exception as e:
                if self.verbosity.value >= Verbosity.MEDIUM.value:
                    print(f"[WS] error: {e}")
                self._notify_state_change("error", str(e))

            if self.running:
                if self.verbosity.value >= Verbosity.HIGH.value:
                    self._notify_state_change("connecting", "Reconnecting...")
                await asyncio.sleep(1)
    
    def stop(self):
        """Stop the WebSocket connection."""
        self.running = False


# ======================
# Netlink Monitor
# ======================
class NetlinkMonitor:
    """Monitors network events via Netlink."""
    
    def __init__(self, verbosity: Verbosity = Verbosity.MEDIUM):
        self.running = False
        self.thread: Optional[threading.Thread] = None
        self.verbosity = verbosity
        
    def _monitor(self):
        """Internal monitoring function."""
        ipr = IPRoute()
        ipr.bind(RTMGRP_LINK | RTMGRP_IPV4_ROUTE | RTMGRP_NEIGH)

        if self.verbosity.value >= Verbosity.MEDIUM.value:
            print("[NETLINK] monitoring started")

        while self.running:
            try:
                msgs = ipr.get()
                for msg in msgs:
                    event = msg.get("event", "unknown")
                    msg_type = msg["header"]["type"]
                    
                    if self.verbosity.value >= Verbosity.HIGH.value:
                        if msg_type in ("RTM_NEWLINK", "RTM_DELLINK"):
                            print(f"[NETLINK] link event: {event}")
                        elif msg_type in ("RTM_NEWROUTE", "RTM_DELROUTE"):
                            print(f"[NETLINK] route event: {event}")
                        elif msg_type in ("RTM_NEWNEIGH", "RTM_DELNEIGH"):
                            print(f"[NETLINK] neighbor event: {event}")
            except Exception as e:
                if self.running and self.verbosity.value >= Verbosity.MEDIUM.value:
                    print(f"[NETLINK] error: {e}")
                    
        if self.verbosity.value >= Verbosity.MEDIUM.value:
            print("[NETLINK] monitoring stopped")
        
    def start(self):
        """Start the Netlink monitor in a background thread."""
        self.running = True
        self.thread = threading.Thread(target=self._monitor, daemon=True)
        self.thread.start()
        
    def stop(self):
        """Stop the Netlink monitor."""
        self.running = False
        if self.thread:
            self.thread.join(timeout=2)


# ======================
# Main Watchdog
# ======================
class ConnectivityWatchdog:
    """Main connectivity monitoring orchestrator."""
    
    def __init__(self, mqtt_brokers: Optional[List[dict]] = None, on_state_change=None, verbosity: Verbosity = Verbosity.MEDIUM):
        """
        Initialize the watchdog.
        
        Args:
            mqtt_brokers: List of dicts with 'name', 'host', 'port' keys.
                         If None, uses default brokers.
            on_state_change: Callback function(name, state, reason, stats) called
                           when any connection state changes.
            verbosity: Verbosity level (LOW, MEDIUM, HIGH). Default is MEDIUM.
        """
        if mqtt_brokers is None:
            mqtt_brokers = [
                {"name": "freemqtt", "host": "broker.freemqtt.com", "port": 8883},
                {"name": "emqx", "host": "broker.emqx.io", "port": 8883},
                {"name": "mosquitto", "host": "test.mosquitto.org", "port": 8883},
            ]
        
        self.on_state_change = on_state_change
        self.verbosity = verbosity
        self.mqtt_connections = [
            MQTTConnection(b["name"], b["host"], b["port"], on_state_change=on_state_change, verbosity=verbosity) 
            for b in mqtt_brokers
        ]
        self.websocket = WebSocketConnection(on_state_change=on_state_change, verbosity=verbosity)
        self.netlink = NetlinkMonitor(verbosity=verbosity)
        
    def get_status(self) -> dict:
        """Get current status of all connections."""
        return {
            "mqtt": {conn.name: conn.get_stats() for conn in self.mqtt_connections},
            "websocket": self.websocket.get_stats()
        }
    
    def print_status_summary(self):
        """Print a summary of all connection states."""
        if self.verbosity.value >= Verbosity.MEDIUM.value:
            print("\n=== Connection Status Summary ===")
            for conn in self.mqtt_connections:
                stats = conn.get_stats()
                status_icon = "✓" if stats["connected"] else "✗"
                print(f"{status_icon} MQTT:{conn.name:12} - {stats['state']:20} (connects: {stats['connect_count']}, disconnects: {stats['disconnect_count']})")
            
            ws_stats = self.websocket.get_stats()
            status_icon = "✓" if ws_stats["connected"] else "✗"
            print(f"{status_icon} WebSocket      - {ws_stats['state']:20} (connects: {ws_stats['connect_count']}, disconnects: {ws_stats['disconnect_count']})")
            print("================================\n")
            global STATUS_SUMMARY_WILL_BE_DISPLAYED_LATER 
            STATUS_SUMMARY_WILL_BE_DISPLAYED_LATER = False
        
    async def run(self):
        """Run all monitoring components."""
        # Start Netlink monitor
        self.netlink.start()
        
        # Start all MQTT connections simultaneously
        for mqtt_conn in self.mqtt_connections:
            mqtt_conn.start()
        
        # Allow TLS handshakes to complete and check initial status
        await asyncio.sleep(3)
        
        # Print initial status summary
        self.print_status_summary()
        
        # Run WebSocket (this runs forever until stopped)
        await self.websocket.run()
        
    def stop(self):
        """Stop all monitoring components."""
        self.websocket.stop()
        self.netlink.stop()
        for mqtt_conn in self.mqtt_connections:
            mqtt_conn.stop()


# ======================
# Convenience functions
# ======================
def default_state_change_handler(name: str, state: str, reason: str, stats: dict, verbosity: Verbosity = Verbosity.MEDIUM):
    """Default handler that prints detailed state changes."""
    uptime = stats.get("uptime", 0)
    connect_count = stats.get("connect_count", 0)
    disconnect_count = stats.get("disconnect_count", 0)

    global STATUS_SUMMARY_WILL_BE_DISPLAYED_LATER 
    if verbosity.value == Verbosity.LOW.value:
        STATUS_SUMMARY_WILL_BE_DISPLAYED_LATER = False
    
    if STATUS_SUMMARY_WILL_BE_DISPLAYED_LATER == False:
        if state == "connecting":
            if verbosity.value >= Verbosity.HIGH.value:
                print(f"[STATE] {name}: CONNECTING... {reason}")
        # Show connected/disconnected at MEDIUM and above
        elif state == "connected":
            if verbosity.value >= Verbosity.MEDIUM.value:
                print(f"[STATE] {name}: ✓ CONNECTED (reason: {reason}, total connects: {connect_count})")
            elif verbosity.value >= Verbosity.LOW.value:
                print(f"[STATE] {name}: ✓ CONNECTED")
        elif state == "disconnected":
            if verbosity.value >= Verbosity.MEDIUM.value:
                print(f"[STATE] {name}: ✗ DISCONNECTED (reason: {reason}, uptime: {uptime:.1f}s, total disconnects: {disconnect_count})")
            elif verbosity.value >= Verbosity.LOW.value:
                print(f"[STATE] {name}: ✗ DISCONNECTED")
        elif state == "connection_failed":
            if verbosity.value > Verbosity.MEDIUM.value:
                print(f"[STATE] {name}: ✗ CONNECTION FAILED - {reason}")
        # Socket events only at HIGH verbosity
        elif state == "socket_opened":
            if verbosity.value >= Verbosity.HIGH.value:
                print(f"[STATE] {name}: SOCKET OPENED")
        elif state == "socket_closed":
            if verbosity.value >= Verbosity.HIGH.value:
                print(f"[STATE] {name}: SOCKET CLOSED")
        elif state == "error":
            if verbosity.value >= Verbosity.MEDIUM.value:
                print(f"[STATE] {name}: ✗ ERROR - {reason}")
            elif verbosity.value >= Verbosity.LOW.value:
                print(f"[STATE] {name}: ✗ ERROR")


async def run_watchdog(mqtt_brokers: Optional[List[dict]] = None, on_state_change=None, verbosity: Verbosity = Verbosity.MEDIUM):
    """
    Convenience function to run the watchdog.
    
    Args:
        mqtt_brokers: List of dicts with 'name', 'host', 'port' keys.
        on_state_change: Callback function(name, state, reason, stats) for state changes.
                        If None, uses default_state_change_handler with the specified verbosity.
        verbosity: Verbosity level (LOW, MEDIUM, HIGH). Default is MEDIUM.
    """
    if on_state_change is None:
        on_state_change = lambda name, state, reason, stats: default_state_change_handler(
            name, state, reason, stats, verbosity
        )
        
    watchdog = ConnectivityWatchdog(mqtt_brokers, on_state_change=on_state_change, verbosity=verbosity)
    try:
        await watchdog.run()
    except KeyboardInterrupt:
        print("\n[MAIN] Shutting down...")
        watchdog.stop()


# ======================
# Main entry point
# ======================
async def main():
    """Main entry point when run as a script."""
    await run_watchdog()


if __name__ == "__main__":
    asyncio.run(main())
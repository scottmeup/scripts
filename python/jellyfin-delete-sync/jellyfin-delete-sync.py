#!/usr/bin/env python3

# To do
# Ignore deletions from certain libraries, eg. Suggested movies from JellyNext


# jellyfin-delete-sync.py
# Version: 3.3.0 (Modular Refactor)
# Date: January 06, 2026

import argparse
from flask import Flask
from scheduler import setup_scheduler
from webhook import register_webhooks
from db import init_database, build_provider_map
from utils import log

app = Flask(__name__)

# Register routes
register_webhooks(app)

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--rebuild', action='store_true', help='Force immediate rebuild on startup')
    parser.add_argument('--clear-status', action='store_true', help='Clear all stored series completion status')
    args = parser.parse_args()

    try:
        log("Jellyfin Sync Script starting - Version 3.3.0")

        init_database()

        build_provider_map(clear_status=args.clear_status)

        if args.rebuild:
            build_provider_map(clear_status=args.clear_status)

        scheduler = setup_scheduler()

        base_url = f"http://{app.config.get('LISTEN_HOST', '0.0.0.0')}:{app.config.get('LISTEN_PORT', 5373)}"
        log(f"Jellyfin webhook endpoint: {base_url}/jellyfin")
        log(f"Sonarr webhook endpoint: {base_url}/sonarr")

        # Pass config values to app for logging
        from config import LISTEN_HOST, LISTEN_PORT
        app.config['LISTEN_HOST'] = LISTEN_HOST
        app.config['LISTEN_PORT'] = LISTEN_PORT

        app.run(host=LISTEN_HOST, port=LISTEN_PORT, debug=False)
    except Exception as e:
        log("FATAL ERROR during startup:")
        log(traceback.format_exc())
        exit(1)
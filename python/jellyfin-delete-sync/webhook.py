# webhook.py
import json
import requests
import traceback
from flask import request
from utils import log, json_repair
from sonarr import (
    find_series_via_map, find_series,
    is_series_completed, is_season_fully_downloaded,
    set_series_completed
)
from config import SONARR_URL, SONARR_HEADERS, RADARR_URL, RADARR_HEADERS, SERIES_DELETION_MODE, SEASON_DELETION_MODE

def register_webhooks(app):
    @app.route('/jellyfin', methods=['POST'])
    def jellyfin_webhook():
        # Full webhook logic with enhanced logging (same as latest version)
        # ... (copy full jellyfin_webhook from previous full code)

        return 'OK', 200

    @app.route('/sonarr', methods=['POST'])
    def sonarr_webhook():
        # Full sonarr webhook with completion updates
        # ... (copy from previous)

        return 'OK', 200
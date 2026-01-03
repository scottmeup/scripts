#!/usr/bin/env python3

import flask
import requests
import json
import sqlite3
import argparse
import threading
import time
from datetime import datetime

try:
    from config import (
        SONARR_URL, SONARR_API_KEY,
        RADARR_URL, RADARR_API_KEY,
        LISTEN_HOST, LISTEN_PORT,
        REBUILD_INTERVAL_MINUTES
    )
except ImportError:
    print("ERROR: Could not import config.py - create it in the same directory!")
    exit(1)

app = flask.Flask(__name__)

SONARR_HEADERS = {'X-Api-Key': SONARR_API_KEY}
RADARR_HEADERS = {'X-Api-Key': RADARR_API_KEY}

DB_FILE = 'episode_map.db'

def log(msg):
    print(f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] {msg}")

def get_db_connection():
    conn = sqlite3.connect(DB_FILE, check_same_thread=False)
    conn.row_factory = sqlite3.Row
    return conn

def build_episode_map():
    log("Rebuilding episode map...")
    start = time.time()
    conn = get_db_connection()
    cur = conn.cursor()
    cur.execute('DELETE FROM episode_map')
    resp = requests.get(f"{SONARR_URL}/api/v3/series", headers=SONARR_HEADERS)
    if resp.status_code != 200:
        log(f"ERROR: Cannot fetch series from Sonarr ({resp.status_code})")
        conn.close()
        return
    inserted = 0
    for series in resp.json():
        sid = series['id']
        eps = requests.get(f"{SONARR_URL}/api/v3/episode?seriesId={sid}", headers=SONARR_HEADERS)
        if eps.status_code == 200:
            for ep in eps.json():
                tvdb = ep.get('tvdbId')
                if tvdb:
                    cur.execute('INSERT OR IGNORE INTO episode_map (episode_tvdb_id, series_id) VALUES (?, ?)', (str(tvdb), sid))
                    inserted += 1
    conn.commit()
    conn.close()
    log(f"Map rebuilt: {inserted} entries in {time.time()-start:.1f}s")

def periodic_rebuild():
    if not REBUILD_INTERVAL_MINUTES or REBUILD_INTERVAL_MINUTES <= 0:
        return
    secs = REBUILD_INTERVAL_MINUTES * 60
    log(f"Auto-rebuild enabled every {REBUILD_INTERVAL_MINUTES} minutes")
    while True:
        time.sleep(secs)
        build_episode_map()

def find_series_via_map(tvdb_id):
    conn = get_db_connection()
    cur = conn.cursor()
    cur.execute('SELECT series_id FROM episode_map WHERE episode_tvdb_id = ?', (tvdb_id,))
    row = cur.fetchone()
    conn.close()
    if row:
        sid = row['series_id']
        log(f"Map hit: TVDB {tvdb_id} → series ID {sid}")
        r = requests.get(f"{SONARR_URL}/api/v3/series/{sid}", headers=SONARR_HEADERS)
        if r.status_code == 200:
            return r.json()
    return None

def find_series(tvdb_id=None, title=None):
    if tvdb_id:
        r = requests.get(f"{SONARR_URL}/api/v3/series?tvdbId={tvdb_id}", headers=SONARR_HEADERS)
        if r.status_code == 200 and r.json():
            return r.json()[0]
    if title:
        r = requests.get(f"{SONARR_URL}/api/v3/series", headers=SONARR_HEADERS)
        if r.status_code == 200:
            for s in r.json():
                if s['title'].lower() == title.lower():
                    log(f"Title match: {s['title']}")
                    return s
    return None

@app.route('/webhook', methods=['POST'])
def webhook():
    raw_data = flask.request.data.decode('utf-8')
    if not raw_data:
        log("EMPTY REQUEST BODY")
        return 'No data', 400

    log("=== RAW WEBHOOK RECEIVED ===")
    log(raw_data)

    try:
        data = json.loads(raw_data)
    except json.JSONDecodeError as e:
        log(f"JSON DECODE ERROR: {e}")
        log("Attempting to fix common malformed JSON (empty EpisodeNumber)...")
        # Fix common bug: "EpisodeNumber": ,
        fixed = raw_data.replace('"EpisodeNumber": ,', '"EpisodeNumber": null,')
        try:
            data = json.loads(fixed)
            log("JSON fixed and parsed successfully")
        except:
            log("Still failed to parse JSON")
            return 'Invalid JSON', 400

    log("=== PARSED PAYLOAD ===")
    log(json.dumps(data, indent=2))

    if data.get('NotificationType') != 'ItemDeleted':
        log("Not a deletion event - ignored")
        return 'Ignored', 200

    item = data.get('Item', data)
    item_type = item.get('Type')
    name = item.get('Name', 'Unknown')
    series_name = item.get('SeriesName')
    season_num = item.get('SeasonNumber')
    episode_num = item.get('EpisodeNumber')  # may be null

    provider_ids = item.get('ProviderIds', {})
    tvdb_id = provider_ids.get('Tvdb') or item.get('Provider_tvdb')
    tmdb_id = provider_ids.get('Tmdb') or item.get('Provider_tmdb')

    log(f"Type: {item_type} | Name: {name} | Series: {series_name} | Season: {season_num} | Episode: {episode_num}")
    log(f"TVDB: {tvdb_id} | TMDB: {tmdb_id}")

    if item_type == 'Movie':
        if not tmdb_id:
            log("No TMDB ID for movie")
            return 'No ID', 400
        # Movie deletion code (same as before)
        # ... (omitted for brevity, but keep your existing movie logic)

    elif item_type in ['Series', 'Season', 'Episode']:
        series = None
        if item_type == 'Episode' and tvdb_id:
            series = find_series_via_map(tvdb_id)
        if not series:
            series_tvdb = tvdb_id if item_type == 'Series' else None
            series = find_series(series_tvdb, series_name)
        if not series:
            log("ERROR: Series not found in Sonarr")
            return 'Series not found', 404

        series_id = series['id']
        log(f"Using series: {series['title']} (ID: {series_id})")

        if item_type == 'Series':
            requests.delete(f"{SONARR_URL}/api/v3/series/{series_id}?deleteFiles=true", headers=SONARR_HEADERS)
            log("Series deleted from Sonarr")

        elif item_type == 'Season':
            # Unmonitor season
            updated = False
            for s in series['seasons']:
                if s['seasonNumber'] == season_num and s['monitored']:
                    s['monitored'] = False
                    updated = True
            if updated:
                requests.put(f"{SONARR_URL}/api/v3/series/{series_id}", json=series, headers=SONARR_HEADERS)
                log(f"Season {season_num} unmonitored")

            # Delete episode files
            files = requests.get(f"{SONARR_URL}/api/v3/episodefile?seriesId={series_id}", headers=SONARR_HEADERS).json()
            deleted = 0
            for f in files:
                if f['seasonNumber'] == season_num:
                    requests.delete(f"{SONARR_URL}/api/v3/episodefile/{f['id']}", headers=SONARR_HEADERS)
                    deleted += 1
            log(f"Deleted {deleted} episode files")
            log("Season processed successfully")

        elif item_type == 'Episode':
            # Episode deletion logic (same as before)
            pass

    log("=== WEBHOOK PROCESSED SUCCESSFULLY ===\n")
    return 'OK', 200

# Sonarr webhook route remains the same...

if __name__ == '__main__':
    # ... same startup logic as before ...

    app.run(host=LISTEN_HOST, port=LISTEN_PORT, debug=False)
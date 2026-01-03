#!/usr/bin/env python3

import flask
import requests
import json
from datetime import datetime

try:
    from config import (
        SONARR_URL, SONARR_API_KEY,
        RADARR_URL, RADARR_API_KEY,
        LISTEN_HOST, LISTEN_PORT
    )
except ImportError:
    print("ERROR: Could not import config.py - create it with your settings!")
    exit(1)

app = flask.Flask(__name__)

SONARR_HEADERS = {'X-Api-Key': SONARR_API_KEY}
RADARR_HEADERS = {'X-Api-Key': RADARR_API_KEY}

def log(msg):
    print(f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] {msg}")

def find_series(tvdb_id=None, title=None):
    """Find series in Sonarr - try TVDB ID first, then title"""
    if tvdb_id:
        resp = requests.get(f"{SONARR_URL}/api/v3/series?tvdbId={tvdb_id}", headers=SONARR_HEADERS)
        if resp.status_code == 200 and resp.json():
            log(f"Series found by TVDB ID {tvdb_id}")
            return resp.json()[0]

    if title:
        resp = requests.get(f"{SONARR_URL}/api/v3/series", headers=SONARR_HEADERS)
        if resp.status_code == 200:
            series_list = resp.json()
            matches = [s for s in series_list if s['title'].lower() == title.lower()]
            if matches:
                log(f"Series found by title: {matches[0]['title']} (ID: {matches[0]['id']})")
                return matches[0]
            else:
                log(f"Series '{title}' not found by title match")
    return None

@app.route('/webhook', methods=['POST'])
def webhook():
    data = flask.request.get_json(force=True)
    log("=== WEBHOOK RECEIVED ===")
    if data:
        log(json.dumps(data, indent=2))
    else:
        log("EMPTY PAYLOAD")
        return 'No JSON', 400

    if data.get('NotificationType') != 'ItemDeleted':
        log("Ignored: not an ItemDeleted event")
        return 'Ignored', 200

    item = data.get('Item', data)
    item_type = item.get('Type')
    name = item.get('Name', 'Unknown')
    series_name = item.get('SeriesName')
    season_num = item.get('SeasonNumber')
    episode_num = item.get('EpisodeNumber')

    provider_ids = item.get('ProviderIds', {})
    tvdb_id = provider_ids.get('Tvdb') or item.get('Provider_tvdb')
    tmdb_id = provider_ids.get('Tmdb') or item.get('Provider_tmdb')

    log(f"Item Type: {item_type} | Name: {name}")
    log(f"Series: {series_name} | Season: {season_num} | Episode: {episode_num}")
    log(f"TVDB ID (raw): {tvdb_id} | TMDB ID: {tmdb_id}")

    # ===================== MOVIE =====================
    if item_type == 'Movie':
        if not tmdb_id:
            log("ERROR: No TMDB ID for movie")
            return 'No TMDB', 400
        # ... (movie logic unchanged - works fine)

    # ===================== SERIES / SEASON / EPISODE =====================
    elif item_type in ['Series', 'Season', 'Episode']:
        if item_type == 'Series' and not tvdb_id:
            log("ERROR: Series deletion needs TVDB ID")
            return 'No TVDB', 400

        # For Series: use TVDB ID directly
        # For Season/Episode: use title (tvdb_id is usually episode-level)
        series = find_series(tvdb_id if item_type == 'Series' else None, series_name)
        if not series:
            log("ERROR: Could not find series in Sonarr")
            return 'Series not found', 404

        series_id = series['id']
        log(f"Using series: {series['title']} (Sonarr ID: {series_id})")

        # ----- SERIES DELETION -----
        if item_type == 'Series':
            del_resp = requests.delete(
                f"{SONARR_URL}/api/v3/series/{series_id}?deleteFiles=true&addImportExclusion=false",
                headers=SONARR_HEADERS
            )
            log(f"Series delete result: {del_resp.status_code} {del_resp.text}")
            log("Series removed from Sonarr")

        # ----- SEASON DELETION -----
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

            # Delete episode files in season
            files = requests.get(f"{SONARR_URL}/api/v3/episodefile?seriesId={series_id}", headers=SONARR_HEADERS).json()
            deleted_count = 0
            for file in files:
                if file['seasonNumber'] == season_num:
                    requests.delete(f"{SONARR_URL}/api/v3/episodefile/{file['id']}", headers=SONARR_HEADERS)
                    deleted_count += 1
            log(f"Deleted {deleted_count} episode files from season {season_num}")
            log("Season processed")

        # ----- EPISODE DELETION -----
        elif item_type == 'Episode':
            episodes = requests.get(
                f"{SONARR_URL}/api/v3/episode?seriesId={series_id}&seasonNumber={season_num}",
                headers=SONARR_HEADERS
            ).json()

            target = next((e for e in episodes if e['episodeNumber'] == episode_num), None)
            if not target:
                log("Episode not found in Sonarr database")
                return 'Episode not found', 200

            # Unmonitor
            if target['monitored']:
                target['monitored'] = False
                requests.put(f"{SONARR_URL}/api/v3/episode/{target['id']}", json=target, headers=SONARR_HEADERS)
                log("Episode unmonitored")

            # Delete file
            if target.get('hasFile'):
                file_id = target['episodeFileId']
                del_resp = requests.delete(f"{SONARR_URL}/api/v3/episodefile/{file_id}", headers=SONARR_HEADERS)
                log(f"Episode file deleted: {del_resp.status_code}")
            else:
                log("No file to delete (already missing)")

            log("Episode successfully processed")

    else:
        log(f"Unsupported item type: {item_type}")

    log("=== PROCESSING COMPLETE ===\n")
    return 'OK', 200

if __name__ == '__main__':
    log(f"Starting server on http://{LISTEN_HOST}:{LISTEN_PORT}/webhook")
    app.run(host=LISTEN_HOST, port=LISTEN_PORT, debug=False)

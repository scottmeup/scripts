#!/usr/bin/env python3

# jellyfin_sync.py
# Version: 1.3.0
# Date: January 04, 2026
#
# Changelog:
# 1.3.0 - Fixed JSON parsing for Series deletions (multiple empty fields: SeasonNumber, EpisodeNumber)
#         - Enhanced repair logic to replace any ": ," with ": null,"
#         - Added logging of repair attempts
#         - Series deletions now work reliably
# 1.2.1 - Fixed schema migration for seasons table...
# 1.2.0 - Extended seasons table...

import flask
import requests
import json
import sqlite3
import argparse
import threading
import time
import re
from datetime import datetime

try:
    from config import (
        SONARR_URL, SONARR_API_KEY,
        RADARR_URL, RADARR_API_KEY,
        LISTEN_HOST, LISTEN_PORT,
        REBUILD_INTERVAL_MINUTES
    )
except ImportError:
    print("ERROR: Could not import config.py - create it in the same directory with your settings!")
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

def upgrade_database_schema(conn):
    cur = conn.cursor()
    
    cur.execute("PRAGMA table_info(seasons)")
    columns = [col[1] for col in cur.fetchall()]
    
    if 'tvdb_id' not in columns:
        log("Upgrading seasons table: adding tvdb_id")
        cur.execute("ALTER TABLE seasons ADD COLUMN tvdb_id INTEGER")
    if 'tmdb_id' not in columns:
        log("Upgrading seasons table: adding tmdb_id")
        cur.execute("ALTER TABLE seasons ADD COLUMN tmdb_id INTEGER")
    if 'imdb_id' not in columns:
        log("Upgrading seasons table: adding imdb_id")
        cur.execute("ALTER TABLE seasons ADD COLUMN imdb_id TEXT")
    
    conn.commit()

def build_provider_map():
    log("Building full provider map from Sonarr and Radarr...")
    start_time = time.time()
    conn = get_db_connection()
    cur = conn.cursor()

    cur.execute('DELETE FROM movies')
    cur.execute('DELETE FROM episodes')
    cur.execute('DELETE FROM seasons')
    cur.execute('DELETE FROM series')
    cur.execute('DELETE FROM episode_map')

    series_resp = requests.get(f"{SONARR_URL}/api/v3/series", headers=SONARR_HEADERS)
    if series_resp.status_code != 200:
        log(f"ERROR: Failed to fetch series from Sonarr ({series_resp.status_code})")
        conn.close()
        return

    series_list = series_resp.json()
    series_count = 0
    season_count = 0
    episode_count = 0
    for ser in series_list:
        series_id = ser['id']
        title = ser['title']
        tvdb = ser.get('tvdbId')
        tmdb = None
        imdb = ser.get('imdbId')

        cur.execute(
            'INSERT INTO series (series_id, title, tvdb_id, tmdb_id, imdb_id) VALUES (?, ?, ?, ?, ?)',
            (series_id, title, tvdb, tmdb, imdb)
        )
        series_count += 1

        for season in ser['seasons']:
            season_num = season['seasonNumber']
            cur.execute(
                'INSERT INTO seasons (series_id, season_number, tvdb_id, tmdb_id, imdb_id) VALUES (?, ?, ?, ?, ?)',
                (series_id, season_num, None, None, None)
            )
            season_count += 1

        eps_resp = requests.get(f"{SONARR_URL}/api/v3/episode?seriesId={series_id}", headers=SONARR_HEADERS)
        if eps_resp.status_code == 200:
            for ep in eps_resp.json():
                ep_id = ep['id']
                season_num = ep['seasonNumber']
                ep_num = ep['episodeNumber']
                ep_tvdb = ep.get('tvdbId')
                ep_tmdb = None
                ep_imdb = ep.get('imdbId')

                cur.execute(
                    'INSERT INTO episodes (episode_id, series_id, season_number, episode_number, tvdb_id, tmdb_id, imdb_id) VALUES (?, ?, ?, ?, ?, ?, ?)',
                    (ep_id, series_id, season_num, ep_num, ep_tvdb, ep_tmdb, ep_imdb)
                )
                episode_count += 1

                if ep_tvdb:
                    cur.execute(
                        'INSERT OR IGNORE INTO episode_map (episode_tvdb_id, series_id) VALUES (?, ?)',
                        (str(ep_tvdb), series_id)
                    )

    movies_resp = requests.get(f"{RADARR_URL}/api/v3/movie", headers=RADARR_HEADERS)
    if movies_resp.status_code != 200:
        log(f"ERROR: Failed to fetch movies from Radarr ({movies_resp.status_code})")
        conn.close()
        return

    movie_count = 0
    for movie in movies_resp.json():
        movie_id = movie['id']
        title = movie['title']
        tmdb = movie.get('tmdbId')
        imdb = movie.get('imdbId')

        cur.execute(
            'INSERT INTO movies (movie_id, title, tmdb_id, imdb_id) VALUES (?, ?, ?, ?)',
            (movie_id, title, tmdb, imdb)
        )
        movie_count += 1

    conn.commit()
    conn.close()

    duration = time.time() - start_time
    log(f"Provider map built: {series_count} series, {season_count} seasons, {episode_count} episodes, {movie_count} movies in {duration:.1f}s")

def periodic_rebuild():
    if not REBUILD_INTERVAL_MINUTES or REBUILD_INTERVAL_MINUTES <= 0:
        return
    interval_seconds = REBUILD_INTERVAL_MINUTES * 60
    log(f"Scheduled automatic rebuild every {REBUILD_INTERVAL_MINUTES} minutes")
    while True:
        time.sleep(interval_seconds)
        log("Scheduled rebuild started")
        build_provider_map()

def find_series_via_map(episode_tvdb_id):
    conn = get_db_connection()
    cur = conn.cursor()
    cur.execute('SELECT series_id FROM episode_map WHERE episode_tvdb_id = ?', (episode_tvdb_id,))
    row = cur.fetchone()
    conn.close()
    if row:
        series_id = row['series_id']
        log(f"Map hit: episode TVDB {episode_tvdb_id} → series ID {series_id}")
        resp = requests.get(f"{SONARR_URL}/api/v3/series/{series_id}", headers=SONARR_HEADERS)
        if resp.status_code == 200:
            return resp.json()
    return None

def find_series(tvdb_id=None, title=None):
    if tvdb_id:
        resp = requests.get(f"{SONARR_URL}/api/v3/series?tvdbId={tvdb_id}", headers=SONARR_HEADERS)
        if resp.status_code == 200 and resp.json():
            log(f"Series found by series-level TVDB ID {tvdb_id}")
            return resp.json()[0]
    if title:
        resp = requests.get(f"{SONARR_URL}/api/v3/series", headers=SONARR_HEADERS)
        if resp.status_code == 200:
            for s in resp.json():
                if s['title'].lower() == title.lower():
                    log(f"Series found by title match: '{s['title']}'")
                    return s
            log(f"No series found matching title '{title}'")
    return None

@app.route('/webhook', methods=['POST'])
def jellyfin_webhook():
    raw_body = flask.request.data.decode('utf-8')
    if not raw_body:
        log("EMPTY REQUEST BODY RECEIVED")
        return 'No data', 400

    log("=== RAW JELLYFIN WEBHOOK RECEIVED ===")
    log(raw_body)

    # Enhanced repair: replace any ": ," (empty value) with ": null,"
    repaired_body = re.sub(r':\s*,', ': null,', raw_body)
    if repaired_body != raw_body:
        log("Applied JSON repair: replaced empty values (: ,) with : null,")

    try:
        data = json.loads(repaired_body)
        log("JSON parsed successfully")
    except json.JSONDecodeError as e:
        log(f"JSON parse failed even after repair: {e}")
        return 'Invalid JSON', 400

    log("=== PARSED PAYLOAD ===")
    log(json.dumps(data, indent=2))

    if data.get('NotificationType') != 'ItemDeleted':
        log("Ignored: not an ItemDeleted event")
        return 'Ignored', 200

    item = data.get('Item', data)
    item_type = item.get('Type')
    name = item.get('Name', 'Unknown')
    series_name = item.get('SeriesName') or ''  # Can be empty for Series deletion
    season_num = item.get('SeasonNumber')
    episode_num = item.get('EpisodeNumber')

    provider_ids = item.get('ProviderIds', {})
    tvdb_id = provider_ids.get('Tvdb') or item.get('Provider_tvdb')
    tmdb_id = provider_ids.get('Tmdb') or item.get('Provider_tmdb')

    log(f"Item Type: {item_type} | Name: {name}")
    log(f"SeriesName: '{series_name}' | Season: {season_num} | Episode: {episode_num}")
    log(f"TVDB ID: {tvdb_id} | TMDB ID: {tmdb_id}")

    # Movie
    if item_type == 'Movie':
        if not tmdb_id:
            log("ERROR: No TMDB ID for movie")
            return 'No TMDB ID', 400
        resp = requests.get(f"{RADARR_URL}/api/v3/movie?tmdbId={tmdb_id}", headers=RADARR_HEADERS)
        if resp.status_code != 200 or not resp.json():
            log("Movie not found in Radarr")
            return 'Not in Radarr', 200
        movie = resp.json()[0]
        movie_id = movie['id']
        log(f"Deleting movie '{movie['title']}' (ID: {movie_id}) from Radarr")
        del_resp = requests.delete(
            f"{RADARR_URL}/api/v3/movie/{movie_id}?deleteFiles=true&addImportExclusion=false",
            headers=RADARR_HEADERS
        )
        log(f"Radarr delete response: {del_resp.status_code}")
        log("Movie removed from Radarr")

    # TV
    elif item_type in ['Series', 'Season', 'Episode']:
        series = None
        if item_type == 'Episode' and tvdb_id:
            series = find_series_via_map(tvdb_id)
        if not series:
            use_tvdb = tvdb_id if item_type == 'Series' else None
            # For Series deletion, series_name is empty, so rely on TVDB ID
            series = find_series(use_tvdb, series_name if series_name else name)
        if not series:
            log("ERROR: Series not found in Sonarr")
            return 'Series not found', 404

        series_id = series['id']
        log(f"Processing with series: '{series['title']}' (Sonarr ID: {series_id})")

        if item_type == 'Series':
            log("Deleting entire series from Sonarr")
            del_resp = requests.delete(
                f"{SONARR_URL}/api/v3/series/{series_id}?deleteFiles=true&addImportExclusion=false",
                headers=SONARR_HEADERS
            )
            log(f"Series delete response: {del_resp.status_code}")
            log("Series removed from Sonarr")

        elif item_type == 'Season':
            log(f"Processing Season {season_num} deletion")
            updated = False
            for s in series['seasons']:
                if s['seasonNumber'] == season_num and s['monitored']:
                    s['monitored'] = False
                    updated = True
            if updated:
                requests.put(f"{SONARR_URL}/api/v3/series/{series_id}", json=series, headers=SONARR_HEADERS)
                log(f"Season {season_num} unmonitored")

            files_resp = requests.get(f"{SONARR_URL}/api/v3/episodefile?seriesId={series_id}", headers=SONARR_HEADERS)
            deleted_count = 0
            if files_resp.status_code == 200:
                for file in files_resp.json():
                    if file['seasonNumber'] == season_num:
                        requests.delete(f"{SONARR_URL}/api/v3/episodefile/{file['id']}", headers=SONARR_HEADERS)
                        deleted_count += 1
            log(f"Deleted {deleted_count} episode files from season {season_num}")
            log("Season processed")

        elif item_type == 'Episode':
            log(f"Processing Episode S{season_num}E{episode_num} deletion")
            eps_resp = requests.get(
                f"{SONARR_URL}/api/v3/episode?seriesId={series_id}&seasonNumber={season_num}",
                headers=SONARR_HEADERS
            )
            if eps_resp.status_code != 200:
                log("Failed to fetch episodes")
                return 'API error', 500
            episodes = eps_resp.json()
            target = next((e for e in episodes if e['episodeNumber'] == episode_num), None)
            if not target:
                log("Episode not found in Sonarr")
                return 'Not found', 200
            if target['monitored']:
                target['monitored'] = False
                requests.put(f"{SONARR_URL}/api/v3/episode/{target['id']}", json=target, headers=SONARR_HEADERS)
                log("Episode unmonitored")
            if target.get('hasFile'):
                file_id = target['episodeFileId']
                del_resp = requests.delete(f"{SONARR_URL}/api/v3/episodefile/{file_id}", headers=SONARR_HEADERS)
                log(f"Episode file deleted: {del_resp.status_code}")
            else:
                log("No episode file to delete")
            log("Episode processed")

    else:
        log(f"Unsupported item type: {item_type}")

    log("=== JELLYFIN WEBHOOK PROCESSED SUCCESSFULLY ===\n")
    return 'OK', 200

@app.route('/sonarr', methods=['POST'])
def sonarr_webhook():
    data = flask.request.get_json(force=True)
    log("=== SONARR WEBHOOK RECEIVED ===")
    log(json.dumps(data, indent=2) if data else "EMPTY")

    event = data.get('eventType')
    conn = get_db_connection()
    cur = conn.cursor()

    if event == 'Download' and 'episodes' in data:
        for ep in data['episodes']:
            tvdb = ep.get('tvdbId')
            if tvdb:
                cur.execute('INSERT OR REPLACE INTO episode_map (episode_tvdb_id, series_id) VALUES (?, ?)',
                            (str(tvdb), data['series']['id']))
                log(f"Map updated for downloaded episode TVDB {tvdb}")

    elif event == 'EpisodeFileDelete' and 'episodes' in data:
        for ep in data['episodes']:
            tvdb = ep.get('tvdbId')
            if tvdb:
                cur.execute('DELETE FROM episode_map WHERE episode_tvdb_id = ?', (str(tvdb),))
                log(f"Map entry removed for deleted episode TVDB {tvdb}")

    elif event == 'SeriesDelete' and 'series' in data:
        cur.execute('DELETE FROM episode_map WHERE series_id = ?', (data['series']['id'],))
        log(f"Cleared map entries for deleted series ID {data['series']['id']}")

    elif event == 'SeriesAdd' and 'series' in data:
        series_id = data['series']['id']
        eps_resp = requests.get(f"{SONARR_URL}/api/v3/episode?seriesId={series_id}", headers=SONARR_HEADERS)
        if eps_resp.status_code == 200:
            for ep in eps_resp.json():
                tvdb = ep.get('tvdbId')
                if tvdb:
                    cur.execute('INSERT OR IGNORE INTO episode_map (episode_tvdb_id, series_id) VALUES (?, ?)',
                                (str(tvdb), series_id))
                    log(f"Map added for new episode TVDB {tvdb}")

    conn.commit()
    conn.close()
    log("=== SONARR WEBHOOK PROCESSED ===\n")
    return 'OK', 200

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--rebuild', action='store_true', help='Force rebuild of provider map on startup')
    args = parser.parse_args()

    log("Jellyfin Sync Script starting - Version 1.3.0")

    conn = get_db_connection()
    cur = conn.cursor()
    
    cur.execute('''
        CREATE TABLE IF NOT EXISTS series (
            series_id INTEGER PRIMARY KEY,
            title TEXT NOT NULL,
            tvdb_id INTEGER,
            tmdb_id INTEGER,
            imdb_id TEXT
        )
    ''')
    cur.execute('''
        CREATE TABLE IF NOT EXISTS seasons (
            series_id INTEGER,
            season_number INTEGER,
            tvdb_id INTEGER,
            tmdb_id INTEGER,
            imdb_id TEXT,
            PRIMARY KEY (series_id, season_number),
            FOREIGN KEY (series_id) REFERENCES series (series_id)
        )
    ''')
    cur.execute('''
        CREATE TABLE IF NOT EXISTS episodes (
            episode_id INTEGER PRIMARY KEY,
            series_id INTEGER NOT NULL,
            season_number INTEGER NOT NULL,
            episode_number INTEGER NOT NULL,
            tvdb_id INTEGER,
            tmdb_id INTEGER,
            imdb_id TEXT,
            FOREIGN KEY (series_id) REFERENCES series (series_id),
            FOREIGN KEY (series_id, season_number) REFERENCES seasons (series_id, season_number)
        )
    ''')
    cur.execute('''
        CREATE TABLE IF NOT EXISTS movies (
            movie_id INTEGER PRIMARY KEY,
            title TEXT NOT NULL,
            tmdb_id INTEGER,
            imdb_id TEXT
        )
    ''')
    cur.execute('''
        CREATE TABLE IF NOT EXISTS episode_map (
            episode_tvdb_id TEXT PRIMARY KEY,
            series_id INTEGER NOT NULL,
            FOREIGN KEY (series_id) REFERENCES series (series_id)
        )
    ''')
    
    #upgrade_database_schema(conn)
    
    conn.commit()
    conn.close()

    if args.rebuild:
        build_provider_map()
    else:
        conn = get_db_connection()
        cur = conn.cursor()
        cur.execute('SELECT COUNT(*) FROM series')
        if cur.fetchone()[0] == 0:
            conn.close()
            build_provider_map()
        else:
            conn.close()
            log("Existing provider map loaded")

    if REBUILD_INTERVAL_MINUTES and REBUILD_INTERVAL_MINUTES > 0:
        thread = threading.Thread(target=periodic_rebuild, daemon=True)
        thread.start()

    log(f"Server listening on http://{LISTEN_HOST}:{LISTEN_PORT}")
    log("Endpoints: /webhook (Jellyfin) | /sonarr (Sonarr updates)")
    app.run(host=LISTEN_HOST, port=LISTEN_PORT, debug=False)
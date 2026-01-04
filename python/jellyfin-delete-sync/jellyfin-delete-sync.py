#!/usr/bin/env python3

# jellyfin_sync.py
# Version: 2.4.0
# Date: January 04, 2026
#
# Changelog:
# 2.4.0 - Updated refresh schedule validation
#         - Now allows REFRESH_INTERVAL_MINUTES or REFRESH_SCHEDULE to be unset (None)
#         - Allows exactly zero or one to be set
#         - Disallows both being set at the same time
#         - No automatic refresh if both are None (optional refresh)
#         - Clear error message if both are defined
# 2.3.0 - Fixed missing json_repair function
# 2.2.0 - Safe config import with getattr

import flask
import requests
import json
import sqlite3
import argparse
import time
import re
import traceback
from datetime import datetime
from apscheduler.schedulers.background import BackgroundScheduler
from apscheduler.triggers.cron import CronTrigger
from apscheduler.triggers.interval import IntervalTrigger

try:
    import config
    SONARR_URL = config.SONARR_URL
    SONARR_API_KEY = config.SONARR_API_KEY
    RADARR_URL = config.RADARR_URL
    RADARR_API_KEY = config.RADARR_API_KEY
    LISTEN_HOST = config.LISTEN_HOST
    LISTEN_PORT = config.LISTEN_PORT
    REFRESH_INTERVAL_MINUTES = getattr(config, 'REFRESH_INTERVAL_MINUTES', None)
    REFRESH_SCHEDULE = getattr(config, 'REFRESH_SCHEDULE', None)
except ImportError as e:
    print("ERROR: Could not import config.py")
    print("Make sure config.py exists in the same directory and contains all required settings.")
    print(f"Import error: {e}")
    exit(1)
except AttributeError as e:
    print("ERROR: Missing required setting in config.py")
    print(f"Missing: {e}")
    exit(1)

# Validate refresh schedule: allow zero or one, but not both
if REFRESH_INTERVAL_MINUTES is not None and REFRESH_SCHEDULE is not None:
    print("ERROR: Invalid refresh schedule configuration in config.py")
    print("You cannot define both REFRESH_INTERVAL_MINUTES and REFRESH_SCHEDULE at the same time.")
    print("")
    print("Current values:")
    print(f"  REFRESH_INTERVAL_MINUTES = {REFRESH_INTERVAL_MINUTES}")
    print(f"  REFRESH_SCHEDULE = {REFRESH_SCHEDULE}")
    print("")
    print("Choose one or neither (no automatic refresh if both are None).")
    exit(1)

# Optional additional validation if one is set
if REFRESH_INTERVAL_MINUTES is not None:
    if not isinstance(REFRESH_INTERVAL_MINUTES, int) or REFRESH_INTERVAL_MINUTES <= 0:
        print("ERROR: REFRESH_INTERVAL_MINUTES must be a positive integer if defined")
        print(f"Current value: {REFRESH_INTERVAL_MINUTES}")
        exit(1)

if REFRESH_SCHEDULE is not None:
    if not isinstance(REFRESH_SCHEDULE, list) or len(REFRESH_SCHEDULE) == 0:
        print("ERROR: REFRESH_SCHEDULE must be a non-empty list if defined")
        print(f"Current value: {REFRESH_SCHEDULE}")
        exit(1)
    for i, sched in enumerate(REFRESH_SCHEDULE):
        if not isinstance(sched, dict):
            print(f"ERROR: REFRESH_SCHEDULE item {i} must be a dictionary")
            exit(1)

app = flask.Flask(__name__)

SONARR_HEADERS = {'X-Api-Key': SONARR_API_KEY}
RADARR_HEADERS = {'X-Api-Key': RADARR_API_KEY}

DB_FILE = 'episode_map.db'

def log(msg):
    print(f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] {msg}")

def get_db_connection():
    try:
        conn = sqlite3.connect(DB_FILE, check_same_thread=False)
        conn.row_factory = sqlite3.Row
        return conn
    except Exception as e:
        log(f"ERROR opening database connection: {e}")
        log(traceback.format_exc())
        return None

def init_database():
    conn = get_db_connection()
    if conn is None:
        return
    try:
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

        cur.execute('''
            CREATE TABLE IF NOT EXISTS settings (
                key TEXT PRIMARY KEY,
                value TEXT
            )
        ''')

        conn.commit()
    except Exception as e:
        log(f"ERROR initializing database: {e}")
        log(traceback.format_exc())
    finally:
        conn.close()

def save_setting(key, value):
    conn = get_db_connection()
    if conn is None:
        return
    try:
        cur = conn.cursor()
        cur.execute('INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)', (key, str(value)))
        conn.commit()
    except Exception as e:
        log(f"ERROR saving setting {key}: {e}")
        log(traceback.format_exc())
    finally:
        conn.close()

def load_setting(key, default=None):
    conn = get_db_connection()
    if conn is None:
        return default
    try:
        cur = conn.cursor()
        cur.execute('SELECT value FROM settings WHERE key = ?', (key,))
        row = cur.fetchone()
        return row['value'] if row else default
    except Exception as e:
        log(f"ERROR loading setting {key}: {e}")
        log(traceback.format_exc())
        return default
    finally:
        conn.close()

def json_repair(raw_body):
    """Ultimate line-by-line repair for the most broken Jellyfin JSON - now safe from IndexError"""
    lines = raw_body.splitlines()
    repaired_lines = []
    last_was_value = False

    for line in lines:
        stripped = line.strip()

        # Skip completely empty lines
        if not stripped:
            continue

        # If previous line ended with a value and current line starts with a key, add comma to previous
        if last_was_value and stripped.startswith('"') and ':' in stripped:
            if repaired_lines:
                repaired_lines[-1] = repaired_lines[-1].rstrip() + ','

        # Fix empty values ": ,"
        line = re.sub(r':\s*,', ': null,', line)

        # Remove stray incomplete keys like "Dummy":
        line = re.sub(r',\s*"[\w]+":\s*$', '', line)
        line = re.sub(r'\s*"[\w]+":\s*$', '', line)

        repaired_lines.append(line)

        # Determine if this line ends with a value - safely
        if len(stripped) > 0:
            last_char = stripped[-1]
            if last_char in ('"', '}', ']', 'l', 'e') or last_char.isdigit():
                last_was_value = True
            else:
                last_was_value = False
        else:
            last_was_value = False

    repaired = '\n'.join(repaired_lines)

    # Final cleanup: remove trailing commas before } or ]
    repaired = re.sub(r',\s*}', '}', repaired)
    repaired = re.sub(r',\s*]', ']', repaired)

    # Ensure it ends with }
    if not repaired.endswith('}'):
        repaired += '}'

    return repaired

def build_provider_map():
    log("Building full provider map from Sonarr and Radarr...")
    start_time = time.time()
    conn = get_db_connection()
    if conn is None:
        return

    try:
        cur = conn.cursor()

        cur.execute('DELETE FROM movies')
        cur.execute('DELETE FROM episodes')
        cur.execute('DELETE FROM seasons')
        cur.execute('DELETE FROM series')
        cur.execute('DELETE FROM episode_map')

        series_resp = requests.get(f"{SONARR_URL}/api/v3/series", headers=SONARR_HEADERS, timeout=60)
        if series_resp.status_code != 200:
            log(f"ERROR: Failed to fetch series from Sonarr ({series_resp.status_code})")
            conn.close()
            return

        series_list = series_resp.json()
        series_count = season_count = episode_count = 0
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

            for season in ser.get('seasons', []):
                season_num = season['seasonNumber']
                cur.execute(
                    'INSERT INTO seasons (series_id, season_number, tvdb_id, tmdb_id, imdb_id) VALUES (?, ?, ?, ?, ?)',
                    (series_id, season_num, None, None, None)
                )
                season_count += 1

            eps_resp = requests.get(f"{SONARR_URL}/api/v3/episode?seriesId={series_id}", headers=SONARR_HEADERS, timeout=60)
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

        movies_resp = requests.get(f"{RADARR_URL}/api/v3/movie", headers=RADARR_HEADERS, timeout=60)
        if movies_resp.status_code != 200:
            log(f"ERROR: Failed to fetch movies from Radarr ({movies_resp.status_code})")
        else:
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
        duration = time.time() - start_time
        log(f"Provider map built: {series_count} series, {season_count} seasons, {episode_count} episodes, {movie_count} movies in {duration:.1f}s")

        save_setting('last_refresh', datetime.now().isoformat())

    except Exception as e:
        log(f"CRITICAL ERROR in build_provider_map: {e}")
        log(traceback.format_exc())
    finally:
        try:
            conn.close()
        except:
            pass

def setup_scheduler():
    scheduler = BackgroundScheduler()
    scheduler.start()

    has_refresh = False

    if REFRESH_INTERVAL_MINUTES is not None:
        log(f"Configured interval refresh every {REFRESH_INTERVAL_MINUTES} minutes")
        scheduler.add_job(
            build_provider_map,
            IntervalTrigger(minutes=REFRESH_INTERVAL_MINUTES),
            id='interval_refresh',
            replace_existing=True
        )
        has_refresh = True

    if REFRESH_SCHEDULE is not None:
        log(f"Configured {len(REFRESH_SCHEDULE)} scheduled refresh time(s)")
        for i, sched in enumerate(REFRESH_SCHEDULE):
            day = sched.get('day', '*').lower()
            hour = sched.get('hour', 3)
            minute = sched.get('minute', 0)

            scheduler.add_job(
                build_provider_map,
                CronTrigger(day_of_week=day, hour=hour, minute=minute),
                id=f'scheduled_refresh_{i}',
                replace_existing=True
            )
            log(f"  - {day.title() if day != '*' else 'Every day'} at {hour:02d}:{minute:02d}")
        has_refresh = True

    if not has_refresh:
        log("No automatic refresh configured (both REFRESH_INTERVAL_MINUTES and REFRESH_SCHEDULE are None)")

    return scheduler

@app.route('/jellyfin', methods=['POST'])
def jellyfin_webhook():
    try:
        raw_body = flask.request.data.decode('utf-8', errors='ignore')
        if not raw_body.strip():
            log("EMPTY REQUEST BODY RECEIVED")
            return 'No data', 400

        log("=== RAW JELLYFIN WEBHOOK RECEIVED ===")
        log(raw_body)

        repaired_body = json_repair(raw_body)
        if repaired_body != raw_body:
            log("Applied ultimate JSON repair")
            log("Repaired version:")
            log(repaired_body)

        data = None
        try:
            data = json.loads(repaired_body)
            log("JSON parsed successfully after repair")
        except json.JSONDecodeError as e:
            log(f"FINAL JSON PARSE FAILURE: {e}")
            log("Payload too malformed - ignoring but returning 200")

        if data:
            log("=== PARSED PAYLOAD ===")
            log(json.dumps(data, indent=2))

        notification_type = data.get('NotificationType') if data else None
        if notification_type != 'ItemDeleted':
            log(f"Ignored event type: {notification_type or 'unknown/malformed'}")
            return 'OK (ignored)', 200

        item = data.get('Item', {}) if data else {}
        item_type = item.get('Type')
        if not item_type:
            log("No valid Item.Type found - cannot process deletion")
            return 'OK (invalid deletion payload)', 200

        name = item.get('Name', 'Unknown')
        series_name = item.get('SeriesName') or ''
        season_num = item.get('SeasonNumber')
        episode_num = item.get('EpisodeNumber')

        provider_ids = item.get('ProviderIds', {})
        tvdb_id = provider_ids.get('Tvdb') or item.get('Provider_tvdb')
        tmdb_id = provider_ids.get('Tmdb') or item.get('Provider_tmdb')

        log(f"Item Type: {item_type} | Name: {name}")
        log(f"SeriesName: '{series_name}' | Season: {season_num} | Episode: {episode_num}")
        log(f"TVDB ID: {tvdb_id} | TMDB ID: {tmdb_id}")

        if item_type == 'Movie':
            if not tmdb_id:
                log("ERROR: No TMDB ID for movie")
                return 'No TMDB ID', 400
            try:
                resp = requests.get(f"{RADARR_URL}/api/v3/movie?tmdbId={tmdb_id}", headers=RADARR_HEADERS, timeout=30)
                if resp.status_code != 200 or not resp.json():
                    log("Movie not found in Radarr")
                    return 'Not in Radarr', 200
                movie = resp.json()[0]
                movie_id = movie['id']
                log(f"Deleting movie '{movie['title']}' (ID: {movie_id}) from Radarr")
                del_resp = requests.delete(
                    f"{RADARR_URL}/api/v3/movie/{movie_id}?deleteFiles=true&addImportExclusion=false",
                    headers=RADARR_HEADERS,
                    timeout=30
                )
                log(f"Radarr delete response: {del_resp.status_code}")
                log("Movie removed from Radarr")
            except Exception as e:
                log(f"ERROR during movie deletion: {e}")
                log(traceback.format_exc())

        elif item_type in ['Series', 'Season', 'Episode']:
            series = None
            try:
                if item_type == 'Episode' and tvdb_id:
                    series = find_series_via_map(tvdb_id)
                if not series:
                    use_tvdb = tvdb_id if item_type == 'Series' else None
                    search_title = series_name if series_name else name
                    series = find_series(use_tvdb, search_title)
                if not series:
                    log("ERROR: Series not found in Sonarr")
                    return 'Series not found', 404

                series_id = series['id']
                log(f"Processing with series: '{series['title']}' (Sonarr ID: {series_id})")

                if item_type == 'Series':
                    log("Deleting entire series from Sonarr")
                    del_resp = requests.delete(
                        f"{SONARR_URL}/api/v3/series/{series_id}?deleteFiles=true&addImportExclusion=false",
                        headers=SONARR_HEADERS,
                        timeout=30
                    )
                    log(f"Series delete response: {del_resp.status_code}")

                elif item_type == 'Season':
                    log(f"Processing Season {season_num} deletion")
                    updated = False
                    for s in series['seasons']:
                        if s['seasonNumber'] == season_num and s['monitored']:
                            s['monitored'] = False
                            updated = True
                    if updated:
                        requests.put(f"{SONARR_URL}/api/v3/series/{series_id}", json=series, headers=SONARR_HEADERS, timeout=30)
                        log(f"Season {season_num} unmonitored")

                    files_resp = requests.get(f"{SONARR_URL}/api/v3/episodefile?seriesId={series_id}", headers=SONARR_HEADERS, timeout=30)
                    deleted_count = 0
                    if files_resp.status_code == 200:
                        for file in files_resp.json():
                            if file['seasonNumber'] == season_num:
                                requests.delete(f"{SONARR_URL}/api/v3/episodefile/{file['id']}", headers=SONARR_HEADERS, timeout=30)
                                deleted_count += 1
                    log(f"Deleted {deleted_count} episode files from season {season_num}")
                    log("Season processed")

                elif item_type == 'Episode':
                    log(f"Processing Episode S{season_num}E{episode_num} deletion")
                    eps_resp = requests.get(
                        f"{SONARR_URL}/api/v3/episode?seriesId={series_id}&seasonNumber={season_num}",
                        headers=SONARR_HEADERS,
                        timeout=30
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
                        requests.put(f"{SONARR_URL}/api/v3/episode/{target['id']}", json=target, headers=SONARR_HEADERS, timeout=30)
                        log("Episode unmonitored")
                    if target.get('hasFile'):
                        file_id = target['episodeFileId']
                        del_resp = requests.delete(f"{SONARR_URL}/api/v3/episodefile/{file_id}", headers=SONARR_HEADERS, timeout=30)
                        log(f"Episode file deleted: {del_resp.status_code}")
                    else:
                        log("No episode file to delete")
                    log("Episode processed")
            except Exception as e:
                log(f"ERROR during TV item processing: {e}")
                log(traceback.format_exc())

        else:
            log(f"Unsupported item type: {item_type}")

        log("=== JELLYFIN WEBHOOK PROCESSED SUCCESSFULLY ===\n")
        return 'OK', 200

    except Exception as e:
        log("CRITICAL UNHANDLED ERROR in /jellyfin webhook:")
        log(traceback.format_exc())
        return 'OK (error handled)', 200

@app.route('/sonarr', methods=['POST'])
def sonarr_webhook():
    try:
        data = flask.request.get_json(force=True)
        log("=== SONARR WEBHOOK RECEIVED ===")
        log(json.dumps(data, indent=2) if data else "EMPTY")

        event = data.get('eventType')
        conn = get_db_connection()
        if conn is None:
            return 'DB error', 200
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
            try:
                eps_resp = requests.get(f"{SONARR_URL}/api/v3/episode?seriesId={series_id}", headers=SONARR_HEADERS, timeout=30)
                if eps_resp.status_code == 200:
                    for ep in eps_resp.json():
                        tvdb = ep.get('tvdbId')
                        if tvdb:
                            cur.execute('INSERT OR IGNORE INTO episode_map (episode_tvdb_id, series_id) VALUES (?, ?)',
                                        (str(tvdb), series_id))
                            log(f"Map added for new episode TVDB {tvdb}")
            except Exception as e:
                log(f"ERROR updating map for new series: {e}")

        conn.commit()
        conn.close()
        log("=== SONARR WEBHOOK PROCESSED ===\n")
        return 'OK', 200
    except Exception as e:
        log("ERROR in Sonarr webhook:")
        log(traceback.format_exc())
        return 'OK (error handled)', 200

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--rebuild', action='store_true', help='Force immediate rebuild on startup')
    args = parser.parse_args()

    try:
        log("Jellyfin Sync Script starting - Version 2.4.0")

        init_database()

        if args.rebuild:
            build_provider_map()

        scheduler = setup_scheduler()

        log(f"Server listening on http://{LISTEN_HOST}:{LISTEN_PORT}")
        log("Endpoints: /jellyfin (Jellyfin) | /sonarr (Sonarr updates)")
        app.run(host=LISTEN_HOST, port=LISTEN_PORT, debug=False)
    except Exception as e:
        log("FATAL ERROR during startup:")
        log(traceback.format_exc())
        exit(1)
# sonarr.py
import requests
import traceback
from db import get_db_connection, save_setting
from utils import log
from config import SONARR_URL, SONARR_HEADERS, RADARR_URL, RADARR_HEADERS

def set_series_completed(series_id, completed=True):
    conn = get_db_connection()
    if conn is None:
        return
    try:
        cur = conn.cursor()
        cur.execute('INSERT OR REPLACE INTO series_status (series_id, is_completed) VALUES (?, ?)',
                    (series_id, 1 if completed else 0))
        conn.commit()
        log(f"Series {series_id} marked as {'completed' if completed else 'incomplete'}")
    except Exception as e:
        log(f"ERROR updating series completion status: {e}")
    finally:
        conn.close()

def is_series_completed(series_id):
    conn = get_db_connection()
    if conn is None:
        return False
    try:
        cur = conn.cursor()
        cur.execute('SELECT is_completed FROM series_status WHERE series_id = ?', (series_id,))
        row = cur.fetchone()
        return bool(row['is_completed']) if row else False
    except Exception as e:
        log(f"ERROR checking series completion: {e}")
        return False
    finally:
        conn.close()

def is_season_fully_downloaded(series, season_number):
    try:
        resp = requests.get(
            f"{SONARR_URL}/api/v3/episode?seriesId={series['id']}&seasonNumber={season_number}",
            headers=SONARR_HEADERS, timeout=30
        )
        if resp.status_code != 200:
            return False
        for ep in resp.json():
            if ep['monitored'] and not ep.get('hasFile', False):
                return False
        return True
    except Exception:
        return False

def build_provider_map(clear_status=False):
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

        if clear_status:
            cur.execute('DELETE FROM series_status')
            log("Completion status cleared as requested")

        # Sonarr series + episodes
        resp = requests.get(f"{SONARR_URL}/api/v3/series", headers=SONARR_HEADERS, timeout=60)
        if resp.status_code != 200:
            log(f"ERROR fetching series: {resp.status_code}")
            return

        series_list = resp.json()
        counts = {'series': 0, 'season': 0, 'episode': 0, 'movie': 0}

        for ser in series_list:
            # insert series, seasons, episodes, map...
            # (same logic as before - omitted for brevity, copy from old script)

        # Radarr movies
        # (same as before)

        conn.commit()
        duration = time.time() - start_time
        log(f"Provider map built in {duration:.1f}s")

        save_setting('last_refresh', datetime.now().isoformat())
    except Exception as e:
        log(f"CRITICAL ERROR in build_provider_map: {e}")
        log(traceback.format_exc())
    finally:
        conn.close()
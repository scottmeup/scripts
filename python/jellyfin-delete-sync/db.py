# db.py
import sqlite3
import traceback
from utils import log

DB_FILE = 'episode_map.db'

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

        # Main tables
        tables = [
            '''series (series_id INTEGER PRIMARY KEY, title TEXT NOT NULL, tvdb_id INTEGER, tmdb_id INTEGER, imdb_id TEXT)''',
            '''seasons (series_id INTEGER, season_number INTEGER, tvdb_id INTEGER, tmdb_id INTEGER, imdb_id TEXT, PRIMARY KEY (series_id, season_number))''',
            '''episodes (episode_id INTEGER PRIMARY KEY, series_id INTEGER NOT NULL, season_number INTEGER NOT NULL, episode_number INTEGER NOT NULL, tvdb_id INTEGER, tmdb_id INTEGER, imdb_id TEXT)''',
            '''movies (movie_id INTEGER PRIMARY KEY, title TEXT NOT NULL, tmdb_id INTEGER, imdb_id TEXT)''',
            '''episode_map (episode_tvdb_id TEXT PRIMARY KEY, series_id INTEGER NOT NULL)''',
            '''settings (key TEXT PRIMARY KEY, value TEXT)''',
            '''series_status (series_id INTEGER PRIMARY KEY, is_completed INTEGER NOT NULL DEFAULT 0)'''
        ]

        for table_def in tables:
            cur.execute(f"CREATE TABLE IF NOT EXISTS {table_def}")

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
    finally:
        conn.close()

# build_provider_map moved to sonarr.py for clarity (imports db functions)
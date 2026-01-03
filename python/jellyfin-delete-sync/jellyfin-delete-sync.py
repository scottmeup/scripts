# Jellyfin Deletion Sync Script
# This script sets up a webhook receiver using Flask to listen for deletion events from Jellyfin.
# It then uses the Sonarr and Radarr APIs to delete and remove the corresponding items.
# Assumptions:
# - Jellyfin webhook payload includes fields like 'NotificationType', 'ItemType', 'Provider_tvdb' (for TV series/season/episode, assuming series TVDB ID),
#   'Provider_tmdb' (for movies), 'SeriesName', 'SeasonNumber', 'EpisodeNumber', 'Name'.
# - Series names are unique in Sonarr for matching via name (fallback for seasons and episodes).
# - Replace placeholders with your actual Sonarr/Radarr URLs and API keys.
# - Jellyfin is configured to send webhooks to http://your-debian-host:5000/webhook for Item Removed events.
# - When deleting in Jellyfin, if files are deleted, setting deleteFiles=true in APIs will attempt to delete but fail gracefully if files are gone.

# Installation on Debian 12:
# sudo apt update
# sudo apt install python3-pip
# pip3 install flask requests
# Then run: python3 this_script.py

import flask
import requests

app = flask.Flask(__name__)

@app.route('/webhook', methods=['POST'])
def handle_webhook():
    data = flask.request.get_json()
    if not data or data.get('NotificationType') != 'ItemRemoved':
        return 'Ignored', 200

    # Adjust if the structure is different; assuming top-level fields or under 'Item'
    item_type = data.get('ItemType') or data.get('Type')
    provider_tvdb = data.get('Provider_tvdb')
    provider_tmdb = data.get('Provider_tmdb')
    series_name = data.get('SeriesName')
    season_number = data.get('SeasonNumber')
    episode_number = data.get('EpisodeNumber')

    # Configure your Sonarr and Radarr details
    sonarr_url = 'http://localhost:8989/api/v3'  # Replace with your Sonarr URL
    sonarr_api_key = 'b8e59275a15b4016b763ab13ae5dbdbc'       # Replace with your Sonarr API key
    radarr_url = 'http://localhost:7878/api/v3'  # Replace with your Radarr URL
    radarr_api_key = '9d0f281b137e47beb54c82f5ef736a12'       # Replace with your Radarr API key

    headers_sonarr = {'X-Api-Key': sonarr_api_key}
    headers_radarr = {'X-Api-Key': radarr_api_key}

    if item_type == 'Series':
        if provider_tvdb:
            # Find series by TVDB ID
            response = requests.get(f"{sonarr_url}/series?tvdbId={provider_tvdb}", headers=headers_sonarr)
            if response.status_code == 200:
                series_list = response.json()
                if series_list:
                    series_id = series_list[0]['id']
                    # Delete series and files
                    requests.delete(f"{sonarr_url}/series/{series_id}?deleteFiles=true&addImportExclusion=false", headers=headers_sonarr)

    elif item_type == 'Season':
        if series_name and season_number is not None:
            # Find series by name (fallback)
            response = requests.get(f"{sonarr_url}/series", headers=headers_sonarr)
            if response.status_code == 200:
                series_list = response.json()
                series = next((s for s in series_list if s['title'] == series_name), None)
                if series:
                    series_id = series['id']
                    # Get series details and unmonitor the season
                    response = requests.get(f"{sonarr_url}/series/{series_id}", headers=headers_sonarr)
                    series_data = response.json()
                    for s in series_data['seasons']:
                        if s['seasonNumber'] == season_number:
                            s['monitored'] = False
                    requests.put(f"{sonarr_url}/series/{series_id}", json=series_data, headers=headers_sonarr)
                    # Delete episode files for the season
                    response = requests.get(f"{sonarr_url}/episodefile?seriesId={series_id}", headers=headers_sonarr)
                    if response.status_code == 200:
                        episode_files = response.json()
                        for file in episode_files:
                            if file['seasonNumber'] == season_number:
                                requests.delete(f"{sonarr_url}/episodefile/{file['id']}", headers=headers_sonarr)

    elif item_type == 'Episode':
        if series_name and season_number is not None and episode_number is not None:
            # Find series by name
            response = requests.get(f"{sonarr_url}/series", headers=headers_sonarr)
            if response.status_code == 200:
                series_list = response.json()
                series = next((s for s in series_list if s['title'] == series_name), None)
                if series:
                    series_id = series['id']
                    # Get episodes in the season
                    response = requests.get(f"{sonarr_url}/episode?seriesId={series_id}&seasonNumber={season_number}", headers=headers_sonarr)
                    if response.status_code == 200:
                        episodes = response.json()
                        episode = next((e for e in episodes if e['episodeNumber'] == episode_number), None)
                        if episode:
                            # Unmonitor the episode
                            episode_update = {'id': episode['id'], 'monitored': False}
                            # Copy other required fields if needed (Sonarr may require full object, but minimal works)
                            response = requests.get(f"{sonarr_url}/episode/{episode['id']}", headers=headers_sonarr)
                            full_episode = response.json()
                            full_episode['monitored'] = False
                            requests.put(f"{sonarr_url}/episode/{episode['id']}", json=full_episode, headers=headers_sonarr)
                            # Delete file if exists
                            if episode.get('hasFile'):
                                episode_file_id = episode['episodeFileId']
                                requests.delete(f"{sonarr_url}/episodefile/{episode_file_id}", headers=headers_sonarr)

    elif item_type == 'Movie':
        if provider_tmdb:
            # Find movie by TMDB ID
            response = requests.get(f"{radarr_url}/movie?tmdbId={provider_tmdb}", headers=headers_radarr)
            if response.status_code == 200:
                movie_list = response.json()
                if movie_list:
                    movie_id = movie_list[0]['id']
                    # Delete movie and files
                    requests.delete(f"{radarr_url}/movie/{movie_id}?deleteFiles=true&addImportExclusion=false", headers=headers_radarr)

    return 'OK', 200

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000, debug=True)  # Run on all interfaces, port 5000; remove debug in production

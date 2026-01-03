import flask
import requests
import json

app = flask.Flask(__name__)

@app.route('/webhook', methods=['POST'])
def handle_webhook():
    data = flask.request.get_json(force=True)  # Force parse even if content-type wrong
    print("\n=== WEBHOOK RECEIVED ===")
    if data:
        print(json.dumps(data, indent=2))  # Pretty-print the full payload
    else:
        print("No JSON payload received!")
        return 'No data', 400

    # Determine notification type
    notification_type = data.get('NotificationType')
    print(f"NotificationType: {notification_type}")

    if notification_type != 'ItemDeleted':  # Correct type name based on plugin source
        print("Ignored: Not an ItemDeleted event")
        return 'Ignored', 200

    # Item data might be under 'Item' key or top-level
    item = data.get('Item', data)

    item_type = item.get('Type') or item.get('ItemType')
    print(f"Detected Item Type: {item_type}")

    # Extract identifiers
    provider_tvdb = None
    provider_tmdb = None
    if 'ProviderIds' in item:
        provider_tvdb = item['ProviderIds'].get('Tvdb')
        provider_tmdb = item['ProviderIds'].get('Tmdb')
    else:
        provider_tvdb = item.get('Provider_tvdb')
        provider_tmdb = item.get('Provider_tmdb')

    series_name = item.get('SeriesName')
    season_number = item.get('SeasonNumber')
    episode_number = item.get('EpisodeNumber')
    name = item.get('Name')

    print(f"TVDB ID: {provider_tvdb}, TMDB ID: {provider_tmdb}")
    print(f"Series: {series_name}, Season: {season_number}, Episode: {episode_number}, Name: {name}")

    # Configure your Sonarr and Radarr details HERE
    sonarr_url = 'http://192.168.1.15:8989/api/v3'  # CHANGE IF NEEDED
    sonarr_api_key = 'your-sonarr-api-key'       # REPLACE
    radarr_url = 'http://192.168.1.15:7878/api/v3'  # CHANGE IF NEEDED
    radarr_api_key = 'your-radarr-api-key'       # REPLACE

    headers_sonarr = {'X-Api-Key': sonarr_api_key}
    headers_radarr = {'X-Api-Key': radarr_api_key}

    if item_type == 'Series':
        print("Processing SERIES deletion")
        if provider_tvdb:
            url = f"{sonarr_url}/series?tvdbId={provider_tvdb}"
            print(f"Fetching series from Sonarr: {url}")
            resp = requests.get(url, headers=headers_sonarr)
            print(f"Sonarr response: {resp.status_code} - {resp.text[:200]}")
            if resp.status_code == 200 and resp.json():
                series_id = resp.json()[0]['id']
                del_url = f"{sonarr_url}/series/{series_id}?deleteFiles=true"
                print(f"Deleting series ID {series_id} from Sonarr")
                del_resp = requests.delete(del_url, headers=headers_sonarr)
                print(f"Delete response: {del_resp.status_code} - {del_resp.text}")
        else:
            print("No TVDB ID for series - cannot delete reliably")

    elif item_type == 'Season':
        print("Processing SEASON deletion")
        # Implementation similar - but for now logging placeholder
        print("Season deletion logic here (unmonitor season + delete episode files)")

    elif item_type == 'Episode':
        print("Processing EPISODE deletion")
        # Similar logic with logging

    elif item_type == 'Movie':
        print("Processing MOVIE deletion")
        if provider_tmdb:
            url = f"{radarr_url}/movie?tmdbId={provider_tmdb}"
            print(f"Fetching movie from Radarr: {url}")
            resp = requests.get(url, headers=headers_radarr)
            print(f"Radarr response: {resp.status_code} - {resp.text[:200]}")
            if resp.status_code == 200 and resp.json():
                movie_id = resp.json()[0]['id']
                del_url = f"{radarr_url}/movie/{movie_id}?deleteFiles=true"
                print(f"Deleting movie ID {movie_id} from Radarr")
                del_resp = requests.delete(del_url, headers=headers_radarr)
                print(f"Delete response: {del_resp.status_code} - {del_resp.text}")
        else:
            print("No TMDB ID for movie - cannot delete reliably")

    else:
        print(f"Unsupported item type: {item_type}")

    print("=== END PROCESSING ===\n")
    return 'OK', 200

if __name__ == '__main__':
    print("Starting webhook listener on http://0.0.0.0:5000/webhook")
    app.run(host='0.0.0.0', port=5000, debug=False)  # debug=False to avoid double logs

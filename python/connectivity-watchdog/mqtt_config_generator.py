#!/usr/bin/env python3

import re
import sys
import requests
from bs4 import BeautifulSoup
from urllib.parse import urlparse


def is_valid_fqdn(hostname):
    """Check if a string is a valid FQDN."""
    if not hostname or len(hostname) > 255:
        return False
    
    if hostname.endswith('.'):
        hostname = hostname[:-1]
    
    fqdn_pattern = re.compile(
        r'^(?!-)[A-Za-z0-9-]{1,63}(?<!-)(\.[A-Za-z0-9-]{1,63})*\.[A-Za-z]{2,}$'
    )
    
    return bool(fqdn_pattern.match(hostname))


def extract_ports(port_text):
    """Extract numeric port numbers from text."""
    if not port_text:
        return []
    
    numbers = re.findall(r'\b\d+\b', port_text)
    
    ports = []
    for num in numbers:
        port = int(num)
        if 1 <= port <= 65535:
            ports.append(port)
    
    return ports


def scrape_mqtt_brokers(url):
    """Scrape MQTT brokers from the public brokers wiki page."""
    print(f"Fetching {url}...")
    
    headers = {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'
    }
    
    try:
        response = requests.get(url, headers=headers, timeout=10)
        response.raise_for_status()
    except requests.RequestException as e:
        print(f"Error fetching URL: {e}", file=sys.stderr)
        return []
    
    soup = BeautifulSoup(response.content, 'html.parser')
    
    wiki_body = soup.find('div', class_='markdown-body')
    if not wiki_body:
        wiki_body = soup.find('div', id='wiki-body')
    
    if wiki_body:
        tables = wiki_body.find_all('table')
    else:
        tables = soup.find_all('table')
    
    print(f"Found {len(tables)} tables")
    
    if len(tables) == 0:
        tables = soup.find_all('table', role='table')
        print(f"Found {len(tables)} tables with role='table'")
    
    if len(tables) == 0:
        print("\nNo tables found. Saving HTML to debug.html...")
        with open('debug.html', 'w', encoding='utf-8') as f:
            f.write(response.text)
        print("Check debug.html to see what was retrieved")
        return []
    
    brokers = []
    
    for table_idx, table in enumerate(tables, 1):
        print(f"\nProcessing table {table_idx}...")
        rows = table.find_all('tr')
        
        if len(rows) < 1:
            continue
        
        # Build a dictionary from rows where first cell is header
        data = {}
        for row in rows:
            cols = row.find_all(['td', 'th'])
            if len(cols) >= 2:
                key = cols[0].get_text(strip=True).lower()
                value = cols[1].get_text(strip=True)
                data[key] = value
        
        print(f"  Found fields: {list(data.keys())}")
        
        # Look for address field
        address_text = None
        for key in data:
            if 'address' in key or 'host' in key or 'broker' in key:
                address_text = data[key]
                print(f"  Using address from '{key}': {address_text}")
                break
        
        if not address_text:
            print(f"  No address field found, skipping")
            continue
        
        # Look for port field
        port_text = None
        for key in data:
            if 'port' in key:
                port_text = data[key]
                print(f"  Using port from '{key}': {port_text}")
                break
        
        # Extract hostname
        hostname = address_text
        if '://' in hostname:
            parsed = urlparse(hostname)
            hostname = parsed.netloc or parsed.path
        
        hostname = hostname.split(':')[0]
        
        if not is_valid_fqdn(hostname):
            print(f"  Invalid FQDN: {address_text}")
            continue
        
        # Extract ports
        ports = []
        if port_text:
            ports = extract_ports(port_text)
        
        if not ports:
            ports = [1883]
        
        for port in ports:
            brokers.append((hostname, port))
            print(f"  Found: {hostname}:{port}")
    
    return brokers


def get_manual_entries():
    """Get manual broker entries from user."""
    print("\n=== Manual Entry Mode ===")
    print("Enter MQTT brokers manually (one per line)")
    print("Format: hostname:port or just hostname (default port 1883)")
    print("Press Enter with empty line when done")
    print()
    
    entries = []
    
    while True:
        try:
            line = input("Broker (or Enter to finish): ").strip()
            
            if not line:
                break
            
            if ':' in line:
                parts = line.rsplit(':', 1)
                hostname = parts[0].strip()
                try:
                    port = int(parts[1].strip())
                except ValueError:
                    print(f"Invalid port number: {parts[1]}")
                    continue
            else:
                hostname = line
                port = 1883
            
            if not is_valid_fqdn(hostname):
                print(f"Invalid hostname: {hostname}")
                continue
            
            if not (1 <= port <= 65535):
                print(f"Invalid port number: {port}")
                continue
            
            entries.append((hostname, port))
            print(f"  Added: {hostname}:{port}")
            
        except EOFError:
            break
        except KeyboardInterrupt:
            print("\nCancelled")
            break
    
    return entries


def generate_config(brokers, output_file):
    """Generate config file with commented entries."""
    
    seen = set()
    unique_brokers = []
    for broker in brokers:
        if broker not in seen:
            seen.add(broker)
            unique_brokers.append(broker)
    
    print(f"\nGenerating config with {len(unique_brokers)} unique brokers...")
    
    with open(output_file, 'w') as f:
        f.write("# MQTT Broker Configuration\n")
        f.write("# Format: hostname:port\n")
        f.write("# Uncomment (remove #) to enable a broker\n")
        f.write("#\n")
        f.write("# Generated from: https://github.com/mqtt/mqtt.org/wiki/public_brokers\n")
        f.write("\n")
        
        for hostname, port in unique_brokers:
            f.write(f"# {hostname}:{port}\n")
    
    print(f"Config written to: {output_file}")
    print(f"\nTo use a broker, edit {output_file} and uncomment the desired entries")


def main():
    url = "https://github.com/mqtt/mqtt.org/wiki/public_brokers"
    output_file = "mqtt_brokers.conf"
    
    if len(sys.argv) > 1:
        output_file = sys.argv[1]
    
    brokers = scrape_mqtt_brokers(url)
    
    print(f"\nFound {len(brokers)} broker entries from web")
    
    manual = get_manual_entries()
    
    if manual:
        print(f"Added {len(manual)} manual entries")
        brokers.extend(manual)
    
    if brokers:
        generate_config(brokers, output_file)
    else:
        print("No brokers to write!", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
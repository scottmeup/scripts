# utils.py
import re
from datetime import datetime

def log(msg):
    print(f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] {msg}")

def json_repair(raw_body):
    """Line-by-line repair for broken Jellyfin JSON"""
    lines = raw_body.splitlines()
    repaired_lines = []
    last_was_value = False

    for line in lines:
        stripped = line.strip()
        if not stripped:
            continue

        if last_was_value and stripped.startswith('"') and ':' in stripped:
            if repaired_lines:
                repaired_lines[-1] = repaired_lines[-1].rstrip() + ','

        line = re.sub(r':\s*,', ': null,', line)
        line = re.sub(r',\s*"[\w]+":\s*$', '', line)
        line = re.sub(r'\s*"[\w]+":\s*$', '', line)

        repaired_lines.append(line)

        if len(stripped) > 0:
            last_char = stripped[-1]
            if last_char in ('"', '}', ']', 'l', 'e') or last_char.isdigit():
                last_was_value = True
            else:
                last_was_value = False
        else:
            last_was_value = False

    repaired = '\n'.join(repaired_lines)
    repaired = re.sub(r',\s*}', '}', repaired)
    repaired = re.sub(r',\s*]', ']', repaired)

    if not repaired.endswith('}'):
        repaired += '}'

    return repaired
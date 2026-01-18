#!/usr/bin/env bash
#
# extract_transit_stops.sh
# Usage:
#   ./extract_transit_stops.sh transit_lines.json transit_stops.json
#
# Extracts the ordered stop sequence from a Google Maps transit/lines RPC response.

set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "Usage: $0 <input_transit_lines_json> <output_stops_json>" >&2
  exit 1
fi

IN="$1"
OUT="$2"

if [ ! -f "$IN" ]; then
  echo "Input file not found: $IN" >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "Error: python3 is required but not installed." >&2
  exit 1
fi

python3 - <<'PY' "$IN" "$OUT"
import json
import sys
from typing import Any, Dict, List, Optional, Tuple

in_path = sys.argv[1]
out_path = sys.argv[2]

raw = open(in_path, 'r', encoding='utf-8').read()
lines = raw.splitlines()
if lines and lines[0].strip() == ")]}'":
    raw_json = "\n".join(lines[1:])
else:
    raw_json = raw

data = json.loads(raw_json)


def looks_like_timed_stop_entry(e: Any) -> bool:
    """Stop entries in the *final sequence* contain a time array like:

      [1768735525, "Asia/Calcutta", "16:55", 19800, 1768735500]

    We use this as the key signal so we don't pick the big master stop list.
    """
    if not isinstance(e, list) or not e:
        return False
    if not isinstance(e[0], str):
        return False
    s = e[0]
    if s.startswith('0x') or s.startswith('http') or s.startswith('//'):
        return False

    for item in e:
        if (
            isinstance(item, list)
            and len(item) >= 3
            and isinstance(item[1], str)
            and item[1] == "Asia/Calcutta"
            and isinstance(item[2], str)
            and (":" in item[2])
        ):
            return True

    return False


def extract_time(stop_entry: List[Any]) -> Optional[str]:
    # Returns the first time string we find in a time-array.
    for item in stop_entry:
        if (
            isinstance(item, list)
            and len(item) >= 3
            and isinstance(item[1], str)
            and item[1] == "Asia/Calcutta"
            and isinstance(item[2], str)
        ):
            return item[2]
    return None


def find_route_badge(root: Any) -> Optional[str]:
    """Find a bus route code within a subtree.

    Typical badge shapes:
      [5, ["600-FC", 1, "#ffffff"]]
      ["600-FC", 1, "#ffffff"]
    """
    found: Optional[str] = None

    def walk(n: Any) -> None:
        nonlocal found
        if found is not None:
            return
        if isinstance(n, list):
            # [5, ["ROUTE", 1, "#fff"]]
            if (
                len(n) >= 2
                and n[0] == 5
                and isinstance(n[1], list)
                and len(n[1]) >= 3
                and isinstance(n[1][0], str)
                and isinstance(n[1][2], str)
                and n[1][2].startswith('#')
            ):
                found = n[1][0]
                return

            # ["ROUTE", 1, "#fff"]
            if (
                len(n) >= 3
                and isinstance(n[0], str)
                and isinstance(n[1], int)
                and isinstance(n[2], str)
                and n[2].startswith('#')
            ):
                found = n[0]
                return

            for it in n:
                walk(it)
        elif isinstance(n, dict):
            for v in n.values():
                walk(v)

    walk(root)
    return found


def looks_like_any_stop_entry(e: Any) -> bool:
    if not isinstance(e, list) or not e:
        return False
    if not isinstance(e[0], str):
        return False
    s = e[0]
    if s.startswith('0x') or s.startswith('http') or s.startswith('//'):
        return False
    return True


def find_last_origin_destination_pair(root: Any) -> Tuple[Optional[Tuple[Any, ...]], Optional[List[Any]]]:
    """Find the last block that starts with two stop entries (origin + destination).

    Example (from the user snippet):
      [
        ["Banashankari", ... , [..time..], [..coords..], "0x.." ...],
        ["Jigani APC Circle", ... , [..time..], ...],
        ...
      ]
    """
    last_path: Optional[Tuple[Any, ...]] = None
    last_pair: Optional[List[Any]] = None

    def walk(n: Any, path: Tuple[Any, ...] = ()):
        nonlocal last_path, last_pair
        if isinstance(n, list):
            # We specifically want the *header* block which starts with two stops
            # followed by an integer (often the number of stops / a code), e.g.:
            #   [ ["Banashankari", ...], ["Jigani APC Circle", ...], 38, null, 0, ...]
            if (
                len(n) >= 3
                and looks_like_any_stop_entry(n[0])
                and looks_like_any_stop_entry(n[1])
                and isinstance(n[2], int)
            ):
                # Require that each has a time somewhere inside
                if extract_time(n[0]) and extract_time(n[1]):
                    last_path = path
                    last_pair = [n[0], n[1]]
            for i, v in enumerate(n):
                walk(v, path + (i,))
        elif isinstance(n, dict):
            for k, v in n.items():
                walk(v, path + (k,))

    walk(root)
    return last_path, last_pair


def extract_lat_lng(stop_entry: List[Any]) -> Tuple[Optional[float], Optional[float]]:
    # In observed structure, a coordinate list appears like [null, null, lat, lng]
    for item in stop_entry:
        if isinstance(item, list) and len(item) >= 4 and item[0] is None and item[1] is None:
            lat, lng = item[2], item[3]
            if isinstance(lat, (int, float)) and isinstance(lng, (int, float)):
                return float(lat), float(lng)
    return None, None


def extract_place_id(stop_entry: List[Any]) -> Optional[str]:
    # Observed place id like "0x...:0x..." appears as a string inside the stop entry
    for item in stop_entry:
        if isinstance(item, str) and item.startswith('0x') and ':' in item:
            return item
    return None


def stop_name(e: List[Any]) -> str:
    return e[0] if e and isinstance(e[0], str) else ""


def stop_key(e: List[Any]) -> Tuple[Any, ...]:
    # Preserve same-named stops if they differ by coordinates or place id.
    n = stop_name(e)
    lat, lng = extract_lat_lng(e)
    pid = extract_place_id(e)
    return (n, pid, lat, lng)


def find_last_timed_stop_sequence(root: Any) -> Tuple[Optional[Tuple[Any, ...]], Optional[List[Any]], Optional[str]]:
    """Find the *last* occurrence (in traversal order) of a stop sequence
    containing timed stop entries.
    """
    last_path: Optional[Tuple[Any, ...]] = None
    last_seq: Optional[List[Any]] = None
    last_route: Optional[str] = None

    def walk(n: Any, path: Tuple[Any, ...] = ()):
        nonlocal last_path, last_seq, last_route
        if isinstance(n, list):
            if (
                len(n) >= 5
                and looks_like_timed_stop_entry(n[0])
                and looks_like_timed_stop_entry(n[1])
                and looks_like_timed_stop_entry(n[2])
            ):
                cnt = sum(1 for e in n if looks_like_timed_stop_entry(e))
                if cnt >= 5 and cnt / len(n) > 0.6:
                    last_path = path
                    last_seq = n
                    # Try to find route badge in the containing subtree (n)
                    last_route = find_route_badge(n)
            for i, v in enumerate(n):
                walk(v, path + (i,))
        elif isinstance(n, dict):
            for k, v in n.items():
                walk(v, path + (k,))

    walk(root)
    return last_path, last_seq, last_route


def get_by_path(root: Any, path: Tuple[Any, ...]) -> Any:
    cur = root
    for p in path:
        if isinstance(cur, list) and isinstance(p, int) and 0 <= p < len(cur):
            cur = cur[p]
        elif isinstance(cur, dict) and p in cur:
            cur = cur[p]
        else:
            return None
    return cur


path, seq, route = find_last_timed_stop_sequence(data)
if not seq:
    raise SystemExit('Could not locate a stop sequence in the input.')

# If route wasn't found inside the sequence subtree, search ancestors.
if route is None and path is not None:
    for i in range(len(path), -1, -1):
        subtree = get_by_path(data, path[:i])
        if subtree is None:
            continue
        r = find_route_badge(subtree)
        if r is not None:
            route = r
            break

pair_path, od_pair = find_last_origin_destination_pair(data)

origin = od_pair[0] if od_pair else None
destination = od_pair[1] if od_pair else None

raw_seq_entries: List[List[Any]] = [e for e in seq if looks_like_timed_stop_entry(e)]

# Build final ordered sequence:
# origin (if present) + last timed sequence + destination (if present)
merged_entries: List[List[Any]] = []
if origin is not None and isinstance(origin, list):
    # Avoid duplicating origin if it matches the first timed stop by composite identity.
    if not raw_seq_entries or stop_key(origin) != stop_key(raw_seq_entries[0]):
        merged_entries.append(origin)
merged_entries.extend(raw_seq_entries)
if destination is not None and isinstance(destination, list):
    # Avoid duplicating destination if it matches the last timed stop by composite identity.
    if not raw_seq_entries or stop_key(destination) != stop_key(raw_seq_entries[-1]):
        merged_entries.append(destination)

# Dedup by stop name while preserving order, but always keep first and last.
deduped: List[List[Any]] = []
seen_keys = set()
for i, e in enumerate(merged_entries):
    n = stop_name(e)
    if not n:
        continue
    is_first = (i == 0)
    is_last = (i == len(merged_entries) - 1)
    k = stop_key(e)
    if k in seen_keys and not is_first and not is_last:
        continue
    seen_keys.add(k)
    deduped.append(e)

stops: List[Dict[str, Any]] = []
for idx, entry in enumerate(deduped):
    name = entry[0]
    lat, lng = extract_lat_lng(entry)
    stops.append({
        'index': idx,
        'name': name,
        'time': extract_time(entry),
        'lat': lat,
        'lng': lng,
        'place_id': extract_place_id(entry),
    })

out = {
    'route': route,
    'stop_sequence': stops,
    'count': len(stops),
    'source_path': list(path) if path else None,
    'origin_destination_path': list(pair_path) if pair_path else None,
}

with open(out_path, 'w', encoding='utf-8') as f:
    json.dump(out, f, ensure_ascii=False, indent=2)
PY

echo "Transit stop sequence written to: $OUT"

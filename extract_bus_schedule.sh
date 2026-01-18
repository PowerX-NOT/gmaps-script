#!/usr/bin/env bash
#
# extract_bus_schedule.sh
# Usage:
#   ./extract_bus_schedule.sh response.json bus_schedule.txt [clean_response.json] [bus_schedule.json]
#
# Reads a Google Maps JSON response (with or without XSSI prefix ")]}'") and extracts
# a human-readable bus timetable for the nearby stop (e.g. Jigani APC Circle)
# in a format similar to:
#
#   Rupesh Hotel
#   Buses
#   355-A
#   ...
#   Bus 600-FC    Jigani APC Circle    8:00 AM
#   Bus BC-3A     Jigani APC Circle    8:10 AM
#   ...
#
# This script uses a small embedded Python parser, because the structure
# of the Google response is deeply nested and positional.

set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "Usage: $0 <input_raw_or_clean_json> <output_text> [output_clean_json] [output_schedule_json]" >&2
  exit 1
fi

IN="$1"
OUT="$2"
CLEAN_OUT="${3:-}"
SCHEDULE_JSON_OUT="${4:-}"

if [ ! -f "$IN" ]; then
  echo "Input file not found: $IN" >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "Error: python3 is required but not installed." >&2
  exit 1
fi

python3 - << 'PY' "$IN" "$OUT" "$CLEAN_OUT" "$SCHEDULE_JSON_OUT"
import json
import sys
from typing import Any, List, Tuple

in_path = sys.argv[1]
out_path = sys.argv[2]

# Optional third arg: where to write a pretty "clean" JSON
clean_out_path = sys.argv[3] if len(sys.argv) > 3 else ""

# Optional fourth arg: where to write a structured schedule JSON
schedule_json_out_path = sys.argv[4] if len(sys.argv) > 4 else ""

with open(in_path, 'r', encoding='utf-8') as f:
    raw = f.read()

# Strip XSSI prefix if present (usually the first line is ")]}'")
lines = raw.splitlines()
if lines and lines[0].strip() == ")]}'":
    raw_json = "\n".join(lines[1:])
else:
    raw_json = raw

data = json.loads(raw_json)

if clean_out_path:
    with open(clean_out_path, 'w', encoding='utf-8') as cf:
        json.dump(data, cf, ensure_ascii=False, indent=2)


def extract_place_name(root: Any) -> str:
    """Best-effort extraction of place name from the response.

    Looks for list patterns like:
      ["<id>", "<name>", null, [null, null, <lat>, <lng>], ...]
    and returns the first matching name.
    """
    def walk(n: Any) -> str:
        if isinstance(n, list):
            if (
                len(n) >= 4
                and isinstance(n[0], str)
                and isinstance(n[1], str)
                and n[2] is None
                and isinstance(n[3], list)
                and len(n[3]) >= 4
                and n[3][2] is not None
                and n[3][3] is not None
            ):
                return n[1]
            for it in n:
                r = walk(it)
                if r:
                    return r
        elif isinstance(n, dict):
            for v in n.values():
                r = walk(v)
                if r:
                    return r
        return ""

    return walk(root) or "(unknown place)"

records: List[Tuple[str, str, str]] = []  # (route, stop, time_str)

# Routes shown under the "Buses" section in the response (may include routes
# without attached time entries).
routes_from_buses_section: List[str] = []


def try_extract_block(node: Any) -> None:
    """Search within this node for a Bus route, stop name, and time string.

    This is a more generic matcher that:
    - looks for a sub-list like ["<route>", 1, "#ffffff"]
    - looks for a stop entry ["<stop>", null, null, time_block]
    - ensures "Bus" appears somewhere in the same node
    """
    if not isinstance(node, list):
        return

    # Quick check: only proceed if this subtree looks like a transit row.
    # "bus2.png" is a strong signal for a bus row.
    def contains_bus_marker(x: Any) -> bool:
        if isinstance(x, str):
            return x == "bus2.png" or x == "Bus"
        if isinstance(x, list):
            return any(contains_bus_marker(i) for i in x)
        if isinstance(x, dict):
            return any(contains_bus_marker(v) for v in x.values())
        return False

    if not contains_bus_marker(node):
        return

    route = None
    stop_name = None
    time_str = None

    # Find route code
    def find_route(x: Any) -> None:
        nonlocal route
        if route is not None:
            return
        # Route badge looks like: ["BC-3A", 1, "#ffffff"]
        if (
            isinstance(x, list)
            and len(x) >= 3
            and isinstance(x[0], str)
            and isinstance(x[1], int)
            and isinstance(x[2], str)
            and x[2].startswith("#")
        ):
            route = x[0]
            return
        if isinstance(x, list):
            for i in x:
                find_route(i)
        elif isinstance(x, dict):
            for v in x.values():
                find_route(v)

    # Find stop + time
    def find_stop_and_time(x: Any) -> None:
        nonlocal stop_name, time_str
        if stop_name is not None and time_str is not None:
            return
        # Stop entry looks like: ["Jigani APC Circle", null, null, time_block]
        if (
            isinstance(x, list)
            and len(x) >= 4
            and isinstance(x[0], str)
            and x[1] is None
            and x[2] is None
        ):
            tb = x[3]
            # time_block ~ [ [ [ [timestamp, tz, time_str, ...], ... ] ] ]
            if (
                isinstance(tb, list)
                and len(tb) >= 1
                and isinstance(tb[0], list)
                and len(tb[0]) >= 1
                and isinstance(tb[0][0], list)
                and len(tb[0][0]) >= 1
                and isinstance(tb[0][0][0], list)
                and len(tb[0][0][0]) >= 3
                and isinstance(tb[0][0][0][2], str)
            ):
                stop_name = x[0]
                time_str = tb[0][0][0][2]
                return
        if isinstance(x, list):
            for i in x:
                find_stop_and_time(i)
        elif isinstance(x, dict):
            for v in x.values():
                find_stop_and_time(v)

    find_route(node)
    find_stop_and_time(node)

    if route and stop_name and time_str:
        records.append((route, stop_name, time_str))


def walk(node: Any) -> None:
    try_extract_block(node)
    if isinstance(node, list):
        for item in node:
            walk(item)
    elif isinstance(node, dict):
        for v in node.values():
            walk(v)


def extract_routes_from_buses_section(root: Any) -> List[str]:
    """Collect route codes from blocks like:

    ["Buses", [...icon...], [ [.., [ [5, ["355-A", 1, "#ffffff"]] ], ...], ... ], ...]
    """
    found: List[str] = []

    def consider_sub(sub: Any) -> None:
        if (
            isinstance(sub, list)
            and len(sub) >= 2
            and sub[0] == 5
            and isinstance(sub[1], list)
            and len(sub[1]) >= 1
            and isinstance(sub[1][0], str)
        ):
            found.append(sub[1][0])

    def walk2(n: Any) -> None:
        if isinstance(n, list):
            # Look for a list where the first element is the literal string "Buses"
            if len(n) >= 3 and n[0] == "Buses":
                # n[2] is expected to be a list of items containing route badges
                candidates = n[2]
                if isinstance(candidates, list):
                    for item in candidates:
                        # Each item is typically like: [null, null, null, null, "0x..", [[5, ["BC-3A", 1, "#ffffff"]]], ...]
                        if not isinstance(item, list):
                            continue
                        for sub in item:
                            # The route badge may be directly [5, [...]]
                            consider_sub(sub)
                            # ...or nested like [[5, [...]]]
                            if isinstance(sub, list):
                                for sub2 in sub:
                                    consider_sub(sub2)
            for it in n:
                walk2(it)
        elif isinstance(n, dict):
            for v in n.values():
                walk2(v)

    walk2(root)

    # Dedup preserve order
    seen = set()
    out: List[str] = []
    for r in found:
        if r not in seen:
            seen.add(r)
            out.append(r)
    return out


place_name = extract_place_name(data)
walk(data)
routes_from_buses_section = extract_routes_from_buses_section(data)

# Deduplicate while preserving order
seen = set()
unique_records: List[Tuple[str, str, str]] = []
for r in records:
    if r not in seen:
        seen.add(r)
        unique_records.append(r)

# Extract unique routes (prefer the dedicated "Buses" section if present)
route_seen = set()
unique_routes: List[str] = []

for r in routes_from_buses_section:
    if r not in route_seen:
        route_seen.add(r)
        unique_routes.append(r)

for route, _stop, _time_str in unique_records:
    if route not in route_seen:
        route_seen.add(route)
        unique_routes.append(route)

with open(out_path, 'w', encoding='utf-8') as out:
    out.write(f"{place_name}\n")
    out.write('Buses\n')
    for route in unique_routes:
        out.write(f"{route}\n")
    for route, stop, time_str in unique_records:
        out.write(f"Bus {route}\t{stop}\t{time_str}\n")

if schedule_json_out_path:
    schedule = {
        "place": place_name,
        "buses": unique_routes,
        "timetable": [
            {
                "mode": "Bus",
                "route": route,
                "towords": stop,
                "time": time_str,
            }
            for route, stop, time_str in unique_records
        ],
    }
    with open(schedule_json_out_path, 'w', encoding='utf-8') as sf:
        json.dump(schedule, sf, ensure_ascii=False, indent=2)

PY

echo "Bus schedule written to: $OUT"

if [ -n "${CLEAN_OUT}" ]; then
  echo "Clean JSON written to: ${CLEAN_OUT}"
fi

if [ -n "${SCHEDULE_JSON_OUT}" ]; then
  echo "Schedule JSON written to: ${SCHEDULE_JSON_OUT}"
fi
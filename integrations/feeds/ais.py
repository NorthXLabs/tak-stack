#!/usr/bin/env python3
"""Vessels from AIS, polled from Finland's Digitraffic API and sent to TAK Server.

Source: Fintraffic / digitraffic.fi, license CC 4.0 BY.
https://www.digitraffic.fi/en/marine-traffic/
"""
import gzip
import json
import logging
import os
import time
import urllib.parse
import urllib.request
from datetime import datetime, timezone

import takfeed

log = logging.getLogger("ais")

LAT = os.environ.get("AIS_LAT", "")          # leave empty for all of Finland's waters
LON = os.environ.get("AIS_LON", "")
RADIUS_KM = os.environ.get("AIS_RADIUS_KM") or "50"
# Digitraffic caches responses for about a minute, so polling faster gains nothing.
POLL_SECONDS = int(os.environ.get("POLL_SECONDS", "60"))
# Moored and anchored ships report every few minutes, and we only see the
# latest report each poll. Keep a vessel for 15 minutes after its last report.
STALE_SECONDS = int(os.environ.get("STALE_SECONDS", "900"))
NAMES_EVERY_SECONDS = 3600

API = "https://meri.digitraffic.fi/api/ais/v1"
HEADERS = {"Accept-Encoding": "gzip", "Digitraffic-User": "tak-stack-feeds/1.0"}
KNOTS = 0.514444
ATTRIBUTION = "Source: Fintraffic / digitraffic.fi, license CC 4.0 BY"


def get(path, **params):
    url = f"{API}/{path}"
    if params:
        url += "?" + urllib.parse.urlencode(params)
    with urllib.request.urlopen(urllib.request.Request(url, headers=HEADERS), timeout=30) as response:
        body = response.read()
        if response.headers.get("Content-Encoding") == "gzip":
            body = gzip.decompress(body)
    return json.loads(body)


def to_event(feature, names, now):
    props = feature["properties"]
    lon, lat = feature["geometry"]["coordinates"]
    when = datetime.fromtimestamp(props["timestampExternal"] / 1000, timezone.utc)
    if (now - when).total_seconds() > STALE_SECONDS:
        return None
    mmsi = props["mmsi"]
    name = names.get(mmsi, {}).get("name", "").strip()
    # 511 means "heading not available", and 360 "course not available".
    course = props.get("cog") if props.get("cog", 360) < 360 else None
    speed = props.get("sog")
    return takfeed.event(
        f"MMSI-{mmsi}", "a-n-S", lat, lon,     # a neutral surface vessel
        stale_seconds=STALE_SECONDS,
        when=when,
        callsign=name or str(mmsi),
        course=course,
        speed=speed * KNOTS if speed is not None and speed < 102.3 else None,
        remarks=f"MMSI {mmsi} | {ATTRIBUTION}",
    )


def main():
    takfeed.setup_logging()
    tak = takfeed.TakServer()
    tak.connect()
    area = dict(latitude=LAT, longitude=LON, radius=RADIUS_KM) if LAT and LON else {}
    log.info("Polling %s/locations every %ds %s", API, POLL_SECONDS, area or "(all vessels)")
    names, names_at = {}, 0.0
    while True:
        started = time.monotonic()
        try:
            if started - names_at > NAMES_EVERY_SECONDS:
                names = {v["mmsi"]: v for v in get("vessels")}
                names_at = started
                log.info("Loaded names for %d vessels", len(names))
            features = get("locations", **area)["features"]
            now = datetime.now(timezone.utc)
            events = [e for e in (to_event(f, names, now) for f in features) if e]
            tak.send(events)
            log.info("Sent %d vessels", len(events))
        except (OSError, ValueError, KeyError) as err:
            log.warning("Poll failed: %s", err)
        time.sleep(max(0, POLL_SECONDS - (time.monotonic() - started)))


if __name__ == "__main__":
    main()

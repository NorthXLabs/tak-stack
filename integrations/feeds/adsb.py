#!/usr/bin/env python3
"""Aircraft from ADS-B, polled from the adsb.lol API and sent to TAK Server.

adsb.lol data is licensed under the ODbL 1.0: https://www.adsb.lol/docs/open-data/api/
"""
import json
import logging
import os
import time
import urllib.request
from datetime import datetime, timedelta, timezone

import takfeed

log = logging.getLogger("adsb")

LAT = float(os.environ.get("ADSB_LAT", "51.13"))        # Calgary airport
LON = float(os.environ.get("ADSB_LON", "-114.01"))
RADIUS_NM = int(os.environ.get("ADSB_RADIUS_NM", "40"))  # nautical miles, up to 250
POLL_SECONDS = int(os.environ.get("POLL_SECONDS", "15"))
# An aircraft drops off the map if we stop hearing about it: out of range,
# landed, or the feed stops. Long enough to ride out a missed poll or two.
STALE_SECONDS = int(os.environ.get("STALE_SECONDS", "60"))

URL = f"https://api.adsb.lol/v2/lat/{LAT}/lon/{LON}/dist/{RADIUS_NM}"
FEET = 0.3048
KNOTS = 0.514444


def to_event(ac, now):
    if "lat" not in ac or "lon" not in ac:
        return None
    seen = ac.get("seen_pos", 0)
    if seen > STALE_SECONDS:
        return None
    # ADS-B category A7 is a rotorcraft. Everything else is drawn as a fixed-wing.
    cot_type = "a-n-A-C-H" if ac.get("category") == "A7" else "a-n-A-C-F"
    # The ICAO address is unique to the airframe, so it makes a stable UID.
    # Flight numbers change, and many aircraft don't broadcast one.
    uid = f"ICAO-{ac['hex'].lower()}"
    callsign = (ac.get("flight") or "").strip() or ac.get("r") or ac["hex"].upper()
    altitude = ac.get("alt_geom", ac.get("alt_baro"))
    hae = altitude * FEET if isinstance(altitude, (int, float)) else takfeed.UNKNOWN
    remarks = " ".join(x for x in (ac.get("t"), ac.get("r")) if x)
    return takfeed.event(
        uid, cot_type, ac["lat"], ac["lon"],
        stale_seconds=STALE_SECONDS,
        when=now - timedelta(seconds=seen),
        callsign=callsign,
        hae=hae,
        course=ac.get("track"),
        speed=ac["gs"] * KNOTS if "gs" in ac else None,
        remarks=f"{remarks} | Source: adsb.lol, ODbL 1.0".strip(" |"),
    )


def main():
    takfeed.setup_logging()
    tak = takfeed.TakServer()
    tak.connect()
    log.info("Polling %s every %ds", URL, POLL_SECONDS)
    request = urllib.request.Request(URL, headers={"User-Agent": "tak-stack-feeds/1.0"})
    while True:
        started = time.monotonic()
        try:
            with urllib.request.urlopen(request, timeout=20) as response:
                aircraft = json.load(response).get("ac", [])
            now = datetime.now(timezone.utc)
            events = [e for e in (to_event(ac, now) for ac in aircraft) if e]
            tak.send(events)
            log.info("Sent %d aircraft", len(events))
        except (OSError, ValueError) as err:
            log.warning("Poll failed: %s", err)
        time.sleep(max(0, POLL_SECONDS - (time.monotonic() - started)))


if __name__ == "__main__":
    main()

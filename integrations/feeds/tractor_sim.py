#!/usr/bin/env python3
"""A pretend GPS tracker on a tractor, working a field up and down.

Publishes OwnTracks location messages to MQTT, the way a real tracker or
gateway would. Replace it with real trackers when you have them.
"""
import json
import logging
import math
import os
import time

import paho.mqtt.client as mqtt

log = logging.getLogger("tractor")

BROKER = os.environ.get("MQTT_HOST", "mosquitto")
TOPIC = os.environ.get("TRACTOR_TOPIC", "owntracks/farm/tractor-1")
# The south-west corner of the field. The default is farmland east of Calgary.
LAT = float(os.environ.get("FIELD_LAT", "51.0300"))
LON = float(os.environ.get("FIELD_LON", "-113.7500"))
FIELD_WIDTH_M = 400      # east to west
FIELD_LENGTH_M = 300     # south to north
ROW_SPACING_M = 25
SPEED_MS = 3.0           # about 11 km/h
REPORT_SECONDS = int(os.environ.get("REPORT_SECONDS", "10"))


def path():
    """Positions in metres from the corner, up one row and down the next, forever."""
    while True:
        x, going_north = 0.0, True
        while x <= FIELD_WIDTH_M:
            for y in range(0, FIELD_LENGTH_M + 1, int(SPEED_MS)):
                yield x, (y if going_north else FIELD_LENGTH_M - y), (0 if going_north else 180)
            x += ROW_SPACING_M
            going_north = not going_north


def main():
    logging.basicConfig(level="INFO", format="%(asctime)s %(name)s %(levelname)s %(message)s")
    client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id="tractor-sim")
    client.connect_async(BROKER)
    client.loop_start()
    metres_per_degree_lon = 111_320 * math.cos(math.radians(LAT))
    battery = 100.0
    for step, (x, y, course) in enumerate(path()):
        if step % REPORT_SECONDS:      # one step per second, one report every few
            continue
        message = {
            "_type": "location",
            "tid": "T1",
            "tst": int(time.time()),
            "lat": round(LAT + y / 111_320, 6),
            "lon": round(LON + x / metres_per_degree_lon, 6),
            "acc": 5,
            "cog": course,
            "vel": round(SPEED_MS * 3.6),
            "batt": int(battery),
        }
        client.publish(TOPIC, json.dumps(message))
        log.info("Published %s", message)
        battery = max(5.0, battery - 0.02)
        time.sleep(REPORT_SECONDS)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""GPS trackers over MQTT, sent to TAK Server.

Subscribes to location messages in OwnTracks' JSON format, on topics like
owntracks/<user>/<device>. The OwnTracks app publishes this format, and it's
simple enough to produce from a tracker or a gateway.
https://owntracks.org/booklet/tech/json/
"""
import json
import logging
import os
from datetime import datetime, timezone

import paho.mqtt.client as mqtt

import takfeed

log = logging.getLogger("mqtt")

BROKER = os.environ.get("MQTT_HOST", "mosquitto")
TOPIC = os.environ.get("MQTT_TOPIC", "owntracks/+/+")
# Trackers save battery by reporting less often. Keep each one on the map for
# 10 minutes after its last report.
STALE_SECONDS = int(os.environ.get("STALE_SECONDS", "600"))
COT_TYPE = os.environ.get("TRACKER_COT_TYPE", "a-f-G-E-V-C")  # friendly civilian vehicle

tak = None


def on_connect(client, userdata, flags, reason_code, properties):
    log.info("Connected to %s, subscribing to %s", BROKER, TOPIC)
    client.subscribe(TOPIC)


def on_message(client, userdata, message):
    try:
        data = json.loads(message.payload)
    except ValueError:
        log.warning("Not JSON on %s", message.topic)
        return
    if data.get("_type") != "location" or "lat" not in data or "lon" not in data:
        return
    _, user, device = message.topic.split("/", 2)
    when = datetime.fromtimestamp(data.get("tst", datetime.now().timestamp()), timezone.utc)
    battery = f"Battery {data['batt']}%" if "batt" in data else ""
    tak.send([takfeed.event(
        f"owntracks-{user}-{device}", COT_TYPE, data["lat"], data["lon"],
        stale_seconds=STALE_SECONDS,
        when=when,
        callsign=device.upper(),
        ce=data.get("acc", takfeed.UNKNOWN),
        course=data.get("cog"),
        speed=data["vel"] / 3.6 if "vel" in data else None,   # km/h to m/s
        remarks=battery,
    )])
    log.info("%s/%s at %.5f, %.5f", user, device, data["lat"], data["lon"])


def main():
    global tak
    takfeed.setup_logging()
    tak = takfeed.TakServer()
    tak.connect()
    client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id="tak-feed")
    client.on_connect = on_connect
    client.on_message = on_message
    client.connect_async(BROKER)
    client.loop_forever(retry_first_connection=True)


if __name__ == "__main__":
    main()

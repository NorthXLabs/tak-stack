# feeds

Data feeds for the TAK Server in [`compose/takserver`](../../compose/takserver). Each feed is a small Python adapter that fetches data, turns it into Cursor on Target (CoT) and sends it to TAK Server over TLS, with its own certificate.

| Service | What it puts on the map | Source |
|---|---|---|
| `adsb` | Aircraft, from ADS-B | [adsb.lol](https://www.adsb.lol/docs/open-data/api/), ODbL 1.0 |
| `ais` | Vessels in Finland's waters, from AIS | [Digitraffic](https://www.digitraffic.fi/en/marine-traffic/), Fintraffic, CC 4.0 BY |
| `tracker` | GPS trackers that publish to MQTT, in OwnTracks' JSON format | The `mosquitto` broker |
| `mosquitto` | An MQTT broker for trackers | |
| `tractor` | A pretend tracker on a tractor, working a field east of Calgary | Simulated |

Each event's remarks name its data source, as the licences ask.

## Requirements

- The TAK Server in `compose/takserver`, running.
- Internet access, for the aircraft and vessel feeds.

## Quick start

1. In `compose/takserver/config/takserver.env`, make a certificate for each feed:

   ```sh
   CLIENT_CERTS=feed-adsb feed-ais feed-tracker
   ```

   Then run `docker compose up -d` in `compose/takserver`.

2. Here, copy the certificates out of TAK Server and start the feeds:

   ```sh
   ./setup.sh
   docker compose up -d --build
   ```

`setup.sh` copies each feed's certificate and key, and the root CA, into `certs/`, and creates `.env` with the settings below. Run it again after rotating a CA.

## Settings

In `.env`. Run `docker compose up -d` after changing them.

| Setting | Default | What it does |
|---|---|---|
| `ADSB_LAT`, `ADSB_LON` | Calgary airport | The centre of the aircraft feed |
| `ADSB_RADIUS_NM` | `40` | How far out, in nautical miles, up to 250 |
| `AIS_LAT`, `AIS_LON`, `AIS_RADIUS_KM` | Empty | Limit vessels to a circle. Empty means every vessel Digitraffic reports |
| `FIELD_LAT`, `FIELD_LON` | East of Calgary | The south-west corner of the tractor's field |

## How each feed behaves

| Feed | Polls or listens | UID | Stale after |
|---|---|---|---|
| `adsb` | Polls every 15 seconds | `ICAO-<hex>`, the aircraft's ICAO address | 60 seconds |
| `ais` | Polls every 60 seconds, Digitraffic's cache time | `MMSI-<mmsi>`, the vessel's MMSI | 15 minutes after the vessel's own report |
| `tracker` | Listens on `owntracks/+/+` | `owntracks-<user>-<device>` | 10 minutes after the tracker's own report |

## Connecting a real tracker

Publish OwnTracks location messages to `owntracks/<user>/<device>` on the broker, for example:

```sh
docker compose exec mosquitto mosquitto_pub -t owntracks/farm/quad-1 \
  -m '{"_type":"location","lat":51.04,"lon":-113.74,"tst":'"$(date +%s)"',"batt":80}'
```

The broker listens on port 1883, on this computer only, with no passwords. Before connecting real trackers over a network, add passwords and TLS to `mosquitto.conf`.

## Files

| File | What it does |
|---|---|
| `takfeed.py` | Shared code: builds CoT events, and keeps a TLS connection to TAK Server |
| `adsb.py`, `ais.py`, `mqtt_tracker.py` | One adapter per feed |
| `tractor_sim.py` | The pretend tractor |

The adapters use only the Python standard library, apart from `paho-mqtt` for MQTT.

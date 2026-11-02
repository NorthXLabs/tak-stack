#!/usr/bin/env python3
"""Put a moving truck on a TAK map by sending Cursor on Target messages.

Uses only the Python standard library. Stop it with Ctrl+C and watch the
truck go stale on the map.
"""
import argparse
import math
import socket
import struct
import time
from datetime import datetime, timedelta, timezone

MESH_GROUP = "239.2.3.1"
MESH_PORT = 6969

UID = "hello-cot-truck-1"
CALLSIGN = "TRUCK-1"
COT_TYPE = "a-f-G-E-V"  # atom, friendly, ground, equipment, vehicle
STALE_SECONDS = 30
RADIUS_DEGREES = 0.005


def cot_time(moment):
    return moment.strftime("%Y-%m-%dT%H:%M:%S.000Z")


def build_event(lat, lon, course):
    now = datetime.now(timezone.utc)
    stale = now + timedelta(seconds=STALE_SECONDS)
    return (
        '<?xml version="1.0" encoding="UTF-8"?>'
        f'<event version="2.0" uid="{UID}" type="{COT_TYPE}" how="m-g" '
        f'time="{cot_time(now)}" start="{cot_time(now)}" stale="{cot_time(stale)}">'
        f'<point lat="{lat:.6f}" lon="{lon:.6f}" hae="9999999" ce="10" le="10"/>'
        f'<detail><contact callsign="{CALLSIGN}"/>'
        f'<track course="{course:.1f}" speed="5"/></detail>'
        "</event>"
    ).encode()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lat", type=float, required=True, help="centre latitude")
    parser.add_argument("--lon", type=float, required=True, help="centre longitude")
    parser.add_argument("--interface", help="IP address of the network to send on")
    parser.add_argument("--target", help="send to host:port instead of the mesh group")
    args = parser.parse_args()

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    if args.target:
        host, port = args.target.rsplit(":", 1)
        destination = (host, int(port))
    else:
        destination = (MESH_GROUP, MESH_PORT)
        sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, struct.pack("b", 1))
        sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_LOOP, 1)
        if args.interface:
            sock.setsockopt(
                socket.IPPROTO_IP,
                socket.IP_MULTICAST_IF,
                socket.inet_aton(args.interface),
            )

    print(f"Sending {CALLSIGN} to {destination[0]}:{destination[1]}. Ctrl+C to stop.")
    angle = 0.0
    try:
        while True:
            lat = args.lat + RADIUS_DEGREES * math.cos(angle)
            lon = args.lon + RADIUS_DEGREES * math.sin(angle) / math.cos(math.radians(args.lat))
            course = (math.degrees(angle) + 90) % 360
            sock.sendto(build_event(lat, lon, course), destination)
            print(f"  {lat:.5f}, {lon:.5f}")
            angle += math.radians(10)
            time.sleep(5)
    except KeyboardInterrupt:
        print(f"\nStopped. Watch {CALLSIGN} go stale on the map.")


if __name__ == "__main__":
    main()

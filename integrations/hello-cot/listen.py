#!/usr/bin/env python3
"""Listen to the TAK mesh and print what devices are saying."""
import argparse
import re
import socket
import struct
from datetime import datetime, timezone

import takproto

MESH_GROUP = "239.2.3.1"
MESH_PORT = 6969


def when(milliseconds):
    moment = datetime.fromtimestamp(milliseconds / 1000, timezone.utc)
    return moment.strftime("%H:%M:%S")


def describe(packet):
    if not packet.startswith(b"\xbf\x01\xbf"):
        return "XML message:\n" + packet.decode(errors="replace")

    event = takproto.parse_proto(bytearray(packet)).cotEvent
    # ATAK can keep the contact as raw XML inside the binary message.
    match = re.search(r'callsign="([^"]*)"', event.detail.xmlDetail)
    callsign = event.detail.contact.callsign or (match.group(1) if match else "unknown")
    return "\n".join(
        [
            f"Binary message, {len(packet)} bytes",
            f"  callsign: {callsign}",
            f"  uid:      {event.uid}",
            f"  type:     {event.type}",
            f"  how:      {event.how}",
            f"  position: {event.lat:.5f}, {event.lon:.5f}",
            f"  sent:     {when(event.sendTime)} UTC",
            f"  stale:    {when(event.staleTime)} UTC",
            f"  team:     {event.detail.group.name}, {event.detail.group.role}",
        ]
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--interface", default="0.0.0.0", help="IP address of the network to listen on")
    args = parser.parse_args()

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    if hasattr(socket, "SO_REUSEPORT"):
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
    sock.bind(("", MESH_PORT))
    membership = struct.pack("4s4s", socket.inet_aton(MESH_GROUP), socket.inet_aton(args.interface))
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, membership)

    print(f"Listening on {MESH_GROUP}:{MESH_PORT}. Ctrl+C to stop.\n")
    try:
        while True:
            packet, sender = sock.recvfrom(65535)
            print(f"From {sender[0]}")
            print(describe(packet))
            print()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()

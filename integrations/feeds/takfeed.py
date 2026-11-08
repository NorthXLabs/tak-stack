"""Shared code for the feed adapters: build Cursor on Target events and send
them to TAK Server over TLS, with the feed's own certificate.

Uses only the Python standard library.
"""
import logging
import os
import socket
import ssl
import threading
import time
from datetime import datetime, timedelta, timezone
from xml.sax.saxutils import quoteattr

log = logging.getLogger("takfeed")

# CoT uses this for "unknown" height and accuracy.
UNKNOWN = 9999999.0


def cot_time(moment):
    return moment.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")[:-4] + "Z"


def event(uid, cot_type, lat, lon, *, stale_seconds, callsign=None, when=None,
          hae=UNKNOWN, ce=UNKNOWN, course=None, speed=None, remarks=None, how="m-g"):
    """One CoT event as XML bytes.

    when is the time the position was observed, which can be earlier than now.
    The track goes stale stale_seconds after that, unless a newer event
    replaces it first.
    """
    when = when or datetime.now(timezone.utc)
    stale = when + timedelta(seconds=stale_seconds)
    detail = ""
    if callsign:
        detail += f"<contact callsign={quoteattr(callsign)}/>"
    if course is not None or speed is not None:
        detail += f'<track course="{course or 0:.1f}" speed="{speed or 0:.1f}"/>'
    if remarks:
        detail += f"<remarks>{escape_text(remarks)}</remarks>"
    return (
        f'<event version="2.0" uid={quoteattr(uid)} type={quoteattr(cot_type)} how="{how}" '
        f'time="{cot_time(when)}" start="{cot_time(when)}" stale="{cot_time(stale)}">'
        f'<point lat="{lat:.6f}" lon="{lon:.6f}" hae="{hae:.1f}" ce="{ce:.1f}" le="{UNKNOWN:.1f}"/>'
        f"<detail>{detail}</detail>"
        "</event>"
    ).encode()


def escape_text(text):
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


class TakServer:
    """A TLS connection to TAK Server's streaming port, reconnecting as needed.

    Settings come from the environment, which compose.yaml sets:
      TAK_HOST, TAK_PORT    where to connect
      FEED_CERT, FEED_KEY   this feed's certificate and encrypted key
      FEED_CERT_PASS        the key's password
      TAK_CA                the CA certificates to trust for the server
    """

    def __init__(self):
        self.host = os.environ.get("TAK_HOST", "takserver")
        self.port = int(os.environ.get("TAK_PORT", "8089"))
        self.context = ssl.create_default_context(cafile=os.environ["TAK_CA"])
        self.context.load_cert_chain(
            os.environ["FEED_CERT"], os.environ["FEED_KEY"], os.environ["FEED_CERT_PASS"]
        )
        self.sock = None
        self.lock = threading.Lock()

    def connect(self):
        delay = 2
        while True:
            try:
                raw = socket.create_connection((self.host, self.port), timeout=10)
                self.sock = self.context.wrap_socket(raw, server_hostname=self.host)
                self.sock.settimeout(None)
                log.info("Connected to %s:%d", self.host, self.port)
                # TAK Server sends every connected client what others share,
                # including us. Read and discard it, or the connection backs up.
                threading.Thread(target=self._drain, args=(self.sock,), daemon=True).start()
                return
            except (OSError, ssl.SSLError) as err:
                log.warning("Can't connect to %s:%d (%s). Retrying in %ds", self.host, self.port, err, delay)
                time.sleep(delay)
                delay = min(delay * 2, 60)

    def _drain(self, sock):
        try:
            while sock.recv(65536):
                pass
        except OSError:
            pass
        log.warning("TAK Server closed the connection")

    def send(self, events):
        """Send a batch of events. Reconnects and resends if the connection drops."""
        data = b"".join(events)
        if not data:
            return
        with self.lock:
            while True:
                if self.sock is None:
                    self.connect()
                try:
                    self.sock.sendall(data)
                    return
                except OSError as err:
                    log.warning("Send failed (%s). Reconnecting", err)
                    try:
                        self.sock.close()
                    except OSError:
                        pass
                    self.sock = None


def setup_logging():
    logging.basicConfig(
        level=os.environ.get("LOG_LEVEL", "INFO"),
        format="%(asctime)s %(name)s %(levelname)s %(message)s",
    )

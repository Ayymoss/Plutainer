"""
Valve A2S_INFO query (UDP).

The Steam server-browser protocol. Any server that appears in a Steam server
list answers it, which makes it the SteamCMD family's equivalent of `getstatus`:
unauthenticated, cheap, and — the part that matters for a health check — it
reports the map the server is actually running, so "healthy" can mean the same
thing here as it does for the Call of Duty engines rather than degrading to
"a socket accepted a connection".

Only A2S_INFO is implemented. A2S_PLAYER and A2S_RULES need the same challenge
dance and nothing here consumes them.

Reference: https://developer.valvesoftware.com/wiki/Server_queries
"""

import socket
import struct

HEADER = b"\xff\xff\xff\xff"
A2S_INFO = b"TSource Engine Query\x00"


class A2SError(Exception):
    pass


class _Reader(object):
    """Little-endian cursor over a response body."""

    def __init__(self, data):
        self.data = data
        self.pos = 0

    def byte(self):
        value = self.data[self.pos]
        self.pos += 1
        return value

    def short(self):
        value = struct.unpack_from("<h", self.data, self.pos)[0]
        self.pos += 2
        return value

    def string(self):
        end = self.data.index(b"\x00", self.pos)
        value = self.data[self.pos:end].decode("utf-8", "replace")
        self.pos = end + 1
        return value


def query_info(host, port, timeout=3.0, retries=2):
    """Return a dict describing the server, or raise A2SError.

    Keys: name, map, folder, game, players, max_players, bots, protocol.
    """
    payload = HEADER + b"T" + A2S_INFO[1:]
    last_error = None

    for _ in range(max(1, retries)):
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.settimeout(timeout)
        try:
            sock.connect((host, port))
            sock.send(payload)
            data = sock.recv(4096)

            # Modern servers answer with a challenge ('A') that must be echoed
            # back appended to the original request. Older ones reply directly.
            if len(data) >= 5 and data[4:5] == b"A":
                sock.send(payload + data[5:9])
                data = sock.recv(4096)

            return _parse_info(data)
        except A2SError as err:
            last_error = err
        except (socket.error, OSError, IndexError, struct.error) as err:
            last_error = A2SError("A2S query failed: %s" % err)
        finally:
            sock.close()

    raise last_error or A2SError("A2S query failed")


def _parse_info(data):
    if len(data) < 6 or not data.startswith(HEADER):
        raise A2SError("malformed A2S reply")

    kind = data[4:5]
    if kind != b"I":
        raise A2SError("unexpected A2S response type %r" % kind)

    r = _Reader(data[5:])
    info = {
        "protocol": r.byte(),
        "name": r.string(),
        "map": r.string(),
        "folder": r.string(),
        "game": r.string(),
    }
    info["app_id"] = r.short()
    info["players"] = r.byte()
    info["max_players"] = r.byte()
    info["bots"] = r.byte()
    return info

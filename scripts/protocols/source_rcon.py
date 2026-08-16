"""
Valve RCON over TCP (the "Source RCON" protocol).

Nothing like the Quake3 rcon the Call of Duty families use: this one is a
stateful TCP session with a login step, length-prefixed binary packets, and
request IDs. Used by every Source-engine dedicated server, L4D2 included.

Packet: <int32 size><int32 id><int32 type><body NUL><NUL>
        size counts everything after itself.

Auth failure is signalled by the server answering the auth request with
id == -1. Some servers send an empty SERVERDATA_RESPONSE_VALUE first, so the
auth reply is read in a short loop rather than assumed to be the next packet.

Reference: https://developer.valvesoftware.com/wiki/Source_RCON_Protocol
"""

import socket
import struct

SERVERDATA_AUTH = 3
SERVERDATA_AUTH_RESPONSE = 2
SERVERDATA_EXECCOMMAND = 2
SERVERDATA_RESPONSE_VALUE = 0


class RconError(Exception):
    pass


class SourceRcon(object):
    def __init__(self, host, port, password, timeout=5.0):
        self.host = host
        self.port = int(port)
        self.password = password
        self.timeout = timeout
        self.sock = None
        self._id = 0

    # --- connection ---------------------------------------------------------

    def connect(self):
        if not self.password:
            raise RconError(
                "No rcon_password is set on this server, so RCON is disabled."
            )
        self.sock = socket.create_connection((self.host, self.port), self.timeout)
        self.sock.settimeout(self.timeout)
        self._authenticate()

    def close(self):
        if self.sock is not None:
            try:
                self.sock.close()
            finally:
                self.sock = None

    def __enter__(self):
        self.connect()
        return self

    def __exit__(self, *_):
        self.close()

    # --- protocol -----------------------------------------------------------

    def _next_id(self):
        self._id += 1
        return self._id

    def _send(self, packet_type, body):
        payload = struct.pack("<ii", self._id, packet_type) + body.encode("utf-8") + b"\x00\x00"
        self.sock.sendall(struct.pack("<i", len(payload)) + payload)

    def _recv_exactly(self, count):
        chunks = []
        remaining = count
        while remaining > 0:
            chunk = self.sock.recv(remaining)
            if not chunk:
                raise RconError("connection closed by the server")
            chunks.append(chunk)
            remaining -= len(chunk)
        return b"".join(chunks)

    def _recv_packet(self):
        size = struct.unpack("<i", self._recv_exactly(4))[0]
        if size < 10 or size > 4 * 1024 * 1024:
            raise RconError("implausible RCON packet size %d" % size)
        payload = self._recv_exactly(size)
        packet_id, packet_type = struct.unpack_from("<ii", payload)
        body = payload[8:-2].decode("utf-8", "replace")
        return packet_id, packet_type, body

    def _authenticate(self):
        self._next_id()
        self._send(SERVERDATA_AUTH, self.password)

        # The auth response is sometimes preceded by an empty value packet.
        for _ in range(3):
            packet_id, packet_type, _body = self._recv_packet()
            if packet_type != SERVERDATA_AUTH_RESPONSE:
                continue
            if packet_id == -1:
                raise RconError("Bad rcon password.")
            return
        raise RconError("Server never answered the RCON login.")

    # --- public -------------------------------------------------------------

    def command(self, cmd):
        """Run one command and return the server's output as text."""
        if self.sock is None:
            raise RconError("not connected")

        request_id = self._next_id()
        self._send(SERVERDATA_EXECCOMMAND, cmd)

        # Responses over 4096 bytes arrive split across packets with no length
        # field to tell you so. Send a second, empty command: its reply cannot
        # overtake the first, so the response is complete once we see it.
        sentinel_id = self._next_id()
        self._send(SERVERDATA_RESPONSE_VALUE, "")

        parts = []
        while True:
            packet_id, _packet_type, body = self._recv_packet()
            if packet_id == sentinel_id:
                break
            if packet_id == request_id:
                parts.append(body)
        return "".join(parts)

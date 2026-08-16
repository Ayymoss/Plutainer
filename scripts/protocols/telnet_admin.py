"""
Line-oriented telnet console client, for 7 Days to Die.

7DTD has no RCON. Its remote administration is a plain TCP console: connect,
answer the password prompt, then exchange newline-terminated text. There is no
framing and no request/response correlation — the server streams whatever it
feels like, including unsolicited game events, so a "response" is just whatever
arrives in the quiet window after a command.

That imprecision is inherent to the protocol, not to this client. It is fine for
`docker exec ... rcon-cli say hello` and it is why nothing here tries to promise
an exact result set.
"""

import socket
import time


class TelnetError(Exception):
    pass


class TelnetAdmin(object):
    def __init__(self, host, port, password, timeout=5.0):
        self.host = host
        self.port = int(port)
        self.password = password
        self.timeout = timeout
        self.sock = None

    def connect(self):
        self.sock = socket.create_connection((self.host, self.port), self.timeout)
        self.sock.settimeout(self.timeout)

        banner = self._drain(1.0)
        if "password" in banner.lower():
            if not self.password:
                raise TelnetError(
                    "The server asked for a telnet password but none is configured. "
                    "Set TelnetPassword in serverconfig.xml, or PLUTAINER_RCON_PASSWORD."
                )
            self._write(self.password)
            reply = self._drain(1.5)
            if "logon successful" not in reply.lower() and "password incorrect" in reply.lower():
                raise TelnetError("Telnet password rejected by the server.")
        return banner

    def close(self):
        if self.sock is not None:
            try:
                self._write("exit")
            except Exception:
                pass
            try:
                self.sock.close()
            finally:
                self.sock = None

    def __enter__(self):
        self.connect()
        return self

    def __exit__(self, *_):
        self.close()

    # --- internals ----------------------------------------------------------

    def _write(self, line):
        self.sock.sendall((line + "\r\n").encode("utf-8", "replace"))

    def _drain(self, quiet_for):
        """Read until the server has been silent for `quiet_for` seconds."""
        chunks = []
        deadline = time.monotonic() + self.timeout
        self.sock.settimeout(quiet_for)
        while time.monotonic() < deadline:
            try:
                chunk = self.sock.recv(8192)
            except socket.timeout:
                break
            if not chunk:
                break
            chunks.append(chunk)
        self.sock.settimeout(self.timeout)
        return b"".join(chunks).decode("utf-8", "replace")

    # --- public -------------------------------------------------------------

    def command(self, cmd, quiet_for=1.0):
        if self.sock is None:
            raise TelnetError("not connected")
        self._write(cmd)
        return self._drain(quiet_for)

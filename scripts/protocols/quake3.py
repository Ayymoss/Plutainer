"""
Minimal Quake 3 connectionless-protocol client (UDP).

Derived from the Python Quake 3 Library, Copyright (C) 2006-2007 Gerald
Kaszuba (http://misc.slowchop.com/misc/wiki/pyquake3), and distributed under
the same terms: GNU General Public License version 2, or (at your option) any
later version.

Trimmed for Plutainer to the two things it actually does:

  * update()    — unauthenticated `getstatus`, used by healthcheck.sh
  * rcon(cmd)   — authenticated remote command, used by rcon-cli

The upstream player-list parsing (Player, parse_players, rcon_update) is gone:
nothing here consumed it, and the RCON `status` text it parsed is printed
verbatim by rcon-cli anyway.
"""

import socket


class Quake3Server(object):
    """A single UDP conversation with one game server."""

    packet_prefix = b'\xff' * 4

    # T7x (Black Ops III) puts a byte in front of the connectionless prefix:
    # its statusResponse arrives as b'D\xff\xff\xff\xffstatusResponse\n...'.
    # Every other engine here answers with the prefix at offset 0. Scan a short
    # window rather than demanding offset 0, so one parser covers both.
    prefix_search_window = 8

    def __init__(self, server, rcon_password=''):
        try:
            address, port = server.split(':')
        except (ValueError, AttributeError):
            raise ValueError('Server address format must be: "address:port"')

        self.address = address
        self.port = int(port)
        self.rcon_password = rcon_password
        self.values = None

        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.connect((self.address, self.port))

    def send_packet(self, data):
        self.sock.send(b'%s%s\n' % (self.packet_prefix, data.encode('utf-8')))

    def recv(self, timeout=1):
        self.sock.settimeout(timeout)
        try:
            return self.sock.recv(8192)
        except socket.error as err:
            raise Exception('Error receiving the packet: %s' % err)

    def command(self, cmd, timeout=1, retries=3):
        while retries:
            self.send_packet(cmd)
            try:
                data = self.recv(timeout)
            except Exception:
                data = None
            if data:
                return self.parse_packet(data)
            retries -= 1
        raise Exception('Server response timed out')

    def rcon(self, cmd):
        r_cmd = self.command('rcon "%s" %s' % (self.rcon_password, cmd))
        if r_cmd[1] in ('No rconpassword set on the server.\n', 'Bad rconpassword.\n'):
            raise Exception(r_cmd[1][:-1])
        return r_cmd

    def parse_packet(self, data):
        """Split a reply into (response type, payload), both decoded."""
        prefix_at = data.find(self.packet_prefix, 0, self.prefix_search_window)
        if prefix_at == -1:
            raise Exception('Malformed packet')

        body = data[prefix_at + len(self.packet_prefix):]

        # The response type is the first whitespace-delimited token, and the
        # separator is framing rather than payload. Which whitespace it is
        # varies by reply, so splitting on one of them only eats content:
        #
        #   statusResponse\n\key\value...   query replies use a newline
        #   print <text>                    rcon replies use a space, and the
        #                                   first line of the answer sits on
        #                                   that same line
        #
        # Splitting on '\n' alone therefore dropped the first line of every
        # rcon reply. `status` merely lost a banner, but a dvar query lost the
        # value line - the whole answer - and `Unknown command "..."` came back
        # as nothing at all, so a mistyped command was indistinguishable from a
        # server that had stopped answering.
        #
        # Not every reply carries a payload either: t5's zombies build answers
        # an unexpected connectionless packet with a bare b'disconnect' and no
        # separator. Treat that as "type, empty body" so callers see an empty
        # result rather than a parse error.
        separator = -1
        for index, char in enumerate(body):
            if char in b' \t\r\n':
                separator = index
                break

        if separator == -1:
            return body.decode('utf-8', 'ignore'), ''

        return (body[:separator].decode('utf-8', 'ignore'),
                body[separator + 1:].decode('utf-8', 'ignore'))

    def parse_status(self, data):
        """Parse a `\\key\\value\\key\\value` serverinfo string into a dict.

        A getstatus reply continues with one line per connected player after
        the serverinfo string; the last value therefore carries a trailing
        newline plus that list, which is truncated here.
        """
        split = data[1:].split('\\')
        values = dict(zip(split[::2], split[1::2]))
        for var, val in values.items():
            newline = val.find('\n')
            if newline != -1:
                values[var] = val[:newline]
        return values

    def query_values(self, query='getstatus'):
        """Send an unauthenticated query and parse its reply into a dict.

        `getstatus` and `getinfo` both answer with a serverinfo string; which
        one an engine honours (and which is authoritative) varies, so the
        caller picks.
        """
        values = self.parse_status(self.command(query)[1])
        self.values = values
        return values

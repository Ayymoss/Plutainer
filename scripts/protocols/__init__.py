"""
Wire protocols Plutainer speaks to game servers.

Split by protocol rather than by game, because the mapping is many-to-many: the
Quake3 connectionless protocol covers seven Call of Duty titles, A2S covers
every Steam-networked server regardless of engine, and administration is a
different protocol again from querying.

  quake3.py        Quake3 connectionless UDP — getstatus/getinfo and rcon.
                   Used by the CoD families for both query and admin.
  a2s.py           Valve's A2S_INFO UDP query. Read-only, no credentials.
                   Used by the SteamCMD family for health checks.
  source_rcon.py   Valve's RCON over TCP. Admin for Source games.
  telnet_admin.py  Line-oriented telnet console. Admin for 7 Days to Die.

Which one a game uses is decided by the family tables in scripts/lib/, not here.
"""

#!/usr/bin/env python3
"""fesl_server.py -- a minimal EA FESL / Theater backend for AoT: The 40th Day.

WHY THIS EXISTS (PASS135): the retail online co-op path fails at EA login, not at
ports/NAT/handler registration. Xenia-WebServices (:36000) emulates the Xbox LIVE
session layer, but the title ALSO needs EA's own backend. The fork resolves EA
hostnames to 127.0.0.1, so the title dials a local port and finds nothing:
   "CONNECTION UNAVAILABLE -- Unable to connect to EA Servers."

WIRE FORMAT -- captured byte-exact from the title (_runs/fesl_capture.txt), not
guessed:

    +0  char[4]  domain      'fsys' | 'acct' | 'pnow' | ...
    +4  u32be    packet id   0xC0000000|n = client request, 0x80000000|n = reply to n,
                             0xF0000000|n = server-initiated request (client replies 0x8...)
    +8  u32be    length      TOTAL bytes INCLUDING this 12-byte header
    +12 body     "key=value\n" * N  then a single trailing NUL

The title's opening packet is:
    fsys C0000001 len=179
    TXN=Hello clientString=ao3-360 sku=15751 locale=en_US clientPlatform=XBOX360
    clientVersion=1.0 SDKVersion=5.1.2.0.0 protocolVersion=2.0 fragmentSize=8096
    clientType=

METHOD: this is deliberately incremental and measure-first. Handlers are added
only for transactions the title has actually been observed to send. Anything
unhandled is logged loudly, in full, with a marker -- that log line is the
worklist for the next iteration. Do not speculatively implement transactions the
title has never asked for.

    python tools/runtime/fesl_server.py [--seconds 600] [--bind-address 127.0.0.1]

Log: _runs/fesl_server.txt
"""
import argparse
import base64
import os
import random
import selectors
import socket
import sys
import time
from pathlib import Path

FESL_PORT = 18131          # byte-proven: EnsureNetStarted 0x82C728A8 `li r7,0x46d3`
THEATER_PORT = 18275       # advertised in the Hello reply; we listen so we capture it
MESSENGER_PORT = 13505     # ditto
LOG = Path.cwd() / "_runs" / "fesl_server.txt"
# MEASURED, and load-bearing: the server-initiated MemCheck must go out with the
# CLIENT-request id class (0xC0000001), not the server-initiated one (0xF0000001).
# With c0 the title answers `MemCheck result=` and proceeds to NuXBL360Login; with
# f0 it closes the connection and re-dials every ~15s forever, never logging in.
# Confirmed both ways: PASS135's working capture is all `mode=c0`, and a PASS136
# run that defaulted to f0 died at exactly this transaction three times.
MEMCHECK_MODE = "c0"       # overridden by --memcheck
CLIENT_REQ = 0xC0000000
SERVER_REPLY = 0x80000000
SERVER_REQ = 0xF0000000
THEATER_REPLY_ID = 0x00000000   # overridden by --theater-id
# A full retail load can legitimately leave Theater quiet for more than four
# minutes.  Advertising 240 seconds closed Daddy's socket at +241s, so CJ's
# later EGRQ targeted the stale Conn retained by game 1 and failed WSAENOTSOCK.
# The earlier JS backend already proved 86400 as the server-side lifetime fix.
ACTIVITY_TIMEOUT_SECS = "86400"

# PASS136 rungs. The join notification itself (rung 1) is always on -- without it
# the host is never told anyone entered and both rigs sit at CONNECTING forever
# (PASS135_BOUNDARY.md 13.4). Rungs 2 and 3 are the extra host-directed pushes,
# default OFF so a single boot bisects them against the PASS135 baseline.
JOIN_NOTIFY = True              # AOT_JOIN_NOTIFY=0 -- restore PASS135 behaviour
HOST_PENT = False               # AOT_HOST_PENT=1   -- push PENT to the host
HOST_EGEG = False               # AOT_HOST_EGEG=1   -- host-directed EGEG
HOST_SELF_UID_EGRQ = False      # AOT_HOST_SELF_UID_EGRQ=1 -- EGRQ UID is recipient
ACK_HOST_EGRS = False           # AOT_ACK_HOST_EGRS=1 -- reply to host verdict txn
HOST_SELF_EGRQ = False          # AOT_HOST_SELF_EGRQ=1 -- mediate host's own EGAM
EGRQ_PLAIN_XUID = False         # AOT_EGRQ_PLAIN_XUID=1 -- include retail plain XUID
EGRQ_PLAIN_INT_ADDR = False     # AOT_EGRQ_PLAIN_INT_ADDR=1 -- include INT-IP/PORT


def hexdump(b, indent="    "):
    out = []
    for off in range(0, len(b), 16):
        c = b[off:off + 16]
        out.append("%s%04X  %-47s  |%s|" % (
            indent, off, " ".join("%02X" % x for x in c),
            "".join(chr(x) if 32 <= x < 127 else "." for x in c)))
    return "\n".join(out)


class Log:
    def __init__(self, path):
        path.parent.mkdir(parents=True, exist_ok=True)
        self.f = path.open("w", encoding="utf-8")

    def __call__(self, msg):
        line = "[%s] %s" % (time.strftime("%H:%M:%S"), msg)
        print(line, flush=True)
        self.f.write(line + "\n")
        self.f.flush()


def parse_body(body):
    """body -> ordered list of (key, value); tolerant of the trailing NUL."""
    kv = []
    for part in body.rstrip(b"\x00").split(b"\n"):
        if not part:
            continue
        k, _, v = part.partition(b"=")
        kv.append((k.decode("latin1"), v.decode("latin1")))
    return kv


def build(domain, pid, pairs):
    body = b"".join(("%s=%s\n" % (k, v)).encode("latin1") for k, v in pairs) + b"\x00"
    return domain.encode("latin1")[:4].ljust(4, b" ") + \
        pid.to_bytes(4, "big") + (len(body) + 12).to_bytes(4, "big") + body


def ea_time():
    """EA's stringly-typed timestamp, with an UPPERCASE month.

    Not cosmetic: the client's own string table has the month names in caps
    ('JAN','FEB',...,'DEC' at 0x8226EB4C..) sitting immediately after 'curTime'
    and 'Current Time: %s' (0x8226EAB8/0x8226EAC0), i.e. that table is the
    curTime parser's month lookup. A mixed-case 'Jul-30-2026' fails it.
    """
    return time.strftime("%b-%d-%Y %H:%M:%S UTC", time.gmtime()).upper()


def xnaddr_ip(b64):
    """The synthetic IPv4 a peer must be dialled on = first 4 bytes of its XNADDR.

    MEASURED against the PASS135 capture, both directions:
      host 'fwoUHg==' -> 7F 0A 14 1E -> 127.10.20.30, which is
           exactly the INT-IP the host put in its own CGAM;
      joiner 'fygyPA==' -> 7F 28 32 3C -> 127.40.50.60.
    This matters because EGAM carries R-XNADDR and PORT but NO R-INT-IP -- the
    joiner's address exists only inside the blob.
    """
    try:
        raw = base64.b64decode(b64 + "===")
    except Exception:
        return ""
    if len(raw) < 4:
        return ""
    return ".".join(str(b) for b in raw[:4])


# The FESL login (port 18131) and Theater (18275) are SEPARATE TCP connections, so
# a Theater conn has no gamertag/xuid of its own. Neither LKEY (one shared
# constant) nor the source address (both rigs dial from 127.0.0.1) can tell them
# apart. The MAC can, exactly: the login carries macAddr and the Theater USER
# carries the same string as MAC --
#   host   macAddr=$<12-hex>      xuid=<synthetic online identity>
#   joiner macAddr=$006655443322  xuid=<synthetic online identity>
# both MEASURED in _runs/fesl_server.txt. So logins are recorded under the MAC and
# the Theater side resolves against it.
IDENTITIES = {}     # normalised mac -> {"gamertag", "xuid", "uid"}


def norm_mac(mac):
    return (mac or "").lstrip("$").replace("-", "").replace(":", "").lower()


class Conn:
    def __init__(self, sock, addr, port, log):
        self.sock, self.addr, self.port, self.log = sock, addr, port, log
        self.rx = bytearray()
        self.next_server_id = 1
        self.gamertag = None
        self.xuid = None
        self.uid = None
        self.hosted_gid = None
        self.joined_gid = None

    def send(self, domain, pid, pairs, why=""):
        pkt = build(domain, pid, pairs)
        try:
            self.sock.sendall(pkt)
        except OSError as exc:
            # A title can close immediately after a reply (for example while
            # rejecting a handshake variant). That is a per-connection outcome,
            # not a reason to take down the process and every other listener.
            self.log("!! send failed on port %d: %s -- dropping connection"
                     % (self.port, exc))
            return False
        self.log("TX %s id=%08X %s\n%s" % (domain, pid, why, hexdump(pkt)))
        return True

    def feed(self, data):
        self.rx += data
        while len(self.rx) >= 12:
            total = int.from_bytes(self.rx[8:12], "big")
            if total < 12 or total > 1 << 20:
                self.log("!! bad length %d -- dropping connection" % total)
                self.rx.clear()
                return False
            if len(self.rx) < total:
                return True
            pkt = bytes(self.rx[:total])
            del self.rx[:total]
            self.handle(pkt)
        return True

    def handle(self, pkt):
        domain = pkt[0:4].decode("latin1").rstrip()
        pid = int.from_bytes(pkt[4:8], "big")
        kv = parse_body(pkt[12:])
        d = dict(kv)
        txn = d.get("TXN", "")
        self.log("RX %s id=%08X TXN=%s  %s" % (domain, pid, txn, kv))
        if not txn:
            # Theater-style packet (command in the domain slot, no TXN).
            # Log the raw bytes so the exact framing is on record.
            self.log("   raw:\n%s" % hexdump(pkt))

        key = (domain, txn)
        fn = HANDLERS.get(key)
        if fn is None:
            # The worklist marker. Grep the log for UNHANDLED to see what to add.
            self.log("!!! UNHANDLED (%s,%s) -- implement next. full body: %s"
                     % (domain, txn, kv))
            return
        if "gamertag" in d:
            self.gamertag = d["gamertag"]
        fn(self, pid, d)


# ---------------------------------------------------------------- handlers

CYCLE = False
CYCLE_N = [0]


def h_fsys_hello_cycle(conn, pid, d):
    """One reply variant per connection attempt, so a single boot A/Bs them all.

    The title re-dials FESL every ~11-17 s until it gives up, so cycling the
    variant per connection gets four data points from one boot instead of four
    boots. Variants are ordered so that the discriminating question -- is the
    close about the packet HEADER or the BODY? -- is answered first.
    """
    n = CYCLE_N[0]
    CYCLE_N[0] += 1
    txn = pid & 0x00FFFFFF
    full = [
        ("TXN", "Hello"),
        ("domainPartition.domain", "eagames"),
        ("domainPartition.subDomain", d.get("clientString", "ao3-360")),
        ("curTime", ea_time()),
        ("activityTimeoutSecs", ACTIVITY_TIMEOUT_SECS),
        ("messengerIp", "127.0.0.1"),
        ("messengerPort", str(MESSENGER_PORT)),
        ("theaterIp", "127.0.0.1"),
        ("theaterPort", str(THEATER_PORT)),
        ("addressRemapping", ""),
        ("minPingSitesToPing", "0"),
        ("pingSite.[]", "1"),
        ("pingSite.0.name", "loc"),
        ("pingSite.0.addr", "127.0.0.1"),
        ("pingSite.0.type", "0"),
    ]
    variants = [
        ("V0 id=0x80|txn, full body", SERVER_REPLY | txn, full),
        ("V1 id=echo request id", pid, full),
        ("V2 id=0x80|txn, TXN only", SERVER_REPLY | txn, [("TXN", "Hello")]),
        ("V3 no reply at all (control)", None, None),
    ]
    label, rid, body = variants[n % len(variants)]
    conn.log(">>> VARIANT %d: %s" % (n, label))
    if rid is None:
        conn.log("   (sending nothing -- control)")
        return
    conn.send("fsys", rid, body, why="(Hello reply, variant %d)" % n)


def h_fsys_hello(conn, pid, d):
    if CYCLE:
        return h_fsys_hello_cycle(conn, pid, d)
    # The client's Hello-response key table is at 0x8226EA54..0x8226EB44 and reads,
    # in order: fsys, theaterPort, messengerPort, theaterIp, messengerIp,
    # addressRemapping, activityTimeoutSecs, curTime, "Current Time: %s", reason,
    # minPingSitesToPing, pingSite.[], pingSite.%d.{name,addr,type}, MemCheck, result.
    # Everything below is a key that table names -- nothing speculative.
    #
    # PACKET ID: echo the request id verbatim. MEASURED, not assumed -- a
    # variant-cycling A/B in one boot (see the V0/V1 experiment in
    # _runs/fesl_server.txt) showed the title CLOSES the connection on
    # `0x80000000|txn` (the convention later FESL servers use) and KEEPS it open
    # on the echoed `0xC0000001`. This SDK is 5.1.2.0.0 / protocolVersion 2.0;
    # direction is implied by who sent the packet, not by an id prefix.
    hello = [
        ("TXN", "Hello"),
        ("domainPartition.domain", "eagames"),
        ("domainPartition.subDomain", d.get("clientString", "ao3-360")),
        ("curTime", ea_time()),
        ("activityTimeoutSecs", ACTIVITY_TIMEOUT_SECS),
        ("messengerIp", "127.0.0.1"),
        ("messengerPort", str(MESSENGER_PORT)),
        ("theaterIp", "127.0.0.1"),
        ("theaterPort", str(THEATER_PORT)),
        # QoS ping sites. The client has a full pingSite.%d.* parser, so give it
        # one reachable site and require zero successful pings, rather than an
        # empty list it might treat as a failure.
        ("minPingSitesToPing", "0"),
        ("pingSite.[]", "1"),
        ("pingSite.0.name", "loc"),
        ("pingSite.0.addr", "127.0.0.1"),
        ("pingSite.0.type", "0"),
    ]
    # EA's server follows Hello with a server-initiated MemCheck. That much is
    # documented behaviour, but the packet-id prefix for a SERVER-initiated
    # request is the one thing here I cannot read off the capture (the title has
    # only ever sent 0xC0......), so it is switchable and A/B-able:
    #   --memcheck none  omit it entirely (is it even required?)
    #   --memcheck f0    0xF0000000|n
    #   --memcheck c0    0xC0000000|n
    mode = MEMCHECK_MODE
    if mode == "none":
        if not conn.send("fsys", pid, hello, why="(reply to Hello)"):
            return
        conn.log("   (MemCheck suppressed by --memcheck none)")
        return
    prefix = SERVER_REQ if mode == "f0" else CLIENT_REQ
    # Keep these as two immediate writes. AoT rejects both a deliberately
    # coalesced pair and a 50 ms-delayed MemCheck. The title may abandon this
    # first socket anyway; the driver holds at SAVE SLOT for its 30s retry.
    if not conn.send("fsys", pid, hello, why="(reply to Hello)"):
        return
    conn.send("fsys", prefix | conn.next_server_id, [
        ("TXN", "MemCheck"),
        ("memcheck.[]", "0"),
        ("salt", "5"),
    ], why="(server-initiated MemCheck, mode=%s)" % mode)
    conn.next_server_id += 1


def h_fsys_memcheck(conn, pid, d):
    # Client's reply to our MemCheck. Nothing to do but note it.
    conn.log("   (client answered MemCheck; no response required)")


# ------------------------------------------------------- acct (login) domain
#
# Response keys below all come from the client's own acct key tables --
# 0x82275E20..0x822762CC (transaction names + request keys) and
# 0x8226E100..0x8226E35C (response keys: personas.[], personas.%d, nuid, userId,
# names.[], ...) plus 'lkey' at 0x82277A68 and 'tos' at 0x82277A64. Note
# 'profileId' and 'displayName' do NOT appear anywhere in the image, so this SDK
# does not use them -- do not send them.
#
# The title's own login request (observed) is:
#   acct C0000002 TXN=NuXBL360Login xuid=<synthetic> gamertag=host
#                 macAddr=$<12-hex> consoleId=<synthetic console id>
# and 012345678 is a literal in the image at 0x82276154, i.e. the SDK's own
# default consoleId.

LKEY = "AbCd1234EfGh5678IjKl9012MnOp3456"


def h_acct_xbl360login(conn, pid, d):
    gamertag = d.get("gamertag", "player")
    xuid = d.get("xuid", "1")
    try:
        xuid_n = int(xuid)
    except ValueError:
        xuid_n = 1
    uid = str(xuid_n & 0x7FFFFFFF)
    conn.gamertag, conn.xuid, conn.uid = gamertag, xuid, uid
    # Record it for the Theater conn to resolve later (see IDENTITIES).
    mac = norm_mac(d.get("macAddr"))
    if mac:
        IDENTITIES[mac] = {"gamertag": gamertag, "xuid": xuid, "uid": uid}
    conn.send("acct", pid, [
        ("TXN", "NuXBL360Login"),
        ("lkey", LKEY),
        ("nuid", gamertag),
        ("userId", uid),
    ], why="(login accepted for %s, xuid=%s)" % (gamertag, xuid))


def h_acct_getpersonas(conn, pid, d):
    # Anticipated follow-up: the client asks which personas the account owns.
    # Keys personas.[] / personas.%d are in the table at 0x8226E124/0x8226E130.
    conn.send("acct", pid, [
        ("TXN", "NuGetPersonas"),
        ("personas.[]", "1"),
        ("personas.0", conn.gamertag or "player"),
    ], why="(one persona)")


def h_acct_loginpersona(conn, pid, d):
    name = d.get("name", conn.gamertag or "player")
    conn.send("acct", pid, [
        ("TXN", "NuLoginPersona"),
        ("lkey", LKEY),
        ("profileId", "1"),
        ("userId", "1"),
    ], why="(persona %s logged in)" % name)


# ----------------------------------------- the rest of the observed worklist
#
# Everything below was added because the title ACTUALLY SENT it (see the RX lines
# in _runs/fesl_server.txt), and every response key is one the image contains.
# The fsys transaction-name table is at 0x82276440 (Hello, Ping, Goodbye, Suicide,
# MemCheck, GetPingSites); the asso key table at 0x82276398 uses a %s-prefixed
# list shape (%s.[] , %s.%d.owner. , %s.%d.member. , %s.%d.mutual) where %s is the
# association type.

PING_SITES = [
    ("minPingSitesToPing", "0"),
    ("pingSite.[]", "1"),
    ("pingSite.0.name", "loc"),
    ("pingSite.0.addr", "127.0.0.1"),
    ("pingSite.0.type", "0"),
]


def h_fsys_getpingsites(conn, pid, d):
    conn.send("fsys", pid, [("TXN", "GetPingSites")] + PING_SITES,
              why="(one loopback ping site, zero required)")


def h_fsys_ping(conn, pid, d):
    conn.send("fsys", pid, [("TXN", "Ping")], why="(pong)")


def h_fsys_goodbye(conn, pid, d):
    # The client says goodbye and gives its reason. This is the single most useful
    # diagnostic line in the log: reason + an ErrType/ErrCode pair.
    conn.log("   *** CLIENT GOODBYE: reason=%s message=%s ***"
             % (d.get("reason", "?"), d.get("message", "?")))


def h_asso_getassociations(conn, pid, d):
    # type=PlasmaBlock on the observed request. Reply with an EMPTY list of that
    # type -- the account blocks nobody -- echoing the partition and owner back.
    t = d.get("type", "PlasmaBlock")
    conn.send("asso", pid, [
        ("TXN", "GetAssociations"),
        ("domainPartition.domain", d.get("domainPartition.domain", "eagames")),
        ("domainPartition.subDomain", d.get("domainPartition.subDomain", "ao3-360")),
        ("type", t),
        ("owner.id", d.get("owner.id", "1")),
        ("owner.type", d.get("owner.type", "1")),
        ("owner.name", conn.gamertag or "player"),
        ("%s.[]" % t, "0"),
        ("maxListSize", "100"),
    ], why="(empty %s list)" % t)


def h_acct_lookupuserinfo(conn, pid, d):
    # The title looks up the OTHER players' xuids here (two of them on the
    # observed request) -- this is the roster/gamertag resolution. Echo one
    # userInfo entry per requested xuid; keys from 0x8226E1E4..0x8226E24C.
    n = int(d.get("userInfo.[]", "0") or 0)
    pairs = [("TXN", "NuLookupUserInfo"), ("userInfo.[]", str(n))]
    for i in range(n):
        xuid = d.get("userInfo.%d.xuid" % i, "0")
        pairs += [
            ("userInfo.%d.userName" % i, "player%d" % i),
            ("userInfo.%d.userId" % i, str(int(xuid or 0) & 0x7FFFFFFF)),
            ("userInfo.%d.masterUserId" % i, str(int(xuid or 0) & 0x7FFFFFFF)),
            ("userInfo.%d.xuid" % i, xuid),
            ("userInfo.%d.namespace" % i, "XBOX360"),
        ]
    conn.send("acct", pid, pairs, why="(resolved %d xuid(s))" % n)


def h_theater_conn(conn, pid, d):
    """Theater 'CONN' -- a DIFFERENT protocol on the theaterPort we advertised.

    Framing is the same 12-byte header, but the 4-char field carries the COMMAND
    (not a domain), there is no TXN key, and the id observed is 0x40000000.
    Observed request: PROT=2 PROD=ao3-360 VERS=1.0 PLAT=XBOX360 LOCALE=en_US
    SDKVERSION=5.1.2.0.0 TID=1.
    """
    # ID: 0, not the echoed 0x40000000. MEASURED -- echoing 0x40000000 made the
    # client say Goodbye with `ErrType=2 ErrCode=1073741824`, and 1073741824 IS
    # 0x40000000, i.e. it reported the id we sent back as the error. Theater's
    # 0x40000000 marks a client->server command; a server reply is not that.
    conn.send("CONN", THEATER_REPLY_ID, [
        ("TID", d.get("TID", "1")),
        ("TIME", str(int(time.time()))),
        ("activityTimeoutSecs", ACTIVITY_TIMEOUT_SECS),
        ("PROT", d.get("PROT", "2")),
    ], why="(theater connect accepted, reply id=%08X)" % THEATER_REPLY_ID)


def h_theater_user(conn, pid, d):
    """Theater 'USER' -- the client authenticating on Theater with our lkey.

    Observed: CID= MAC=$<12-hex> SKU=15751 LKEY=<the lkey we issued in
    NuXBL360Login> NAME= TID=2. Theater's own key strings are at 0x822767A0
    (COUNT, PROT, NAME, LOCALE, REASON).
    """
    # Resolve who this Theater conn belongs to from the MAC (see IDENTITIES). The
    # EGRQ we later push to the host has to name the joiner, and a 360 host denies
    # the join outright without it.
    mac = norm_mac(d.get("MAC"))
    ident = IDENTITIES.get(mac)
    if ident:
        conn.gamertag = ident["gamertag"]
        conn.xuid = ident["xuid"]
        conn.uid = ident["uid"]
    conn.send("USER", THEATER_REPLY_ID, [
        ("NAME", conn.gamertag or "player"),
        ("TID", d.get("TID", "1")),
    ], why="(theater user authenticated, lkey matched=%s, resolved=%s)"
       % (d.get("LKEY") == LKEY, conn.gamertag or "UNRESOLVED mac=%s" % mac))


# ------------------------------------------------------------ game registry
#
# Theater's whole point: the host CREATES a game (CGAM) advertising the endpoint
# its peer should dial, and the joiner LISTS (GLST) and ENTERS (EGAM) it. Keeping
# the created games here is what makes same-PC pairing possible at all.
#
# The observed CGAM from the host carries exactly the endpoint pair the peer
# needs -- INT-IP=127.10.20.30 INT-PORT=1000 PORT=1000 -- i.e. this instance's
# synthetic loopback IP (see xsocket.cc) and the game port. Note this is the
# same :1000 that PASS133 mistook for a same-PC collision: it is the GAME port,
# and the two instances differ by IP, so it never collided.

GAMES = {}          # gid -> dict of CGAM fields
NEXT_GID = [1]
NEXT_PLAYER_PID = [100]     # theater player ids, kept clear of gids


def _conn_socket_is_open(conn):
    """Whether a game's owning Theater connection can still be advertised."""
    sock = getattr(conn, "sock", None)
    if sock is None:
        return False
    try:
        return sock.fileno() >= 0
    except (AttributeError, OSError, TypeError, ValueError):
        return False


def _remove_games_for_conn(conn):
    """Drop every game owned by a connection that the event loop is closing."""
    removed = [
        gid for gid, game in list(GAMES.items())
        if game.get("_conn") is conn
    ]
    for gid in removed:
        del GAMES[gid]
    if removed:
        conn.hosted_gid = None
    return removed


def _remove_players_for_conn(conn):
    """Remove a disconnected entrant from every game that still has a host."""
    removed = []
    for gid, game in GAMES.items():
        players = game.get("_players") or []
        departed = [player for player in players if player.get("conn") is conn]
        if departed:
            game["_players"] = [
                player for player in players if player.get("conn") is not conn
            ]
            removed.extend((gid, player) for player in departed)

        pending = game.get("_pending")
        if pending:
            for player_pid, player in list(pending.items()):
                if player.get("conn") is conn:
                    del pending[player_pid]

    conn.joined_gid = None
    return removed


def h_theater_cgam(conn, pid, d):
    gid = NEXT_GID[0]
    NEXT_GID[0] += 1
    g = dict(d)
    g["GID"] = str(gid)
    g["_conn"] = conn
    # The host sends UGID and SECRET EMPTY (measured), so the server mints the
    # session credentials. They are not decoration: the guest's connect-confirm
    # parser reads PID/TICKET/UGID/EKEY off the EGEG, and an absent EKEY leaves
    # conn+0x150 unpopulated. EKEY is the exact 24-char blob the previous backend
    # paired with (ea_fesl.js:64) -- kept verbatim rather than regenerated.
    g["EKEY"] = "AIBSgPFqRDg0TfdXW1zUyQ=="
    g["UGID"] = d.get("UGID") or ("AO3-%d" % gid)
    g["SECRET"] = d.get("SECRET") or ("S%dECRET" % gid)
    g["TICKET"] = str(random.randint(1000000000, 9999999999))
    if conn.gamertag is None:
        conn.gamertag = d.get("NAME") or None      # CGAM carries NAME=daddy
    GAMES[gid] = g
    conn.hosted_gid = gid
    # The host is player 0 of its own game from the moment it creates it; its EGAM
    # fills in the endpoint.
    g["_players"] = []
    conn.log("   *** GAME CREATED gid=%d name=%s endpoint=%s:%s map=%s ***"
             % (gid, d.get("NAME"), d.get("INT-IP"), d.get("INT-PORT"),
                d.get("B-U-Map")))
    conn.send("CGAM", THEATER_REPLY_ID, [
        ("TID", d.get("TID", "1")),
        ("LID", d.get("LID", "1")),
        ("GID", str(gid)),
        ("MAX-PLAYERS", d.get("MAX-PLAYERS", "2")),
        ("NAME", d.get("NAME", "")),
        ("JOIN", d.get("JOIN", "O")),
        ("QUEUE-LENGTH", "0"),
        ("EKEY", g["EKEY"]),
        ("UGID", g["UGID"]),
        ("SECRET", g["SECRET"]),
        ("J", "O"),
    ], why="(game %d created, ugid=%s ticket=%s)" % (gid, g["UGID"], g["TICKET"]))


def _gdat_pairs(g):
    """The advertised game record. Carries the endpoint a peer must dial."""
    return [
        ("LID", g.get("LID", "1")),
        ("GID", g["GID"]),
        ("HN", g.get("NAME", "")),
        ("N", g.get("NAME", "")),
        ("I", g.get("INT-IP", "127.0.0.1")),
        ("P", g.get("PORT", "1000")),
        ("MP", g.get("MAX-PLAYERS", "2")),
        ("AP", str(len(g.get("_players", ())) or 1)),
        ("JP", "0"),
        ("QP", "0"),
        ("PL", "XBOX360"),
        ("PW", "0"),
        ("TYPE", g.get("TYPE", "G")),
        ("J", "O"),
        ("B-version", g.get("B-version", "AO3-100")),
        ("B-U-Mode", g.get("B-U-Mode", "CAMPAIGN")),
        ("B-U-Map", g.get("B-U-Map", "")),
        ("B-U-Friendly", g.get("B-U-Friendly", "")),
        ("B-U-ChangeList", g.get("B-U-ChangeList", "")),
        ("B-U-Private", g.get("B-U-Private", "false")),
        ("B-U-Difficulty", g.get("B-U-Difficulty", "1")),
        ("B-U-DLC", g.get("B-U-DLC", "1")),
        ("B-U-NAT", g.get("B-U-NAT", "1")),
        ("B-U-PlayerSkin", g.get("B-U-PlayerSkin", "0")),
        ("B-maxObservers", "0"),
        ("B-numObservers", "0"),
        ("XB360SESS", g.get("XB360SESS", "")),
        ("SECRET", g.get("SECRET", "")),
        ("UGID", g.get("UGID", "")),
    ]


def h_theater_glst(conn, pid, d):
    """Theater 'GLST' -- browse for a game to join.

    The host sends this FIRST (its filters mirror its own campaign checkpoint:
    FILTER-ATTR-U-Mode=CAMPAIGN, -Friendly=01_00, -ChangeList=97620) and only
    creates its own game when the list comes back empty. So a joiner seeing the
    host's game here is exactly the pairing moment.

    Don't return the requester its own game -- that would make the host try to
    join itself.
    """
    tid = d.get("TID", "1")
    live_games = [
        g for g in GAMES.values()
        if _conn_socket_is_open(g.get("_conn"))
    ]
    games = [g for g in live_games if g.get("_conn") is not conn]
    conn.send("GLST", THEATER_REPLY_ID, [
        ("TID", tid),
        ("LID", d.get("LID", "1")),
        ("LOBBY-NUM-GAMES", str(len(live_games))),
        ("NUM-GAMES", str(len(games))),
        ("LOBBY-MAX-GAMES", "100"),
    ], why="(%d game(s) visible to %s)" % (len(games), conn.gamertag))
    for g in games:
        conn.send("GDAT", THEATER_REPLY_ID, [("TID", tid)] + _gdat_pairs(g),
                  why="(advertising game %s)" % g["GID"])


def h_theater_ecnl(conn, pid, d):
    """Acknowledge the title leaving a Theater channel/game.

    The retail client waits for this transaction even when it is tearing down a
    failed local session.  The legacy backend echoed these identifiers exactly;
    omitting the reply leaves the frontend waiting on an already-failed route.
    ECNL is not treated as authority to delete a hosted game here because the
    title has separate XSession/RGAM cleanup paths for that state change.
    """
    conn.send("ECNL", THEATER_REPLY_ID, [
        ("TID", d.get("TID", "0")),
        ("LID", d.get("LID", "0")),
        ("GID", d.get("GID", "0")),
    ], why="(exit channel/game acknowledged)")


def _player_from_egam(conn, d):
    """One player record. EGAM carries R-XNADDR + PORT but no R-INT-IP, so the
    dialable address has to come out of the blob (see xnaddr_ip)."""
    xnaddr = d.get("R-XNADDR", "")
    return {
        "name": conn.gamertag or "player",
        # The joiner's EGAM carries R-U-XUID directly (measured); the host's own
        # EGAM carries no R-U-* at all, so fall back to the login-side identity.
        "xuid": d.get("R-U-XUID") or conn.xuid or "0",
        "uid": conn.uid or "0",
        "xnaddr": xnaddr,
        "ip": xnaddr_ip(xnaddr),
        "port": d.get("PORT", "1000"),
        "ptype": d.get("PTYPE", "P"),
        "conn": conn,
    }


def _push(target, domain, pairs, why=""):
    """Server-initiated push to a connection that did not ask for it.

    Theater pushes use id 0 like every other Theater reply -- NOT 0x40000000,
    which the client reports straight back as ErrType=2 ErrCode=1073741824 (see
    h_theater_conn), and NOT SERVER_REQ, which is the FESL-domain class.
    A dead peer socket must not take the server down with it.
    """
    try:
        return target.send(domain, THEATER_REPLY_ID, pairs, why=why)
    except OSError as e:
        target.log("   !! push %s failed: %s" % (domain, e))
        return False


def _send_egrq_to_host(g, player, egam, ppid, host_self=False):
    """Ask the game's host to admit one pending player.

    Retail Theater runs this transaction for the host's own EGAM too.  That
    first, self-addressed request is significant to AoT: its EGRQ handler
    allocates the native local roster member before any remote player joins.
    """
    gid = int(g["GID"])
    host_conn = g.get("_conn")
    if host_conn is None:
        player["conn"].log(
            "   !! game %d has no host connection -- cannot notify" % gid)
        return False

    host_player = g.get("_host_player") or {}
    if host_self:
        # The entering player and recipient are the same person in this first
        # transaction, so both the plain and R-* identities name the host.
        egrq_uid = player["uid"]
    else:
        # Historical A/B switch retained for old captures.  Proper roster
        # classification leaves this OFF so a remote EGRQ's UID names the
        # remote player and does not overwrite the local-member pointer.
        egrq_uid = ((host_player.get("uid") or "0")
                    if HOST_SELF_UID_EGRQ else player["uid"])

    egrq = [
        ("R-INT-IP", player["ip"]),
        ("R-INT-PORT", player["port"]),
    ]
    # Retail Blaze/Theater schemas distinguish the remote-prefixed endpoint
    # from the entering player's plain internal endpoint.  Keep the completion
    # default-off so this remains an exact packet-level A/B against Attempt 11.
    if EGRQ_PLAIN_INT_ADDR:
        egrq += [
            ("INT-IP", player["ip"]),
            ("INT-PORT", player["port"]),
        ]
    egrq += [
        ("PORT", player["port"]),
        ("IP", player["ip"]),
        ("R-XNADDR", player["xnaddr"]),
        ("NAME", player["name"]),
        ("PTYPE", player["ptype"]),
        ("TICKET", g.get("TICKET", "")),
        ("PID", ppid),
    ]
    if EGRQ_PLAIN_XUID:
        egrq.append(("XUID", player["xuid"]))
    egrq += [
        ("UID", egrq_uid),
        ("LID", egam.get("LID", g.get("LID", "1"))),
        ("GID", str(gid)),
    ]
    egrq += [(k, v) for k, v in sorted(egam.items())
             if k.startswith("R-U-")]
    egrq += [
        ("R-XUID", player["xuid"]),
        ("R-UID", player["uid"]),
        ("R-USER", player["name"]),
    ]
    kind = "HOST-SELF-ENTRY" if host_self else "JOIN-REQ"
    return _push(
        host_conn, "EGRQ", egrq,
        why="(%s: %s pid=%s %s:%s -> host of game %d; UID=%s R-UID=%s)"
             % (kind, player["name"], ppid, player["ip"], player["port"],
                gid, egrq_uid, player["uid"]))


def h_theater_egam(conn, pid, d):
    """Theater 'EGAM' -- enter a game.

    Two callers, and they must NOT be treated alike:

      * the HOST enters its OWN freshly-created game (measured: PORT=1000
        R-XNADDR=<blob> PTYPE=P LID=1 GID=1 TID=6, and no R-U-* attributes).
        It just needs its enter acknowledged.
      * a JOINER enters someone else's game (measured: the same plus the full
        R-U-* attribute set including R-U-XUID).

    For the joiner this handler deliberately sends NOTHING back. Real Theater
    asks the host first (EGRQ) and only completes the joiner once the host has
    answered (EGRS). Acking here instead -- which is what PASS135 did -- is why
    both rigs sat at CONNECTING: the host was never told anyone had arrived.
    """
    gid = int(d.get("GID", "0") or 0)
    g = GAMES.get(gid)
    tid = d.get("TID", "1")
    if g is None:
        conn.log("   !! EGAM for unknown gid=%s" % d.get("GID"))
        return
    p = _player_from_egam(conn, d)
    players = g.setdefault("_players", [])
    conn.joined_gid = gid

    if g.get("_conn") is conn:
        p["host"] = True
        g["_host_player"] = p
        if players and players[0].get("host"):
            players[0] = p
        else:
            players.insert(0, p)
        # Phrasing kept so watch_pairing.sh's "HOST entered" marker still matches.
        conn.log("   *** HOST entered its own game %d as %s (%s:%s) ***"
                 % (gid, p["name"], p["ip"], p["port"]))
        if not HOST_SELF_EGRQ:
            conn.send("EGAM", THEATER_REPLY_ID, [
                ("TID", tid),
                ("LID", g.get("LID", "1")),
                ("GID", str(gid)),
                ("QPOS", "0"),
                ("QLEN", "0"),
            ], why="(host entered its own game; immediate legacy ack)")
            return

        # The first per-game Theater player id is 1.  Defer the host's EGAM
        # reply exactly like any other entrant until its own EGRS verdict comes
        # back; this is the transaction that creates AoT's native local member.
        ppid = "1"
        p["pid"] = ppid
        p["egam_tid"] = tid
        g.setdefault("_pending", {})[ppid] = p
        conn.log("   *** HOST self-entry queued as pid=1 -- EGRQ->host, "
                 "awaiting host EGRS ***")
        _send_egrq_to_host(g, p, d, ppid, host_self=True)
        return

    # ---- joiner ----
    ppid = str(NEXT_PLAYER_PID[0])
    NEXT_PLAYER_PID[0] += 1
    p["pid"] = ppid
    p["egam_tid"] = tid
    players.append(p)
    g.setdefault("_pending", {})[ppid] = p
    conn.log("   *** %s ENTERED game %d as pid=%s (%s:%s, now %d player(s)) "
             "-- EGRQ->host, awaiting host EGRS ***"
             % (p["name"], gid, ppid, p["ip"], p["port"], len(players)))

    if not JOIN_NOTIFY:
        # Rung 0: the exact PASS135 behaviour, kept switchable so the baseline is
        # an A/B inside one session rather than a checkout. Acks the joiner at
        # once and tells the host nothing -- both rigs should stall at CONNECTING.
        conn.log("   [rung0] AOT_JOIN_NOTIFY=0 -- acking joiner, host NOT notified")
        conn.send("EGAM", THEATER_REPLY_ID, [
            ("TID", tid), ("LID", g.get("LID", "1")), ("GID", str(gid)),
        ], why="(rung0 enter accepted)")
        conn.send("EGRS", THEATER_REPLY_ID, [
            ("TID", tid), ("ALLOWED", "1"),
        ], why="(rung0 entry granted)")
        return

    _send_egrq_to_host(g, p, d, ppid)


def h_theater_egrs(conn, pid, d):
    """Theater 'EGRS' -- the HOST's verdict on the EGRQ we pushed it.

    EGRS travels INBOUND from the host; it is not a grant the server hands the
    joiner. Only now is the joiner completed: its deferred EGAM ack (carrying its
    ORIGINAL TID, not this transaction's) followed by the EGEG that tells it which
    endpoint to dial.

    The verdict is relayed honestly. ALLOWED=0 REASON=2 is the documented symptom
    of an EGRQ missing R-XUID/R-UID/R-USER, and masking it would hide exactly the
    signal this pass is trying to read.
    """
    # Retail Theater treats the host verdict as a normal request transaction.
    # Both Arcadia and GoFesl answer EGRS@ with an id-0 EGRS carrying only the
    # original TID, before completing the joiner. Keep this default-off for the
    # isolated A/B: the previous backend consumed the verdict but never
    # completed the host's registered 10-second waiter.
    if ACK_HOST_EGRS:
        conn.send("EGRS", THEATER_REPLY_ID, [
            ("TID", d.get("TID", "0")),
        ], why="(host verdict transaction ack)")

    gid = int(d.get("GID", "0") or 0) or (conn.hosted_gid or 0)
    g = GAMES.get(gid)
    allowed = d.get("ALLOWED", "1")
    reason = d.get("REASON", "-")
    if g is None:
        conn.log("   !! EGRS for unknown gid=%s" % d.get("GID"))
        return
    pending = g.get("_pending") or {}
    ppid = d.get("PID") or ""
    j = pending.get(ppid)
    if j is None and pending:
        ppid, j = sorted(pending.items())[0]
    if j is None:
        conn.log("   !! EGRS gid=%d allowed=%s but no pending joiner"
                 % (gid, allowed))
        return
    pending.pop(ppid, None)

    if allowed != "1":
        conn.log("   *** HOST DENIED %s (pid=%s): ALLOWED=%s REASON=%s ***"
                 % (j["name"], ppid, allowed, reason))
        _push(j["conn"], "EGAM", [
            ("TID", j["egam_tid"]),
            ("LID", g.get("LID", "1")),
            ("GID", str(gid)),
            ("ALLOWED", allowed),
            ("REASON", reason),
        ], why="(host denied the join)")
        return

    conn.log("   *** HOST ALLOWED %s (pid=%s) -- completing entry ***"
             % (j["name"], ppid))
    hp = g.get("_host_player") or {}
    host_ip = hp.get("ip") or g.get("INT-IP", "127.0.0.1")
    host_port = hp.get("port") or g.get("PORT", "1000")

    # 1) the deferred EGAM ack, on the joiner's ORIGINAL TID
    _push(j["conn"], "EGAM", [
        ("TID", j["egam_tid"]),
        ("LID", g.get("LID", "1")),
        ("GID", str(gid)),
        ("ALLOWED", "1"),
    ], why="(deferred enter-ack, original tid=%s)" % j["egam_tid"])

    # 2) EGEG -- the host's endpoint. This is what the joiner goes active off.
    _push(j["conn"], "EGEG", [
        ("PL", "XBOX360"),
        ("TICKET", g.get("TICKET", "")),
        ("PID", ppid),
        ("P", host_port),
        ("HUID", hp.get("uid", "0")),
        ("INT-PORT", host_port),
        ("EKEY", g.get("EKEY", "")),
        ("INT-IP", host_ip),
        ("UGID", g.get("UGID", "")),
        ("I", host_ip),
        ("R-XNADDR", hp.get("xnaddr", "")),
        ("XB360SESS", g.get("XB360SESS", "")),
        ("LID", g.get("LID", "1")),
        ("GID", str(gid)),
    ], why="(EGEG->joiner: dial host at %s:%s)" % (host_ip, host_port))

    if j.get("host"):
        # The host's self-entry is complete.  The optional host-directed PENT
        # and second EGEG below are experimental notifications for a *remote*
        # joiner and must not be duplicated for this local bootstrap.
        conn.log("   *** HOST native self-entry complete as pid=%s ***" % ppid)
        return

    # 3) rung 2 -- PENT to the host. Previously measured as CONSUMED (the host
    #    echoes its own PENT ~28ms later and sets joinable=true) but INERT for
    #    member-add, so it is an acceptance signal, not the lever.
    if HOST_PENT:
        _push(conn, "PENT", [
            ("GID", str(gid)),
            ("LID", g.get("LID", "1")),
            ("PID", ppid),
            ("TICKET", g.get("TICKET", "")),
            ("NAME", j["name"]),
            ("UID", j["uid"]),
            ("R-XNADDR", j["xnaddr"]),
            ("INT-IP", j["ip"]),
            ("INT-PORT", j["port"]),
            ("IP", j["ip"]),
            ("PORT", j["port"]),
            ("PTYPE", j["ptype"]),
        ], why="(rung2 HOST-PENT: %s joined)" % j["name"])

    # 4) rung 3 -- host-directed EGEG carrying the JOINER's address, mirroring the
    #    joiner's. On the old path this was what first made the host recognise the
    #    peer and enter the connect-confirm (a stable 2-player lobby, the furthest
    #    the project has reached). Kept last and OFF by default.
    if HOST_EGEG:
        _push(conn, "EGEG", [
            ("PL", "XBOX360"),
            ("TICKET", g.get("TICKET", "")),
            ("PID", ppid),
            ("P", j["port"]),
            ("HUID", j["uid"]),
            ("INT-PORT", j["port"]),
            ("EKEY", g.get("EKEY", "")),
            ("INT-IP", j["ip"]),
            ("UGID", g.get("UGID", "")),
            ("I", j["ip"]),
            ("R-XNADDR", j["xnaddr"]),
            ("XB360SESS", g.get("XB360SESS", "")),
            ("LID", g.get("LID", "1")),
            ("GID", str(gid)),
        ], why="(rung3 HOST-EGEG: dial joiner at %s:%s)" % (j["ip"], j["port"]))


def h_theater_plvt(conn, pid, d):
    """Acknowledge the client's post-enter player-status transaction."""
    conn.send("PLVT", THEATER_REPLY_ID, [
        ("TID", d.get("TID", "0")),
        ("LID", d.get("LID", "0")),
        ("GID", d.get("GID", "0")),
        ("PID", d.get("PID", "0")),
    ], why="(post-enter player status ack)")


def h_theater_pent(conn, pid, d):
    """Complete the title's player-activation transaction.

    After the host accepts the peer's native hello, AoT sends PENT and waits up
    to 10 seconds for this Theater reply.  Leaving it unanswered makes the
    shipped activation callback remove the peer before it can send the roster.
    """
    # Match the captured retail service exactly: its 27-byte success frame
    # carries PID then TID and uses the Theater response id (zero). LID/GID are
    # request context, not response fields for this transaction.
    conn.send("PENT", THEATER_REPLY_ID, [
        ("PID", d.get("PID", "0")),
        ("TID", d.get("TID", "0")),
    ], why="(player activation ack)")


def h_theater_ubra(conn, pid, d):
    """Acknowledge the host's bracket-update transaction."""
    conn.send("UBRA", THEATER_REPLY_ID, [
        ("TID", d.get("TID", "0")),
    ], why="(host bracket update ack)")


def _h_theater_game_update(conn, d, component):
    """Record the host-open fields and complete UGAM/UGDE."""
    gid = int(d.get("GID", "0") or 0)
    g = GAMES.get(gid)
    if g is not None:
        g["_can_join"] = True
        for key, value in d.items():
            if key == "JOIN" or key.startswith("B-"):
                g[key] = value
    conn.send(component, THEATER_REPLY_ID, [
        ("TID", d.get("TID", "0")),
    ], why="(host game-open update ack)")


def h_theater_ugam(conn, pid, d):
    _h_theater_game_update(conn, d, "UGAM")


def h_theater_ugde(conn, pid, d):
    _h_theater_game_update(conn, d, "UGDE")


def h_theater_llst(conn, pid, d):
    """Theater 'LLST' -- LOBBY list (not game list).

    Theater's lobby/game keys are at 0x82272F60..0x82273010 and 0x8227861B
    (IN-SIZE, FAV-GAME, FILTER-ATTR-U-, TID, LID, GID, NUM-GAMES,
    LOBBY-MAX-GAMES, LOBBY-NUM-GAMES, NUM-LOBBIES, PASSING, FAVORITE-GAMES,
    FAVORITE-PLAYERS, NOGUID, UGID). Observed request carries the filter set plus
    FAV-GAME=AO3-100 and TID=3.

    Advertise exactly one empty lobby: a host needs a lobby to create its game in,
    and an empty game list is what makes it host rather than join.
    """
    tid = d.get("TID", "1")
    conn.send("LLST", THEATER_REPLY_ID, [
        ("TID", tid),
        ("NUM-LOBBIES", "1"),
    ], why="(one lobby)")
    conn.send("LDAT", THEATER_REPLY_ID, [
        ("TID", tid),
        ("LID", "1"),
        ("PASSING", "0"),
        ("NAME", "ao3"),
        ("LOCALE", d.get("LOCALE", "en_US")),
        ("MAX-GAMES", "100"),
        ("FAVORITE-GAMES", "0"),
        ("FAVORITE-PLAYERS", "0"),
        # Captured PASS135 contract: LDAT describes the lobby and leaves the
        # game count at zero.  AoT then issues GLST, whose reply carries the
        # live game count and GDAT records.  Putting the live count here made
        # the title skip GLST and self-host with LID=-1.
        ("NUM-GAMES", "0"),
    ], why="(lobby 1, captured empty-LDAT contract)")


def h_acct_telemetrytoken(conn, pid, d):
    # Key 'telemetryToken' at 0x8226E2AC.
    conn.send("acct", pid, [
        ("TXN", "GetTelemetryToken"),
        ("telemetryToken", "0,127.0.0.1,9946,ao3-360,0,0,0,0,0,0,0"),
    ], why="(telemetry token)")


def h_acct_lockerurl(conn, pid, d):
    conn.send("acct", pid, [
        ("TXN", "GetLockerURL"),
        ("URL", "http://127.0.0.1:36000/locker"),
    ], why="(locker url)")


def h_acct_getentitlements(conn, pid, d):
    # Key 'entitlements.[]' at 0x8226E398. Empty list = owns no extra DLC, which
    # is the truthful answer for a bare disc install.
    conn.send("acct", pid, [
        ("TXN", "NuGetEntitlements"),
        ("entitlements.[]", "0"),
    ], why="(no entitlements)")


def h_acct_grantentitlement(conn, pid, d):
    # The title grants its own achievements through EA as well as XBL. Accept.
    conn.send("acct", pid, [("TXN", "NuGrantEntitlement")],
              why="(granted %s)" % d.get("entitlementTag", "?"))


def h_pres_subscribe(conn, pid, d):
    # Presence keys are at 0x822767C8..0x8227683C (PresenceSubscribe,
    # PresenceUnsubscribe, SetPresenceStatus, AsyncPresenceStatusEvent,
    # status.show, status.status). Echo the request set back as subscribed.
    n = int(d.get("requests.[]", "0") or 0)
    pairs = [("TXN", "PresenceSubscribe"), ("requests.[]", str(n))]
    for i in range(n):
        pairs += [
            ("requests.%d.userId" % i, d.get("requests.%d.userId" % i, "0")),
            ("requests.%d.status.show" % i, "0"),
            ("requests.%d.status.status" % i, ""),
        ]
    conn.send("pres", pid, pairs, why="(subscribed %d user(s))" % n)


def h_pres_setstatus(conn, pid, d):
    conn.send("pres", pid, [("TXN", "SetPresenceStatus")], why="(status accepted)")


HANDLERS = {
    ("fsys", "Hello"): h_fsys_hello,
    ("fsys", "MemCheck"): h_fsys_memcheck,
    ("fsys", "GetPingSites"): h_fsys_getpingsites,
    ("fsys", "Ping"): h_fsys_ping,
    ("fsys", "Goodbye"): h_fsys_goodbye,
    ("acct", "NuXBL360Login"): h_acct_xbl360login,
    ("acct", "NuGetPersonas"): h_acct_getpersonas,
    ("acct", "NuLoginPersona"): h_acct_loginpersona,
    ("acct", "NuLookupUserInfo"): h_acct_lookupuserinfo,
    ("asso", "GetAssociations"): h_asso_getassociations,
    ("pres", "PresenceSubscribe"): h_pres_subscribe,
    ("pres", "SetPresenceStatus"): h_pres_setstatus,
    # Theater: keyed on the command, which lands in the domain slot with no TXN.
    ("acct", "GetTelemetryToken"): h_acct_telemetrytoken,
    ("acct", "GetLockerURL"): h_acct_lockerurl,
    ("acct", "NuGetEntitlements"): h_acct_getentitlements,
    ("acct", "NuGrantEntitlement"): h_acct_grantentitlement,
    ("CONN", ""): h_theater_conn,
    ("USER", ""): h_theater_user,
    ("LLST", ""): h_theater_llst,
    ("CGAM", ""): h_theater_cgam,
    ("GLST", ""): h_theater_glst,
    ("ECNL", ""): h_theater_ecnl,
    ("EGAM", ""): h_theater_egam,
    ("EGRS", ""): h_theater_egrs,
    ("PENT", ""): h_theater_pent,
    ("PLVT", ""): h_theater_plvt,
    ("UBRA", ""): h_theater_ubra,
    ("UGAM", ""): h_theater_ugam,
    ("UGDE", ""): h_theater_ugde,
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seconds", type=int, default=600)
    ap.add_argument(
        "--bind-address", choices=["127.0.0.1"], default="127.0.0.1",
        help="same-PC alpha safety boundary; only loopback is accepted")
    ap.add_argument("--memcheck", choices=["none", "f0", "c0"], default="c0",
                    help="id class for the server-initiated MemCheck; c0 is the "
                         "only value the title accepts (see MEMCHECK_MODE)")
    ap.add_argument("--cycle", action="store_true",
                    help="one Hello-reply variant per connection attempt")
    ap.add_argument("--theater-id", default="0",
                    help="hex id to use on Theater replies (default 0)")
    ap.add_argument("--log", default=str(LOG),
                    help="log path (opened with 'w' -- point it away from the "
                         "default when a run must not clobber a kept capture)")
    args = ap.parse_args()
    global MEMCHECK_MODE, CYCLE
    MEMCHECK_MODE = args.memcheck
    CYCLE = args.cycle
    global THEATER_REPLY_ID
    THEATER_REPLY_ID = int(args.theater_id, 16)
    global JOIN_NOTIFY, HOST_PENT, HOST_EGEG, HOST_SELF_UID_EGRQ, ACK_HOST_EGRS
    global HOST_SELF_EGRQ, EGRQ_PLAIN_XUID, EGRQ_PLAIN_INT_ADDR
    JOIN_NOTIFY = os.environ.get("AOT_JOIN_NOTIFY", "1") == "1"
    HOST_PENT = os.environ.get("AOT_HOST_PENT", "0") == "1"
    HOST_EGEG = os.environ.get("AOT_HOST_EGEG", "0") == "1"
    HOST_SELF_UID_EGRQ = os.environ.get("AOT_HOST_SELF_UID_EGRQ", "0") == "1"
    ACK_HOST_EGRS = os.environ.get("AOT_ACK_HOST_EGRS", "0") == "1"
    HOST_SELF_EGRQ = os.environ.get("AOT_HOST_SELF_EGRQ", "0") == "1"
    EGRQ_PLAIN_XUID = os.environ.get("AOT_EGRQ_PLAIN_XUID", "0") == "1"
    EGRQ_PLAIN_INT_ADDR = (
        os.environ.get("AOT_EGRQ_PLAIN_INT_ADDR", "0") == "1")
    log = Log(Path(args.log))
    log("PASS136 rungs: JOIN_NOTIFY(EGRQ/EGRS)=%s HOST_PENT=%s HOST_EGEG=%s"
        % (JOIN_NOTIFY, HOST_PENT, HOST_EGEG))
    log("PASS136 identity: HOST_SELF_UID_EGRQ=%s"
        % HOST_SELF_UID_EGRQ)
    log("PASS138 transaction: ACK_HOST_EGRS=%s" % ACK_HOST_EGRS)
    log("PASS139 roster bootstrap: HOST_SELF_EGRQ=%s" % HOST_SELF_EGRQ)
    log("PASS140 identity completion: EGRQ_PLAIN_XUID=%s"
        % EGRQ_PLAIN_XUID)
    log("PASS141 endpoint completion: EGRQ_PLAIN_INT_ADDR=%s"
        % EGRQ_PLAIN_INT_ADDR)

    # Refuse to start alongside another backend. On Windows SO_REUSEADDR does NOT
    # mean "rebind after TIME_WAIT" as it does on POSIX -- it lets a SECOND socket
    # bind a port that is already being listened on. Both processes then log
    # "server up" and the OS hands new connections to one of them arbitrarily.
    # Measured 2026-07-30: a stale backend from a previous rung silently absorbed
    # the whole session, so the run under test was never the one being measured.
    # A pre-bind probe turns that into a loud failure.
    for p in (FESL_PORT, THEATER_PORT, MESSENGER_PORT):
        try:
            probe = socket.create_connection(("127.0.0.1", p), timeout=0.5)
        except OSError:
            continue
        probe.close()
        log("FATAL: something is already listening on %d -- another fesl_server?" % p)
        log("       kill it first; two servers on one port measure nothing.")
        return 2

    sel = selectors.DefaultSelector()
    bound = []
    for p in (FESL_PORT, THEATER_PORT, MESSENGER_PORT):
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            s.bind((args.bind_address, p))
            s.listen(8)
            s.setblocking(False)
            sel.register(s, selectors.EVENT_READ, ("listen", p))
            bound.append(p)
        except OSError as e:
            log("port %d NOT bound (%s)" % (p, e))
            s.close()
    log("FESL server up on %s:%s for %ds"
        % (args.bind_address, bound, args.seconds))

    deadline = time.time() + args.seconds
    while time.time() < deadline:
        for key, _ in sel.select(timeout=1.0):
            kind, meta = key.data
            if kind == "listen":
                c, addr = key.fileobj.accept()
                c.setblocking(False)
                conn = Conn(c, addr, meta, log)
                sel.register(c, selectors.EVENT_READ, ("conn", conn))
                log("*** CONNECT port %d from %s:%d ***" % (meta, addr[0], addr[1]))
            else:
                conn = meta
                try:
                    data = key.fileobj.recv(16384)
                except OSError:
                    data = b""
                if not data or not conn.feed(data):
                    log("closed: port %d from %s" % (conn.port, conn.addr[0]))
                    for gid in _remove_games_for_conn(conn):
                        log("   *** GAME REMOVED gid=%s host=%s reason=connection-closed ***"
                            % (gid, conn.gamertag or "UNRESOLVED"))
                    for gid, player in _remove_players_for_conn(conn):
                        log("   *** PLAYER REMOVED gid=%s pid=%s name=%s "
                            "reason=connection-closed ***"
                            % (gid, player.get("pid", "?"),
                               player.get("name", "player")))
                    sel.unregister(key.fileobj)
                    key.fileobj.close()
    log("window over")


if __name__ == "__main__":
    sys.exit(main())

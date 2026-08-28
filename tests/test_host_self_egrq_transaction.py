#!/usr/bin/env python3
"""Focused contract test for the native Theater host-roster bootstrap.

This exercises the handler functions directly.  It intentionally opens no
sockets and never touches either live rig.  The enabled path must model the
retail transaction as two distinct admissions:

  host EGAM -> self EGRQ(pid=1) -> host EGRS -> deferred EGAM + EGEG
  CJ EGAM   -> CJ EGRQ(pid=100), still pending its own host verdict

The feature remains an A/B gate: with HOST_SELF_EGRQ false, the historical
immediate host-EGAM acknowledgement is preserved exactly.  Plain XUID and the
plain internal endpoint are separate default-off completion gates; the
existing R-prefixed identity/address fields and PID must not change.
"""

import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools" / "runtime"))

import fesl_server  # noqa: E402


THEATER_REQUEST = 0x40000000
HOST = {
    "name": "host",
    "xuid": "9000000000000001",
    "uid": str(9000000000000001 & 0x7FFFFFFF),
    "xnaddr": "fwoUHg==",
    "ip": "127.10.20.30",
}
CJ = {
    "name": "joiner",
    "xuid": "9000000000000002",
    "uid": str(9000000000000002 & 0x7FFFFFFF),
    "xnaddr": "fygyPA==",
    "ip": "127.40.50.60",
}


class FakeConn:
    """Smallest connection surface used by CGAM/EGAM/EGRS and _push."""

    def __init__(self, identity):
        self.gamertag = identity["name"]
        self.xuid = identity["xuid"]
        self.uid = identity["uid"]
        self.joined_gid = None
        self.hosted_gid = None
        self.frames = []
        self.logs = []

    def send(self, domain, packet_id, pairs, why=""):
        ordered = list(pairs)
        self.frames.append({
            "domain": domain,
            "packet_id": packet_id,
            "pairs": ordered,
            "fields": dict(ordered),
            "why": why,
        })
        return True

    def log(self, message):
        self.logs.append(message)


def frames_since(conn, start, domain=None):
    frames = conn.frames[start:]
    if domain is not None:
        frames = [frame for frame in frames if frame["domain"] == domain]
    return frames


class HostSelfEgrqTransactionTest(unittest.TestCase):
    def setUp(self):
        self.assertTrue(
            hasattr(fesl_server, "HOST_SELF_EGRQ"),
            "fesl_server must declare the independently gated HOST_SELF_EGRQ flag",
        )
        self.assertTrue(
            hasattr(fesl_server, "EGRQ_PLAIN_XUID"),
            "fesl_server must declare the independently gated EGRQ_PLAIN_XUID flag",
        )
        self.assertTrue(
            hasattr(fesl_server, "EGRQ_PLAIN_INT_ADDR"),
            "fesl_server must declare the independently gated EGRQ_PLAIN_INT_ADDR flag",
        )
        self.saved_flags = {
            name: getattr(fesl_server, name)
            for name in (
                "JOIN_NOTIFY",
                "HOST_PENT",
                "HOST_EGEG",
                "HOST_SELF_UID_EGRQ",
                "ACK_HOST_EGRS",
                "HOST_SELF_EGRQ",
                "EGRQ_PLAIN_XUID",
                "EGRQ_PLAIN_INT_ADDR",
            )
        }
        fesl_server.GAMES.clear()
        fesl_server.NEXT_GID[0] = 1
        fesl_server.NEXT_PLAYER_PID[0] = 100
        fesl_server.JOIN_NOTIFY = True
        fesl_server.HOST_PENT = False
        fesl_server.HOST_EGEG = False
        # A later CJ EGRQ must describe CJ, not falsely compare as host-self.
        fesl_server.HOST_SELF_UID_EGRQ = False
        fesl_server.ACK_HOST_EGRS = True
        fesl_server.EGRQ_PLAIN_XUID = False
        fesl_server.EGRQ_PLAIN_INT_ADDR = False

    def tearDown(self):
        for name, value in self.saved_flags.items():
            setattr(fesl_server, name, value)
        fesl_server.GAMES.clear()
        fesl_server.NEXT_GID[0] = 1
        fesl_server.NEXT_PLAYER_PID[0] = 100

    def create_game(self):
        host = FakeConn(HOST)
        fesl_server.h_theater_cgam(host, THEATER_REQUEST, {
            "LID": "1",
            "RESERVE-HOST": "1",
            "NAME": HOST["name"],
            "PORT": "1000",
            "TYPE": "G",
            "INT-PORT": "1000",
            "INT-IP": HOST["ip"],
            "MAX-PLAYERS": "2",
            "UGID": "",
            "SECRET": "",
            "B-U-Mode": "CAMPAIGN",
            "B-version": "AO3-100",
            "JOIN": "C",
            "XB360SESS": "-5908495911602746880",
            "TID": "5",
        })
        self.assertEqual(host.hosted_gid, 1)
        self.assertIn(1, fesl_server.GAMES)
        return host, fesl_server.GAMES[1]

    @staticmethod
    def host_egam(host):
        fesl_server.h_theater_egam(host, THEATER_REQUEST, {
            "PORT": "1000",
            "R-XNADDR": HOST["xnaddr"],
            "PTYPE": "P",
            "LID": "1",
            "GID": "1",
            "TID": "6",
        })

    def test_gate_is_default_off_and_preserves_immediate_baseline(self):
        self.assertIs(
            self.saved_flags["HOST_SELF_EGRQ"],
            False,
            "HOST_SELF_EGRQ must be default-off at import",
        )
        fesl_server.HOST_SELF_EGRQ = False
        host, game = self.create_game()
        start = len(host.frames)

        self.host_egam(host)

        emitted = frames_since(host, start)
        self.assertEqual([frame["domain"] for frame in emitted], ["EGAM"])
        self.assertEqual(emitted[0]["fields"]["TID"], "6")
        self.assertNotIn("_pending", game)
        self.assertEqual(len(game["_players"]), 1)
        self.assertTrue(game["_players"][0]["host"])

    def test_host_self_admission_then_cj_remains_distinct(self):
        fesl_server.HOST_SELF_EGRQ = True
        host, game = self.create_game()
        host_start = len(host.frames)

        self.host_egam(host)

        self_admission = frames_since(host, host_start)
        self.assertEqual(
            [frame["domain"] for frame in self_admission],
            ["EGRQ"],
            "host EGAM must be deferred until the self EGRQ verdict",
        )
        self_egrq = self_admission[0]
        self.assertEqual(self_egrq["packet_id"], fesl_server.THEATER_REPLY_ID)
        self.assertEqual(self_egrq["fields"]["PID"], "1")
        self.assertNotIn("XUID", self_egrq["fields"])
        self.assertEqual(self_egrq["fields"]["UID"], HOST["uid"])
        self.assertEqual(self_egrq["fields"]["R-UID"], HOST["uid"])
        self.assertEqual(self_egrq["fields"]["R-XUID"], HOST["xuid"])
        self.assertEqual(self_egrq["fields"]["R-USER"], HOST["name"])
        self.assertEqual(self_egrq["fields"]["R-XNADDR"], HOST["xnaddr"])
        self.assertEqual(self_egrq["fields"]["IP"], HOST["ip"])
        self.assertNotIn("INT-IP", self_egrq["fields"])
        self.assertNotIn("INT-PORT", self_egrq["fields"])
        self.assertEqual(game["_host_player"]["pid"], "1")
        self.assertIs(game["_pending"]["1"], game["_host_player"])

        # These are remote-join experiments.  Even if a later run enables them,
        # completing the local bootstrap must not echo a PENT or second EGEG at
        # the host itself.
        fesl_server.HOST_PENT = True
        fesl_server.HOST_EGEG = True
        verdict_start = len(host.frames)
        fesl_server.h_theater_egrs(host, THEATER_REQUEST, {
            "TID": "7",
            "GID": "1",
            "LID": "1",
            "PID": "1",
            "ALLOWED": "1",
        })

        completion = frames_since(host, verdict_start)
        self.assertEqual(
            [frame["domain"] for frame in completion],
            ["EGRS", "EGAM", "EGEG"],
        )
        egrs_ack, egam_ack, egeg = completion
        self.assertEqual(egrs_ack["fields"], {"TID": "7"})
        self.assertEqual(egam_ack["fields"]["TID"], "6")
        self.assertEqual(egam_ack["fields"]["ALLOWED"], "1")
        self.assertEqual(egeg["fields"]["PID"], "1")
        self.assertEqual(egeg["fields"]["HUID"], HOST["uid"])
        self.assertEqual(egeg["fields"]["INT-IP"], HOST["ip"])
        self.assertEqual(egeg["fields"]["R-XNADDR"], HOST["xnaddr"])
        self.assertFalse(game["_pending"])

        cj = FakeConn(CJ)
        host_before_cj = len(host.frames)
        cj_before = len(cj.frames)
        fesl_server.h_theater_egam(cj, THEATER_REQUEST, {
            "R-U-ChangeList": "97620",
            "R-U-DLC": "1",
            "R-U-JOINASHOST": "0",
            "R-U-MaxPlayers": "2",
            "R-U-Mode": "CAMPAIGN",
            "R-U-NAT": "1",
            "R-U-Private": "false",
            "R-U-XUID": CJ["xuid"],
            "PORT": "1000",
            "R-XNADDR": CJ["xnaddr"],
            "PTYPE": "P",
            "LID": "1",
            "GID": "1",
            "TID": "5",
        })

        self.assertEqual(
            frames_since(cj, cj_before),
            [],
            "CJ must remain pending until Daddy answers CJ's own EGRQ",
        )
        cj_pushes = frames_since(host, host_before_cj)
        self.assertEqual([frame["domain"] for frame in cj_pushes], ["EGRQ"])
        cj_egrq = cj_pushes[0]["fields"]
        self.assertEqual(cj_egrq["PID"], "100")
        self.assertNotIn("XUID", cj_egrq)
        self.assertEqual(cj_egrq["UID"], CJ["uid"])
        self.assertEqual(cj_egrq["R-UID"], CJ["uid"])
        self.assertEqual(cj_egrq["R-XUID"], CJ["xuid"])
        self.assertEqual(cj_egrq["R-USER"], CJ["name"])
        self.assertEqual(cj_egrq["R-U-Mode"], "CAMPAIGN")
        self.assertNotIn("INT-IP", cj_egrq)
        self.assertNotIn("INT-PORT", cj_egrq)
        self.assertNotEqual(cj_egrq["PID"], self_egrq["fields"]["PID"])
        self.assertNotEqual(cj_egrq["UID"], self_egrq["fields"]["UID"])
        self.assertIn("100", game["_pending"])
        self.assertEqual([player["pid"] for player in game["_players"]], ["1", "100"])

    def test_plain_xuid_gate_adds_host_and_cj_identity_only(self):
        self.assertIs(
            self.saved_flags["EGRQ_PLAIN_XUID"],
            False,
            "EGRQ_PLAIN_XUID must be default-off at import",
        )
        fesl_server.HOST_SELF_EGRQ = True
        fesl_server.EGRQ_PLAIN_XUID = True
        host, game = self.create_game()
        host_start = len(host.frames)

        self.host_egam(host)

        self_pushes = frames_since(host, host_start)
        self.assertEqual([frame["domain"] for frame in self_pushes], ["EGRQ"])
        self_egrq = self_pushes[0]["fields"]
        self.assertEqual(self_egrq["XUID"], HOST["xuid"])
        self.assertEqual(self_egrq["R-XUID"], HOST["xuid"])
        self.assertEqual(self_egrq["PID"], "1")

        fesl_server.h_theater_egrs(host, THEATER_REQUEST, {
            "TID": "7",
            "GID": "1",
            "LID": "1",
            "PID": "1",
            "ALLOWED": "1",
        })
        self.assertFalse(game["_pending"])

        cj = FakeConn(CJ)
        host_before_cj = len(host.frames)
        fesl_server.h_theater_egam(cj, THEATER_REQUEST, {
            "R-U-ChangeList": "97620",
            "R-U-DLC": "1",
            "R-U-JOINASHOST": "0",
            "R-U-MaxPlayers": "2",
            "R-U-Mode": "CAMPAIGN",
            "R-U-NAT": "1",
            "R-U-Private": "false",
            "R-U-XUID": CJ["xuid"],
            "PORT": "1000",
            "R-XNADDR": CJ["xnaddr"],
            "PTYPE": "P",
            "LID": "1",
            "GID": "1",
            "TID": "5",
        })

        cj_pushes = frames_since(host, host_before_cj)
        self.assertEqual([frame["domain"] for frame in cj_pushes], ["EGRQ"])
        cj_egrq = cj_pushes[0]["fields"]
        self.assertEqual(cj_egrq["XUID"], CJ["xuid"])
        self.assertEqual(cj_egrq["R-XUID"], CJ["xuid"])
        self.assertEqual(cj_egrq["PID"], "100")
        self.assertNotEqual(cj_egrq["XUID"], self_egrq["XUID"])

    def test_plain_internal_endpoint_gate_adds_host_and_cj_address_only(self):
        self.assertIs(
            self.saved_flags["EGRQ_PLAIN_INT_ADDR"],
            False,
            "EGRQ_PLAIN_INT_ADDR must be default-off at import",
        )
        fesl_server.HOST_SELF_EGRQ = True
        fesl_server.EGRQ_PLAIN_INT_ADDR = True
        host, game = self.create_game()
        host_start = len(host.frames)

        self.host_egam(host)

        self_pushes = frames_since(host, host_start)
        self.assertEqual([frame["domain"] for frame in self_pushes], ["EGRQ"])
        self_egrq = self_pushes[0]["fields"]
        self.assertEqual(self_egrq["INT-IP"], HOST["ip"])
        self.assertEqual(self_egrq["INT-PORT"], "1000")
        self.assertEqual(self_egrq["R-INT-IP"], HOST["ip"])
        self.assertEqual(self_egrq["R-INT-PORT"], "1000")
        self.assertEqual(self_egrq["PID"], "1")
        self.assertNotIn("XUID", self_egrq)

        fesl_server.h_theater_egrs(host, THEATER_REQUEST, {
            "TID": "7",
            "GID": "1",
            "LID": "1",
            "PID": "1",
            "ALLOWED": "1",
        })
        self.assertFalse(game["_pending"])

        cj = FakeConn(CJ)
        host_before_cj = len(host.frames)
        fesl_server.h_theater_egam(cj, THEATER_REQUEST, {
            "R-U-ChangeList": "97620",
            "R-U-DLC": "1",
            "R-U-JOINASHOST": "0",
            "R-U-MaxPlayers": "2",
            "R-U-Mode": "CAMPAIGN",
            "R-U-NAT": "1",
            "R-U-Private": "false",
            "R-U-XUID": CJ["xuid"],
            "PORT": "1000",
            "R-XNADDR": CJ["xnaddr"],
            "PTYPE": "P",
            "LID": "1",
            "GID": "1",
            "TID": "5",
        })

        cj_pushes = frames_since(host, host_before_cj)
        self.assertEqual([frame["domain"] for frame in cj_pushes], ["EGRQ"])
        cj_egrq = cj_pushes[0]["fields"]
        self.assertEqual(cj_egrq["INT-IP"], CJ["ip"])
        self.assertEqual(cj_egrq["INT-PORT"], "1000")
        self.assertEqual(cj_egrq["R-INT-IP"], CJ["ip"])
        self.assertEqual(cj_egrq["R-INT-PORT"], "1000")
        self.assertEqual(cj_egrq["PID"], "100")
        self.assertNotIn("XUID", cj_egrq)


if __name__ == "__main__":
    unittest.main(verbosity=2)

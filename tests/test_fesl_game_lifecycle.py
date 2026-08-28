#!/usr/bin/env python3
"""Socket-free contracts for Theater game ownership and advertisement."""

import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools" / "runtime"))

import fesl_server  # noqa: E402


class FakeSocket:
    def __init__(self, descriptor):
        self.descriptor = descriptor

    def fileno(self):
        return self.descriptor

    def close(self):
        self.descriptor = -1


class FakeConn:
    def __init__(self, gamertag, descriptor):
        self.gamertag = gamertag
        self.sock = FakeSocket(descriptor)
        self.hosted_gid = None
        self.joined_gid = None
        self.frames = []

    def send(self, domain, packet_id, pairs, why=""):
        ordered = list(pairs)
        self.frames.append({
            "domain": domain,
            "packet_id": packet_id,
            "fields": dict(ordered),
            "why": why,
        })
        return True


def add_game(gid, owner, name):
    fesl_server.GAMES[gid] = {
        "GID": str(gid),
        "NAME": name,
        "INT-IP": "127.0.0.%d" % gid,
        "PORT": "1000",
        "MAX-PLAYERS": "2",
        "_players": [],
        "_conn": owner,
    }
    owner.hosted_gid = gid


def add_player(gid, conn, pid, name, host=False, pending=False):
    player = {
        "pid": str(pid),
        "name": name,
        "conn": conn,
        "host": host,
    }
    game = fesl_server.GAMES[gid]
    game["_players"].append(player)
    if host:
        game["_host_player"] = player
    if pending:
        game.setdefault("_pending", {})[str(pid)] = player
    conn.joined_gid = gid
    return player


class FeslGameLifecycleTest(unittest.TestCase):
    def setUp(self):
        fesl_server.GAMES.clear()

    def tearDown(self):
        fesl_server.GAMES.clear()

    def test_disconnect_cleanup_removes_only_the_disconnected_hosts_game(self):
        disconnected_host = FakeConn("old-host", -1)
        live_host = FakeConn("live-host", 42)
        add_game(1, disconnected_host, "old-host")
        add_game(2, live_host, "live-host")

        removed = fesl_server._remove_games_for_conn(disconnected_host)

        self.assertEqual(removed, [1])
        self.assertNotIn(1, fesl_server.GAMES)
        self.assertIn(2, fesl_server.GAMES)
        self.assertIsNone(disconnected_host.hosted_gid)
        self.assertEqual(live_host.hosted_gid, 2)

    def test_glst_defensively_excludes_closed_host_and_advertises_live_host(self):
        closed_host = FakeConn("old-host", -1)
        live_host = FakeConn("live-host", 42)
        joiner = FakeConn("joiner", 43)
        add_game(1, closed_host, "old-host")
        add_game(2, live_host, "live-host")

        fesl_server.h_theater_glst(
            joiner,
            0x40000000,
            {"TID": "7", "LID": "1"},
        )

        self.assertEqual(
            [frame["domain"] for frame in joiner.frames],
            ["GLST", "GDAT"],
        )
        self.assertEqual(joiner.frames[0]["fields"]["LOBBY-NUM-GAMES"], "1")
        self.assertEqual(joiner.frames[0]["fields"]["NUM-GAMES"], "1")
        self.assertEqual(joiner.frames[1]["fields"]["GID"], "2")
        self.assertIn(2, fesl_server.GAMES)

    def test_joiner_disconnect_removes_player_and_pending_capacity(self):
        host = FakeConn("live-host", 42)
        departed = FakeConn("CJ", -1)
        browser = FakeConn("reconnecting-CJ", 43)
        add_game(1, host, "live-host")
        add_player(1, host, 1, "live-host", host=True)
        add_player(1, departed, 100, "CJ", pending=True)

        removed = fesl_server._remove_players_for_conn(departed)
        fesl_server.h_theater_glst(
            browser,
            0x40000000,
            {"TID": "9", "LID": "1"},
        )

        self.assertEqual(
            [(gid, player["pid"]) for gid, player in removed],
            [(1, "100")],
        )
        self.assertEqual(
            [player["name"] for player in fesl_server.GAMES[1]["_players"]],
            ["live-host"],
        )
        self.assertEqual(fesl_server.GAMES[1]["_pending"], {})
        self.assertIs(fesl_server.GAMES[1]["_conn"], host)
        self.assertIs(fesl_server.GAMES[1]["_host_player"]["conn"], host)
        self.assertIsNone(departed.joined_gid)
        self.assertEqual(browser.frames[1]["fields"]["AP"], "1")
        self.assertEqual(browser.frames[1]["fields"]["MP"], "2")

    def test_joiner_cleanup_preserves_host_and_other_live_players(self):
        host = FakeConn("live-host", 42)
        departed = FakeConn("CJ", -1)
        survivor = FakeConn("other-player", 44)
        add_game(1, host, "live-host")
        add_player(1, host, 1, "live-host", host=True)
        add_player(1, departed, 100, "CJ", pending=True)
        add_player(1, survivor, 101, "other-player", pending=True)

        fesl_server._remove_players_for_conn(departed)

        game = fesl_server.GAMES[1]
        self.assertEqual(
            [player["pid"] for player in game["_players"]],
            ["1", "101"],
        )
        self.assertEqual(list(game["_pending"]), ["101"])
        self.assertIs(game["_conn"], host)
        self.assertIs(game["_host_player"]["conn"], host)

    def test_ecnl_acknowledgment_alone_does_not_delete_hosted_game(self):
        host = FakeConn("live-host", 42)
        add_game(1, host, "live-host")
        add_player(1, host, 1, "live-host", host=True)

        fesl_server.h_theater_ecnl(
            host,
            0x40000000,
            {"TID": "8", "LID": "1", "GID": "1"},
        )

        self.assertIn(1, fesl_server.GAMES)
        self.assertEqual(len(fesl_server.GAMES[1]["_players"]), 1)
        self.assertEqual([frame["domain"] for frame in host.frames], ["ECNL"])


if __name__ == "__main__":
    unittest.main()

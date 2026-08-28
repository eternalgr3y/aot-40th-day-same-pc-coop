#!/usr/bin/env python3
"""Focused, socket-free contract for the Theater ECNL acknowledgment."""

import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools" / "runtime"))

import fesl_server  # noqa: E402


class FakeConn:
    def __init__(self):
        self.frames = []

    def send(self, domain, packet_id, pairs, why=""):
        self.frames.append((domain, packet_id, list(pairs), why))
        return True


class EcnlTransactionTest(unittest.TestCase):
    def test_handler_is_registered_and_echoes_transaction_identity(self):
        self.assertIs(
            fesl_server.HANDLERS[("ECNL", "")],
            fesl_server.h_theater_ecnl,
        )
        conn = FakeConn()
        fesl_server.h_theater_ecnl(
            conn,
            0x40000000,
            {"TID": "17", "LID": "1", "GID": "2"},
        )
        self.assertEqual(len(conn.frames), 1)
        domain, packet_id, pairs, why = conn.frames[0]
        self.assertEqual(domain, "ECNL")
        self.assertEqual(packet_id, fesl_server.THEATER_REPLY_ID)
        self.assertEqual(dict(pairs), {"TID": "17", "LID": "1", "GID": "2"})
        self.assertIn("acknowledged", why)

    def test_missing_fields_use_the_legacy_zero_defaults(self):
        conn = FakeConn()
        fesl_server.h_theater_ecnl(conn, 0x40000000, {})
        self.assertEqual(
            dict(conn.frames[0][2]),
            {"TID": "0", "LID": "0", "GID": "0"},
        )


if __name__ == "__main__":
    unittest.main()

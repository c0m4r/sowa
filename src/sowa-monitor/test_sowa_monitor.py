#!/usr/bin/python3
"""Focused unit and HTTP-contract tests for sowa-monitor."""

from __future__ import annotations

import importlib.machinery
import importlib.util
import json
import os
import socket
import stat
import tempfile
import threading
import unittest
from pathlib import Path


SOURCE = Path(__file__).with_name("sowa-monitor")
loader = importlib.machinery.SourceFileLoader("sowa_monitor", str(SOURCE))
spec = importlib.util.spec_from_loader(loader.name, loader)
assert spec is not None
monitor = importlib.util.module_from_spec(spec)
loader.exec_module(monitor)


class HelpersTest(unittest.TestCase):
    def test_percent_is_bounded(self) -> None:
        self.assertEqual(monitor.percent(50, 100), 50.0)
        self.assertEqual(monitor.percent(200, 100), 100.0)
        self.assertEqual(monitor.percent(1, 0), 0.0)

    def test_mount_escapes_are_decoded(self) -> None:
        self.assertEqual(monitor.decode_mount_path("/media/a\\040b"), "/media/a b")

    def test_stale_socket_refuses_regular_file(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "socket"
            path.write_text("do not replace", encoding="utf-8")
            with self.assertRaises(RuntimeError):
                monitor.remove_stale_socket(str(path))
            self.assertEqual(path.read_text(encoding="utf-8"), "do not replace")

    def test_live_snapshot_has_bounded_public_shape(self) -> None:
        payload = monitor.Collector(minimum_interval=0).snapshot()
        self.assertEqual(payload["api_version"], "1")
        self.assertIn(payload["health"], {"healthy", "attention", "critical"})
        self.assertIn("used_percent", payload["cpu"])
        self.assertIn("used_percent", payload["memory"])
        self.assertLessEqual(len(payload["filesystems"]), monitor.MAX_FILESYSTEMS)
        self.assertLessEqual(len(payload["processes"]["top_memory"]), monitor.MAX_PROCESSES)

    def test_expected_full_read_only_volume_is_not_a_health_alarm(self) -> None:
        writable = {"used_percent": 10.0, "read_only": False}
        immutable = {"used_percent": 100.0, "read_only": True}
        self.assertEqual(monitor.writable_capacity_peak([writable, immutable]), 10.0)


class FakeCollector:
    def snapshot(self) -> dict[str, object]:
        return {"api_version": "1", "health": "healthy"}


class HttpContractTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        root = Path(self.temporary.name)
        for filename in ("index.html", "dashboard.css", "dashboard.js"):
            (root / filename).write_text(filename, encoding="utf-8")
        self.socket_path = str(root / "monitor.sock")
        self.server = monitor.BoundedThreadingUnixServer(self.socket_path, monitor.DashboardHandler, FakeCollector(), str(root))
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)
        self.temporary.cleanup()

    def request(self, method: str, path: str) -> tuple[int, dict[str, str], bytes]:
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        client.settimeout(2)
        client.connect(self.socket_path)
        client.sendall(f"{method} {path} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n".encode())
        chunks = []
        while True:
            chunk = client.recv(65536)
            if not chunk:
                break
            chunks.append(chunk)
        client.close()
        head, _, body = b"".join(chunks).partition(b"\r\n\r\n")
        lines = head.decode("iso-8859-1").split("\r\n")
        status = int(lines[0].split()[1])
        headers = {key.lower(): value.strip() for line in lines[1:] for key, separator, value in [line.partition(":")] if separator}
        return status, headers, body

    def test_api_and_security_headers(self) -> None:
        status, headers, body = self.request("GET", "/api/v1/summary")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)["api_version"], "1")
        self.assertEqual(headers["x-content-type-options"], "nosniff")
        self.assertEqual(headers["cross-origin-opener-policy"], "same-origin")
        self.assertIn("frame-ancestors 'none'", headers["content-security-policy"])
        self.assertEqual(headers["cache-control"], "no-store")

    def test_mutating_methods_are_rejected(self) -> None:
        status, headers, _body = self.request("POST", "/api/v1/summary")
        self.assertEqual(status, 405)
        self.assertEqual(headers["allow"], "GET, HEAD")

    def test_arbitrary_paths_are_not_served(self) -> None:
        status, _headers, _body = self.request("GET", "/../../etc/shadow")
        self.assertEqual(status, 404)

    def test_socket_starts_restrictive(self) -> None:
        mode = stat.S_IMODE(os.stat(self.socket_path).st_mode)
        self.assertEqual(mode, 0o600)


if __name__ == "__main__":
    unittest.main()

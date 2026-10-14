"""Unit tests for mcp/health_server.py — Qdrant-based ingestion status probe."""
import sys
import unittest
from pathlib import Path
from unittest.mock import patch, MagicMock
from io import BytesIO
import json

# Make mcp/ importable
REPO_ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(REPO_ROOT / "mcp"))

import health_server  # noqa: E402


def _mock_response(payload: dict, status: int = 200):
    """Create a context-manager-compatible mock for urllib.request.urlopen."""
    body = BytesIO(json.dumps(payload).encode("utf-8"))
    resp = MagicMock()
    resp.status = status
    resp.read = body.read
    resp.__enter__ = MagicMock(return_value=resp)
    resp.__exit__ = MagicMock(return_value=False)
    return resp


class TestCheckIngestionStatus(unittest.TestCase):
    """_check_ingestion_status() returns 'complete' | 'pending' | 'unknown'."""

    @patch("health_server.urllib.request.urlopen")
    def test_complete_when_any_collection_has_points(self, mock_urlopen):
        def side_effect(req, *args, **kwargs):
            url = req.full_url if hasattr(req, "full_url") else str(req)
            if url.endswith("/collections"):
                return _mock_response({"result": {"collections": [{"name": "code_rust"}, {"name": "code_typescript"}]}})
            if url.endswith("/collections/code_rust"):
                return _mock_response({"result": {"points_count": 1234}})
            if url.endswith("/collections/code_typescript"):
                return _mock_response({"result": {"points_count": 0}})
            raise AssertionError(f"unexpected URL: {url}")
        mock_urlopen.side_effect = side_effect
        self.assertEqual(health_server._check_ingestion_status(), "complete")

    @patch("health_server.urllib.request.urlopen")
    def test_pending_when_all_collections_empty(self, mock_urlopen):
        def side_effect(req, *args, **kwargs):
            url = req.full_url if hasattr(req, "full_url") else str(req)
            if url.endswith("/collections"):
                return _mock_response({"result": {"collections": [{"name": "code_rust"}]}})
            if url.endswith("/collections/code_rust"):
                return _mock_response({"result": {"points_count": 0}})
            raise AssertionError(f"unexpected URL: {url}")
        mock_urlopen.side_effect = side_effect
        self.assertEqual(health_server._check_ingestion_status(), "pending")

    @patch("health_server.urllib.request.urlopen")
    def test_pending_when_no_collections(self, mock_urlopen):
        mock_urlopen.return_value = _mock_response({"result": {"collections": []}})
        self.assertEqual(health_server._check_ingestion_status(), "pending")

    @patch("health_server.urllib.request.urlopen")
    def test_unknown_when_qdrant_unreachable(self, mock_urlopen):
        mock_urlopen.side_effect = ConnectionError("connection refused")
        self.assertEqual(health_server._check_ingestion_status(), "unknown")


class TestGetHealthStatus(unittest.TestCase):
    """get_health_status() composes _check_qdrant + _check_ingestion_status."""

    @patch("health_server._check_qdrant", return_value=True)
    @patch("health_server._check_ingestion_status", return_value="complete")
    def test_ready_when_qdrant_ok_and_complete(self, _ing, _q):
        body, code = health_server.get_health_status()
        self.assertEqual(code, 200)
        self.assertEqual(body["status"], "ready")
        self.assertEqual(body["qdrant"], "ok")
        self.assertEqual(body["ingestion"], "complete")
        self.assertEqual(body["backend_type"], "qdrant")

    @patch("health_server._check_qdrant", return_value=True)
    @patch("health_server._check_ingestion_status", return_value="pending")
    def test_waiting_when_qdrant_ok_and_pending(self, _ing, _q):
        body, code = health_server.get_health_status()
        self.assertEqual(code, 503)
        self.assertEqual(body["status"], "waiting_for_ingestion")
        self.assertEqual(body["ingestion"], "pending")

    @patch("health_server._check_qdrant", return_value=True)
    @patch("health_server._check_ingestion_status", return_value="unknown")
    def test_unknown_ingestion_with_qdrant_ok(self, _ing, _q):
        body, code = health_server.get_health_status()
        self.assertEqual(code, 503)
        self.assertEqual(body["ingestion"], "unknown")

    @patch("health_server._check_qdrant", return_value=False)
    @patch("health_server._check_ingestion_status", return_value="unknown")
    def test_unhealthy_when_qdrant_down(self, _ing, _q):
        body, code = health_server.get_health_status()
        self.assertEqual(code, 503)
        self.assertEqual(body["status"], "unhealthy")
        self.assertEqual(body["qdrant"], "unavailable")


if __name__ == "__main__":
    unittest.main()

"""
Health HTTP endpoint for MCP server.

Provides a simple HTTP health check endpoint that can be polled to verify:
1. Qdrant is accessible
2. Whether ingestion has produced data in any collection
"""

import os
import json
import logging
import urllib.request
from http.server import HTTPServer, BaseHTTPRequestHandler
from threading import Thread
from typing import Any, Dict, Tuple

logger = logging.getLogger(__name__)


def get_health_status() -> Tuple[Dict[str, Any], int]:
    """
    Compute health status (reusable for HTTP handler or FastMCP custom route).

    Returns:
        Tuple of (response_dict, http_status_code).
    """
    qdrant_ok = _check_qdrant()
    ingestion = _check_ingestion_status() if qdrant_ok else "unknown"

    if qdrant_ok and ingestion == "complete":
        status_code = 200
        status = "ready"
    elif qdrant_ok and ingestion == "pending":
        status_code = 503
        status = "waiting_for_ingestion"
    elif qdrant_ok:
        # ingestion == "unknown" but Qdrant itself is reachable
        status_code = 503
        status = "waiting_for_ingestion"
    else:
        status_code = 503
        status = "unhealthy"

    response = {
        "status": status,
        "qdrant": "ok" if qdrant_ok else "unavailable",
        "backend_type": "qdrant",
        "ingestion": ingestion,
    }
    return response, status_code


def _qdrant_url() -> str:
    return os.getenv("QDRANT_URL", "http://qdrant:6333").rstrip("/")


def _qdrant_request(path: str, timeout: float = 2.0) -> Dict[str, Any]:
    """GET a Qdrant API path and return the parsed JSON body. Raises on failure."""
    url = f"{_qdrant_url()}{path}"
    req = urllib.request.Request(url)
    api_key = os.getenv("QDRANT_API_KEY", "")
    if api_key:
        req.add_header("api-key", api_key)
    with urllib.request.urlopen(req, timeout=timeout) as response:
        return json.loads(response.read().decode("utf-8"))


def _check_qdrant() -> bool:
    """Check if Qdrant is accessible (root endpoint returns version info)."""
    try:
        req = urllib.request.Request(f"{_qdrant_url()}/")
        api_key = os.getenv("QDRANT_API_KEY", "")
        if api_key:
            req.add_header("api-key", api_key)
        with urllib.request.urlopen(req, timeout=2) as response:
            return response.status == 200
    except Exception:
        return False


def _check_ingestion_status() -> str:
    """
    Probe Qdrant for ingestion progress.

    Returns:
        "complete" if any collection has points_count > 0
        "pending"  if Qdrant is reachable but all collections are empty (or none exist)
        "unknown"  if any Qdrant API call raised
    """
    try:
        body = _qdrant_request("/collections")
        collections = body.get("result", {}).get("collections", []) or []
        if not collections:
            return "pending"
        for entry in collections:
            name = entry.get("name") if isinstance(entry, dict) else None
            if not name:
                continue
            try:
                detail = _qdrant_request(f"/collections/{name}")
                points = detail.get("result", {}).get("points_count") or 0
                if points > 0:
                    return "complete"
            except Exception:
                # One collection probe failed — treat the whole check as unknown
                return "unknown"
        return "pending"
    except Exception:
        return "unknown"


class HealthHandler(BaseHTTPRequestHandler):
    """HTTP handler for health endpoint."""

    def log_message(self, format, *args):
        """Suppress default HTTP logging (use our logger instead)."""
        pass

    def do_GET(self):
        """Handle GET request to /health."""
        if self.path != "/health":
            self.send_response(404)
            self.end_headers()
            self.wfile.write(b"Not Found")
            return
        response, status_code = get_health_status()
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(response).encode("utf-8"))


def start_health_server(port: int = 8001, host: str = "0.0.0.0"):
    """
    Start health check HTTP server in background thread.

    Args:
        port: Port to listen on (default: 8001)
        host: Host to bind to (default: 0.0.0.0)
    """
    server = HTTPServer((host, port), HealthHandler)

    def run_server():
        logger.info(f"🏥 Health server listening on {host}:{port}")
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            logger.info("🛑 Health server shutting down")
            server.shutdown()

    thread = Thread(target=run_server, daemon=True)
    thread.start()

    return server


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)
    server = start_health_server()
    try:
        import time
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        logger.info("Shutting down...")
        server.shutdown()

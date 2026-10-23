"""Start a temporary FastAPI server and verify it against real Plaid Sandbox.

Only PLAID_CLIENT_ID and PLAID_SECRET are needed. The app key is generated for
this process, never printed, and discarded when the server stops.
"""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import secrets
import socket
import subprocess
import sys
import time

from dotenv import load_dotenv
import httpx


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--product", choices=["transactions", "liabilities", "investments"], default="transactions")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--wait-seconds", type=float, default=180)
    args = parser.parse_args(argv)
    if not 1 <= args.port <= 65535 or not 0 <= args.wait_seconds <= 600:
        parser.error("Use a valid port and a wait-seconds value between 0 and 600")
    root = Path(__file__).resolve().parent
    load_dotenv(root / ".env")
    missing = [name for name in ("PLAID_CLIENT_ID", "PLAID_SECRET") if not os.getenv(name, "").strip()]
    if missing:
        raise SystemExit("Add these environment variables or repository Actions secrets: " + ", ".join(missing))
    if os.getenv("PLAID_ENV", "sandbox") != "sandbox":
        raise SystemExit("This verifier accepts PLAID_ENV=sandbox only")
    # Check the port before starting; never attach to or stop an existing server.
    try:
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", args.port))
    except OSError:
        raise SystemExit("The local test port is unavailable; choose another with --port") from None
    child_env = {**os.environ, "PLAID_ENV": "sandbox", "ALLOW_PRODUCTION": "false", "ENABLE_SANDBOX_TOOLS": "true", "APP_KEY": secrets.token_urlsafe(32)}
    process = subprocess.Popen([sys.executable, "-m", "uvicorn", "app:app", "--host", "127.0.0.1", "--port", str(args.port), "--no-access-log", "--no-proxy-headers", "--log-level", "warning"], cwd=root, env=child_env)
    url = f"http://127.0.0.1:{args.port}"
    try:
        with httpx.Client(base_url=url, timeout=2, trust_env=False) as client:
            deadline = time.monotonic() + 30
            while True:
                if process.poll() is not None:
                    raise SystemExit("FastAPI stopped before becoming ready; inspect the server error above")
                try:
                    health = client.get("/health").json()
                    if health.get("environment") == "sandbox" and health.get("configured") is True:
                        break
                except (httpx.HTTPError, ValueError):
                    pass
                if time.monotonic() >= deadline:
                    raise SystemExit("FastAPI did not become ready within 30 seconds")
                time.sleep(0.2)
        print("PASS: temporary FastAPI server is ready in Sandbox mode", flush=True)
        result = subprocess.run([sys.executable, str(root / "sandbox_smoke.py"), "--url", url, "--product", args.product, "--wait-seconds", str(args.wait_seconds)], env=child_env, timeout=args.wait_seconds + 240)
        raise SystemExit(result.returncode)
    except subprocess.TimeoutExpired:
        raise SystemExit("Sandbox verification timed out; no live result was accepted") from None
    finally:
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


if __name__ == "__main__":
    main()

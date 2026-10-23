"""Optional live Sandbox check. Never prints or persists Plaid/app tokens.

Start the local proxy first, then: .venv/bin/python sandbox_smoke.py
Creates one disposable Sandbox Item. Does not link production bank accounts.
"""
from __future__ import annotations
import argparse
import os
import sys
import time
import uuid
from urllib.parse import urlparse

from dotenv import load_dotenv
import httpx

load_dotenv()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", default="http://127.0.0.1:8000")
    parser.add_argument("--product", choices=["transactions", "liabilities", "investments"], default="transactions")
    parser.add_argument("--reset-login", action="store_true", help="Also simulate a broken login and create an update-mode link token")
    args = parser.parse_args()
    parsed = urlparse(args.url)
    if parsed.scheme != "https" and not (parsed.scheme == "http" and parsed.hostname in {"localhost", "127.0.0.1", "::1"}):
        raise SystemExit("Use HTTPS or local loopback HTTP.")
    key = os.getenv("APP_KEY", "")
    if not key:
        raise SystemExit("Set APP_KEY in proxy/.env. Tokens and keys will not be printed.")
    with httpx.Client(base_url=args.url, headers={"X-App-Key": key}, timeout=65, follow_redirects=False) as client:
        health = client.get("/health").json()
        if not (health.get("environment") == "sandbox" and health.get("configured") and health.get("sandbox_tools")):
            raise SystemExit("A configured Sandbox proxy with ENABLE_SANDBOX_TOOLS=true is required.")

        def post(path, body):
            response = client.post(path, json=body)
            if response.status_code != 200:
                # Do not echo an arbitrary server response or a token-bearing request.
                try:
                    code = response.json().get("error_code", "UNKNOWN_ERROR")
                except ValueError:
                    code = "INVALID_RESPONSE"
                raise SystemExit(f"{path}: HTTP {response.status_code}, {code}")
            return response.json()

        post("/session/check", {})
        user_id = str(uuid.uuid4())
        link = post("/link/token", {"client_user_id": user_id, "product": args.product})
        assert link.get("link_token"), "Missing link token"
        seed = post("/sandbox/item/create", {"product": args.product, "dynamic": True})
        item = post("/item/exchange", {"public_token": seed["public_token"]})
        access = {"access_token": item["access_token"]}
        accounts = post("/accounts", access)["accounts"]
        print(f"PASS: link token, token exchange, {len(accounts)} accounts ({args.product})")
        if args.product == "transactions":
            cursor = None
            ids = set()
            for attempt in range(6):
                new_ids = set(ids)
                while True:
                    page = post("/transactions/sync", {**access, **({"cursor": cursor} if cursor else {})})
                    new_ids.update(x["transaction_id"] for x in page["added"])
                    cursor = page["next_cursor"]
                    if not page["has_more"]:
                        break
                ids = new_ids
                if ids:
                    break
                if attempt < 5:
                    time.sleep(5)
            if not ids:
                raise SystemExit("History is still preparing. Rerun later or use pull-to-refresh in the app; no live history assertion passed.")
            replay = post("/transactions/sync", {**access, "cursor": cursor})
            assert not replay["has_more"], "Unexpected extra page; pull another page before committing"
            print(f"PASS: initial transaction history ({len(ids)} unique IDs), incremental sync")
        elif args.product == "liabilities":
            response = post("/liabilities", access)
            print(f"PASS: {len(response['student'])} student liabilities, {len(response['credit'])} card liabilities")
        else:
            response = post("/investments", access)
            print(f"PASS: {len(response['holdings'])} holdings, {len(response['securities'])} securities")
        if args.reset_login:
            post("/sandbox/item/reset-login", access)
            update = post("/link/token", {**access, "client_user_id": user_id, "product": args.product})
            assert update.get("link_token")
            print("PASS: reset login and update-mode token (finish re-authentication in the simulator)")
        print("No credentials were printed or persisted. The test Item remains in Sandbox.")


if __name__ == "__main__":
    main()

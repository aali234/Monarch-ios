"""Live Sandbox check through the proxy. Tokens stay in memory and are never printed.

Creates one test Item, which remains in Plaid Sandbox after the check.
"""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import re
import time
import uuid
from urllib.parse import urlparse

from dotenv import load_dotenv
import httpx

load_dotenv(Path(__file__).with_name(".env"))


class CheckFailure(Exception):
    def __init__(self, message: str, code: str = "CHECK_FAILED"):
        super().__init__(message)
        self.code = code


def require(condition, message: str):
    if not condition:
        raise CheckFailure(message)


def post(client: httpx.Client, path: str, body: dict) -> dict:
    response = client.post(path, json=body)
    try:
        data = response.json()
    except ValueError:
        raise CheckFailure(f"{path}: invalid JSON response") from None
    require(isinstance(data, dict), f"{path}: expected a JSON object")
    if response.status_code != 200:
        code = data.get("error_code", "UNKNOWN_ERROR")
        # Never print an arbitrary response field: it could contain a token.
        if not isinstance(code, str) or not re.fullmatch(r"[A-Z0-9_]{1,100}", code):
            code = "UNKNOWN_ERROR"
        raise CheckFailure(f"{path}: HTTP {response.status_code}, {code}", code)
    return data


def sync_batch(client: httpx.Client, access: dict, cursor: str | None):
    """Only return a cursor after all pages succeed; discard a mutated batch."""
    for attempt in range(3):
        next_cursor, added, removed = cursor, set(), set()
        for _ in range(100):
            try:
                page = post(client, "/transactions/sync", {**access, **({"cursor": next_cursor} if next_cursor else {})})
            except CheckFailure as error:
                if error.code == "TRANSACTIONS_SYNC_MUTATION_DURING_PAGINATION" and attempt < 2:
                    break
                raise
            require(all(isinstance(page.get(key), list) for key in ("added", "modified", "removed")), "Sync response is missing its change lists")
            require(isinstance(page.get("next_cursor"), str), "Sync response is missing its cursor")
            require(isinstance(page.get("has_more"), bool), "Sync response is missing has_more")
            if not page["next_cursor"]:
                # Plaid's first response can have an empty cursor while history
                # is being prepared. Keep the original cursor and poll later.
                require(not next_cursor and not any(page[field] for field in ("added", "modified", "removed")) and not page["has_more"], "Sync returned an invalid empty cursor")
                raise CheckFailure("Sandbox transaction history is still preparing", "PRODUCT_NOT_READY")
            for field, target in (("added", added), ("removed", removed)):
                for row in page[field]:
                    require(isinstance(row, dict) and isinstance(row.get("transaction_id"), str) and row["transaction_id"], "Sync returned an invalid transaction ID")
                    if field == "added":
                        require(row["transaction_id"] not in target, "Sync returned a duplicate added transaction ID")
                    target.add(row["transaction_id"])
            if not page["has_more"]:
                return page["next_cursor"], added, removed
            require(page["next_cursor"] != next_cursor, "Sync pagination did not advance")
            next_cursor = page["next_cursor"]
        else:
            raise CheckFailure("Sync exceeded the page limit")
    raise CheckFailure("Sync kept changing during pagination; retry later")


def verify(client: httpx.Client, product: str, reset_login: bool = False, wait_seconds: float = 180):
    health = client.get("/health").json()
    require(isinstance(health, dict) and health.get("environment") == "sandbox" and health.get("configured") is True and health.get("sandbox_tools") is True,
            "A configured Sandbox proxy with ENABLE_SANDBOX_TOOLS=true is required")
    post(client, "/session/check", {})
    user_id = str(uuid.uuid4())
    link = post(client, "/link/token", {"client_user_id": user_id, "product": product})
    require(bool(link.get("link_token")), "Missing Link token")
    seed = post(client, "/sandbox/item/create", {"product": product, "dynamic": True})
    require(bool(seed.get("public_token")), "Missing Sandbox public token")
    item = post(client, "/item/exchange", {"public_token": seed["public_token"]})
    require(isinstance(item.get("access_token"), str) and item["access_token"].startswith("access-sandbox-"), "Missing Sandbox access token")
    access = {"access_token": item["access_token"]}
    accounts = post(client, "/accounts", access).get("accounts")
    require(isinstance(accounts, list) and len(accounts) > 0, "Plaid did not return any Sandbox accounts")
    print(f"PASS: Link token, token exchange, {len(accounts)} Sandbox accounts ({product})", flush=True)

    if product == "transactions":
        cursor, ids = None, set()
        deadline = time.monotonic() + wait_seconds
        while True:
            try:
                cursor, added, removed = sync_batch(client, access, cursor)
                ids = (ids | added) - removed
            except CheckFailure as error:
                if error.code != "PRODUCT_NOT_READY":
                    raise
            if ids:
                break
            remaining = deadline - time.monotonic()
            require(remaining > 0, "Sandbox history is still preparing; rerun later. No transaction-history assertion passed")
            time.sleep(min(5, remaining))
        # A dynamic Sandbox Item may have new changes here. Drain every page.
        sync_batch(client, access, cursor)
        print(f"PASS: transaction history ({len(ids)} unique IDs) and incremental cursor sync", flush=True)
    elif product == "liabilities":
        data = post(client, "/liabilities", access)
        student, credit = data.get("student"), data.get("credit")
        require(isinstance(student, list) and isinstance(credit, list) and bool(student or credit), "Plaid did not return any Sandbox liabilities")
        print(f"PASS: {len(student)} student liabilities, {len(credit)} card liabilities", flush=True)
    else:
        data = post(client, "/investments", access)
        holdings, securities = data.get("holdings"), data.get("securities")
        require(isinstance(holdings, list) and isinstance(securities, list) and bool(holdings) and bool(securities), "Plaid did not return Sandbox holdings and securities")
        print(f"PASS: {len(holdings)} holdings, {len(securities)} securities", flush=True)
    if reset_login:
        post(client, "/sandbox/item/reset-login", access)
        update = post(client, "/link/token", {**access, "client_user_id": user_id, "product": product})
        require(bool(update.get("link_token")), "Missing update-mode Link token")
        print("PASS: reset login and update-mode token; finish re-authentication in the simulator", flush=True)
    print("No credentials or financial rows were printed or persisted locally. The test Item remains in Sandbox.", flush=True)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", default="http://127.0.0.1:8000")
    parser.add_argument("--product", choices=["transactions", "liabilities", "investments"], default="transactions")
    parser.add_argument("--reset-login", action="store_true")
    parser.add_argument("--wait-seconds", type=float, default=180)
    args = parser.parse_args(argv)
    parsed = urlparse(args.url)
    local = parsed.hostname in {"localhost", "127.0.0.1", "::1"}
    if not parsed.hostname or parsed.username or parsed.password or parsed.query or parsed.fragment or parsed.path not in {"", "/"}:
        parser.error("Use the proxy's root URL without credentials, query parameters or fragments")
    if parsed.scheme != "https" and not (parsed.scheme == "http" and local):
        parser.error("Use HTTPS or local loopback HTTP")
    if not 0 <= args.wait_seconds <= 600:
        parser.error("wait-seconds must be between 0 and 600")
    key = os.getenv("APP_KEY", "")
    if len(key) < 32:
        raise SystemExit("Set APP_KEY (at least 32 characters) in the environment or proxy/.env. Its value is not printed.")
    try:
        # Loopback stays on this machine. Hosted HTTPS retains proxy/CA settings.
        with httpx.Client(base_url=args.url, headers={"X-App-Key": key}, timeout=75, trust_env=not (local and parsed.scheme == "http"), follow_redirects=False) as client:
            verify(client, args.product, args.reset_login, args.wait_seconds)
    except CheckFailure as error:
        raise SystemExit(str(error)) from None
    except (httpx.HTTPError, ValueError):
        raise SystemExit("Could not read a valid response from the proxy. Check its URL and /health endpoint; wake a sleeping Render service first.") from None


if __name__ == "__main__":
    main()

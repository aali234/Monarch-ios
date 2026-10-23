import json
import logging
import pytest
import httpx
from fastapi.testclient import TestClient

from app import Settings, create_app


KEY = "test-app-key-which-is-at-least-32-characters"
TOKEN = "access-sandbox-test-token"


def make_client(handler, **overrides):
    settings = Settings(client_id="test-client", secret="test-secret", app_key=KEY, **overrides)
    return TestClient(create_app(settings, httpx.MockTransport(handler)))


def ok_handler(request):
    return httpx.Response(200, json={"accounts": [], "request_id": "not-forwarded"})


def test_health_without_credentials_and_authentication():
    with TestClient(create_app(Settings())) as client:
        assert client.get("/health").json() == {"ok": True, "environment": "sandbox", "configured": False, "sandbox_tools": False, "tracking_configured": False}
        assert client.post("/accounts", json={"access_token": TOKEN}).status_code == 401
    with make_client(ok_handler) as client:
        assert client.post("/accounts", headers={"X-App-Key": "wrong"}, json={"access_token": TOKEN}).status_code == 401
        assert client.post("/session/check", headers={"X-App-Key": KEY}, json={}).json() == {"ok": True}


def test_exchange_trims_response_and_authenticates_upstream():
    def handler(request):
        assert request.url.host == "sandbox.plaid.com"
        assert request.url.path == "/item/public_token/exchange"
        payload = json.loads(request.content)
        assert payload["client_id"] == "test-client" and payload["secret"] == "test-secret"
        assert payload["public_token"] == "public-sandbox-test"
        return httpx.Response(200, json={"access_token": TOKEN, "item_id": "item", "request_id": "private"})
    with make_client(handler) as client:
        result = client.post("/item/exchange", headers={"X-App-Key": KEY}, json={"public_token": "public-sandbox-test"})
        assert result.json() == {"access_token": TOKEN, "item_id": "item"}
        assert result.headers["cache-control"] == "no-store"


@pytest.mark.parametrize("update", [False, True])
def test_link_and_update_mode_never_create_new_item(update):
    def handler(request):
        assert request.url.path == "/link/token/create"
        payload = json.loads(request.content)
        if update:
            assert payload["access_token"] == TOKEN
            assert "products" not in payload
        else:
            assert payload["products"] == ["transactions"]
            assert "access_token" not in payload
        return httpx.Response(200, json={"link_token": "link-sandbox-test", "expiration": "2026-10-23T00:00:00Z"})
    body = {"client_user_id": "local-user", "product": "transactions"}
    if update:
        body["access_token"] = TOKEN
    with make_client(handler) as client:
        assert client.post("/link/token", headers={"X-App-Key": KEY}, json=body).status_code == 200


def test_sync_forwards_cursor_and_trims_financial_fields():
    def handler(request):
        payload = json.loads(request.content)
        assert payload["cursor"] == "saved-cursor"
        return httpx.Response(200, json={
            "added": [{"transaction_id": "one", "amount": 1.23, "account_id": "bank", "location": {"address": "do not forward"}}],
            "modified": [], "removed": [{"transaction_id": "old", "account_id": "bank"}],
            "next_cursor": "next", "has_more": False, "transactions_update_status": "HISTORICAL_UPDATE_COMPLETE", "request_id": "private"
        })
    with make_client(handler) as client:
        result = client.post("/transactions/sync", headers={"X-App-Key": KEY}, json={"access_token": TOKEN, "cursor": "saved-cursor"})
        assert result.status_code == 200
        assert "location" not in result.json()["added"][0]
        assert result.json()["removed"] == [{"transaction_id": "old"}]
        assert result.json()["next_cursor"] == "next"


def test_errors_do_not_echo_tokens_secret_or_upstream_messages(caplog):
    def handler(request):
        return httpx.Response(400, json={"error_code": "ITEM_LOGIN_REQUIRED", "error_message": "secret=do-not-copy", "display_message": TOKEN})
    with make_client(handler) as client, caplog.at_level(logging.INFO, logger="monarch.proxy"):
        result = client.post("/accounts?secret=do-not-log", headers={"X-App-Key": KEY}, json={"access_token": TOKEN})
        assert result.status_code == 502
        assert result.json()["error_code"] == "ITEM_LOGIN_REQUIRED"
        invalid = client.post("/accounts", headers={"X-App-Key": KEY}, json={"access_token": TOKEN, "unexpected": "sensitive"})
        assert invalid.status_code == 422
        output = result.text + invalid.text + " ".join(r.getMessage() for r in caplog.records if r.name == "monarch.proxy")
        for sensitive in [TOKEN, "do-not-copy", "do-not-log", "sensitive", KEY, "test-secret"]:
            assert sensitive not in output


def test_rate_limit_and_wrong_environment():
    with make_client(ok_handler, rate_limit=1) as client:
        headers = {"X-App-Key": KEY}
        assert client.post("/accounts", headers=headers, json={"access_token": TOKEN}).status_code == 200
        assert client.post("/accounts", headers=headers, json={"access_token": TOKEN}).status_code == 429
    with make_client(ok_handler) as client:
        result = client.post("/accounts", headers={"X-App-Key": KEY}, json={"access_token": "access-production-example"})
        assert result.status_code == 400
        assert result.json()["error_code"] == "TOKEN_ENVIRONMENT_MISMATCH"


def test_sandbox_controls_are_gated_and_no_remove_endpoint():
    with make_client(ok_handler) as client:
        assert client.post("/sandbox/item/create", headers={"X-App-Key": KEY}, json={}).status_code == 403
        assert client.post("/item/remove", headers={"X-App-Key": KEY}, json={}).status_code == 404
    with pytest.raises(ValueError):
        create_app(Settings(environment="production"))
    with pytest.raises(ValueError):
        create_app(Settings(environment="production", allow_production=True, sandbox_tools=True))


def test_sandbox_seed_refresh_and_reset_routes():
    paths = []
    def handler(request):
        paths.append(request.url.path)
        if request.url.path == "/sandbox/public_token/create":
            payload = json.loads(request.content)
            assert payload["institution_id"] == "ins_109508"
            assert payload["options"]["override_username"] == "user_transactions_dynamic"
            return httpx.Response(200, json={"public_token": "public-sandbox-test"})
        return httpx.Response(200, json={})
    with make_client(handler, sandbox_tools=True) as client:
        headers = {"X-App-Key": KEY}
        assert client.post("/sandbox/item/create", headers=headers, json={}).json()["public_token"] == "public-sandbox-test"
        assert client.post("/sandbox/transactions/refresh", headers=headers, json={"access_token": TOKEN}).json() == {"ok": True}
        assert client.post("/sandbox/item/reset-login", headers=headers, json={"access_token": TOKEN}).json() == {"ok": True}
    assert paths == ["/sandbox/public_token/create", "/transactions/refresh", "/sandbox/item/reset_login"]


def test_large_payload_and_unexpected_upstream_output():
    with make_client(lambda request: httpx.Response(200, text="not json")) as client:
        assert client.post("/accounts", headers={"X-App-Key": KEY}, json={"access_token": TOKEN}).json()["error_code"] == "INVALID_UPSTREAM_RESPONSE"
        assert client.post("/accounts", headers={"X-App-Key": KEY}, content="x" * 20000).status_code == 413
        def chunked():
            yield b"x" * 9000
            yield b"x" * 9000
        assert client.post("/accounts", headers={"X-App-Key": KEY}, content=chunked()).status_code == 413


def test_investment_and_liability_response_shapes():
    def handler(request):
        if request.url.path == "/liabilities/get":
            return httpx.Response(200, json={"liabilities": {"student": [{"account_id": "loan", "interest_rate_percentage": 6, "account_number": "secret"}], "credit": []}})
        return httpx.Response(200, json={"holdings": [{"account_id": "investment", "security_id": "sec", "quantity": 2, "institution_price": 10}], "securities": [{"security_id": "sec", "ticker_symbol": "TEST", "name": "Test fund", "close_price": 10, "cusip": "do-not-forward"}]})
    with make_client(handler) as client:
        headers = {"X-App-Key": KEY}
        assert "account_number" not in client.post("/liabilities", headers=headers, json={"access_token": TOKEN}).json()["student"][0]
        assert "cusip" not in client.post("/investments", headers=headers, json={"access_token": TOKEN}).json()["securities"][0]

import json

import httpx
import pytest

from sandbox_smoke import CheckFailure, post, sync_batch, verify
import verify_sandbox


TOKEN = "access-sandbox-private-test-token"


def page(cursor, *ids, more=False):
    return {"added": [{"transaction_id": value} for value in ids], "modified": [], "removed": [], "next_cursor": cursor, "has_more": more}


def test_sync_restarts_mutated_pages_from_original_cursor():
    cursors = []
    responses = [
        (200, page("partial", "discard-this-row", more=True)),
        (502, {"error_code": "TRANSACTIONS_SYNC_MUTATION_DURING_PAGINATION"}),
        (200, page("committed", "keep-this-row")),
    ]

    def handler(request):
        cursors.append(json.loads(request.content)["cursor"])
        status, data = responses.pop(0)
        return httpx.Response(status, json=data)

    with httpx.Client(base_url="https://proxy.example", transport=httpx.MockTransport(handler)) as client:
        cursor, added, removed = sync_batch(client, {"access_token": TOKEN}, "original")
    assert cursors == ["original", "partial", "original"]
    assert (cursor, added, removed) == ("committed", {"keep-this-row"}, set())


def test_sync_rejects_duplicate_added_ids_across_pages():
    responses = [page("first", "duplicate", more=True), page("last", "duplicate")]
    with httpx.Client(base_url="https://proxy.example", transport=httpx.MockTransport(lambda request: httpx.Response(200, json=responses.pop(0)))) as client:
        with pytest.raises(CheckFailure, match="duplicate"):
            sync_batch(client, {"access_token": TOKEN}, None)


def fake_proxy(sync_pages=(), accounts=None, liabilities=None, investments=None):
    pending = list(sync_pages)
    requests = []

    def handler(request):
        path = request.url.path
        body = json.loads(request.content) if request.content else {}
        requests.append((path, body))
        data = {
            "/health": {"environment": "sandbox", "configured": True, "sandbox_tools": True},
            "/session/check": {"ok": True},
            "/link/token": {"link_token": "link-sandbox-private-test"},
            "/sandbox/item/create": {"public_token": "public-sandbox-private-test"},
            "/item/exchange": {"access_token": TOKEN},
            "/accounts": {"accounts": [{"account_id": "test-bank"}] if accounts is None else accounts},
            "/liabilities": liabilities or {"student": [], "credit": []},
            "/investments": investments or {"holdings": [], "securities": []},
        }
        if path == "/transactions/sync":
            return httpx.Response(200, json=pending.pop(0))
        return httpx.Response(200, json=data[path])

    return httpx.Client(base_url="https://proxy.example", transport=httpx.MockTransport(handler)), requests


def test_incremental_check_drains_pages_and_does_not_print_tokens_or_rows(capsys):
    client, requests = fake_proxy([page("initial", "private-transaction-id"), page("incremental-one", "new-one", more=True), page("incremental-two", "new-two")])
    with client:
        verify(client, "transactions", wait_seconds=0)
    cursors = [body.get("cursor") for path, body in requests if path == "/transactions/sync"]
    assert cursors == [None, "initial", "incremental-one"]
    output = capsys.readouterr().out
    assert "PASS: transaction history (1 unique IDs)" in output
    for value in [TOKEN, "link-sandbox-private-test", "public-sandbox-private-test", "private-transaction-id", "new-one", "test-bank"]:
        assert value not in output


def test_unprepared_history_does_not_pass(capsys):
    client, _ = fake_proxy([page("empty")])
    with client, pytest.raises(CheckFailure, match="still preparing"):
        verify(client, "transactions", wait_seconds=0)
    assert "PASS: transaction history" not in capsys.readouterr().out


def test_empty_initial_cursor_waits_for_plaid_history(monkeypatch, capsys):
    monkeypatch.setattr("sandbox_smoke.time.sleep", lambda seconds: None)
    client, requests = fake_proxy([page(""), page("ready", "private-row"), page("current")])
    with client:
        verify(client, "transactions", wait_seconds=1)
    assert [body.get("cursor") for path, body in requests if path == "/transactions/sync"] == [None, None, "ready"]
    assert "PASS: transaction history" in capsys.readouterr().out


def test_empty_cursor_cannot_rewind_an_existing_sync():
    with httpx.Client(base_url="https://proxy.example", transport=httpx.MockTransport(lambda request: httpx.Response(200, json=page("")))) as client:
        with pytest.raises(CheckFailure, match="invalid empty cursor"):
            sync_batch(client, {"access_token": TOKEN}, "saved")


@pytest.mark.parametrize("product,accounts,expected", [
    ("transactions", [], "accounts"),
    ("liabilities", None, "liabilities"),
    ("investments", None, "holdings"),
])
def test_empty_product_data_does_not_pass(product, accounts, expected):
    client, _ = fake_proxy(accounts=accounts)
    with client, pytest.raises(CheckFailure, match=expected):
        verify(client, product, wait_seconds=0)


def test_arbitrary_error_fields_cannot_leak_tokens():
    with httpx.Client(base_url="https://proxy.example", transport=httpx.MockTransport(lambda request: httpx.Response(502, json={"error_code": TOKEN, "error_message": "private-server-secret"}))) as client:
        with pytest.raises(CheckFailure) as error:
            post(client, "/accounts", {"access_token": TOKEN})
    assert str(error.value) == "/accounts: HTTP 502, UNKNOWN_ERROR"


def test_production_health_is_rejected_before_creating_an_item():
    paths = []

    def handler(request):
        paths.append(request.url.path)
        return httpx.Response(200, json={"environment": "production", "configured": True, "sandbox_tools": True})

    with httpx.Client(base_url="https://proxy.example", transport=httpx.MockTransport(handler)) as client:
        with pytest.raises(CheckFailure, match="configured Sandbox"):
            verify(client, "transactions", wait_seconds=0)
    assert paths == ["/health"]


@pytest.mark.parametrize("configured", [False, True])
def test_verifier_rejects_missing_keys_or_production_before_starting_a_server(monkeypatch, configured):
    monkeypatch.setattr(verify_sandbox, "load_dotenv", lambda path: None)
    monkeypatch.setattr(verify_sandbox.subprocess, "Popen", lambda *args, **kwargs: pytest.fail("No server should start"))
    monkeypatch.delenv("PLAID_CLIENT_ID", raising=False)
    monkeypatch.delenv("PLAID_SECRET", raising=False)
    if configured:
        monkeypatch.setenv("PLAID_CLIENT_ID", "test-client")
        monkeypatch.setenv("PLAID_SECRET", "test-secret")
        monkeypatch.setenv("PLAID_ENV", "production")
    with pytest.raises(SystemExit, match="sandbox only" if configured else "PLAID_CLIENT_ID, PLAID_SECRET"):
        verify_sandbox.main([])

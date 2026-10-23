import json
import logging
import httpx
from fastapi.testclient import TestClient
from app import Settings, create_app

KEY = "tracking-app-key-which-is-at-least-32-characters"
NUMBER = "1Z999AA10123456784"


def test_tracking_needs_auth_and_rejects_email_and_financial_fields():
    with TestClient(create_app(Settings(app_key=KEY))) as client:
        assert client.post('/tracking', json={'tracking_number': NUMBER}).status_code == 401
        response = client.post('/tracking', headers={'X-App-Key': KEY}, json={'tracking_number': NUMBER, 'email_body': 'private', 'amount': 100})
        assert response.status_code == 422
        assert 'private' not in response.text


def test_missing_tracking_key_returns_link_only_without_plaid_credentials():
    def handler(request):
        raise AssertionError('No upstream call should be made')
    with TestClient(create_app(Settings(app_key=KEY), httpx.MockTransport(handler))) as client:
        response = client.post('/tracking', headers={'X-App-Key': KEY}, json={'tracking_number': NUMBER})
        assert response.status_code == 200
        assert response.json()['available'] is False
        assert response.json()['status'] is None


def test_tracking_forwards_number_only_and_trims_results(caplog):
    def handler(request):
        assert request.url.host == 'api.ship24.com'
        assert request.url.path == '/public/v1/trackers/track'
        assert json.loads(request.content) == {'trackingNumber': NUMBER}
        assert request.headers['authorization'] == 'Bearer server-only-key'
        assert 'secret' not in json.loads(request.content)
        return httpx.Response(200, json={'data': {'trackings': [{
            'tracker': {'trackingNumber': NUMBER},
            'shipment': {'statusMilestone': 'out_for_delivery', 'delivery': {'estimatedDeliveryDate': '2026-10-23'}},
            'events': [{'eventId': 'one', 'occurrenceDatetime': '2026-10-22T09:30:00Z', 'status': 'Out for delivery', 'location': 'Seattle', 'privateField': 'omit-me'}]
        }]}})
    with TestClient(create_app(Settings(app_key=KEY, ship24_api_key='server-only-key'), httpx.MockTransport(handler))) as client, caplog.at_level(logging.INFO, logger='monarch.proxy'):
        response = client.post('/tracking', headers={'X-App-Key': KEY}, json={'tracking_number': NUMBER})
        assert response.status_code == 200
        data = response.json()
        assert data['available'] is True and data['status'] == 'outForDelivery'
        assert data['eta'] == '2026-10-23'
        assert 'privateField' not in data['events'][0]
        assert 'tracker' not in data
        logs = ' '.join(record.getMessage() for record in caplog.records if record.name == 'monarch.proxy')
        assert NUMBER not in logs and 'server-only-key' not in logs


def test_amazon_is_link_only_and_vendor_failures_do_not_invent_status():
    calls = []
    def handler(request):
        calls.append(request.url.path)
        return httpx.Response(503, json={'secret': 'must-not-forward'})
    with TestClient(create_app(Settings(app_key=KEY, ship24_api_key='key'), httpx.MockTransport(handler))) as client:
        amazon = client.post('/tracking', headers={'X-App-Key': KEY}, json={'tracking_number': 'TBA123456789012'})
        assert amazon.json()['available'] is False and not calls
        response = client.post('/tracking', headers={'X-App-Key': KEY}, json={'tracking_number': NUMBER})
        assert response.json()['status'] is None and response.json()['events'] == []
        assert 'must-not-forward' not in response.text


def test_tracking_timeout_and_malformed_response_fall_back():
    def timeout(request):
        raise httpx.ReadTimeout('private upstream details')
    for handler in [timeout, lambda request: httpx.Response(200, json={'data': None})]:
        with TestClient(create_app(Settings(app_key=KEY, ship24_api_key='key'), httpx.MockTransport(handler))) as client:
            response = client.post('/tracking', headers={'X-App-Key': KEY}, json={'tracking_number': NUMBER})
            assert response.status_code == 200
            assert response.json()['available'] is False
            assert 'private upstream' not in response.text

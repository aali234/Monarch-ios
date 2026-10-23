"""Stateless, allow-listed Plaid proxy. No financial data or tokens are persisted."""
from __future__ import annotations

import asyncio
from collections import defaultdict, deque
from contextlib import asynccontextmanager
from dataclasses import dataclass
import hmac
import logging
import os
import re
import time
from typing import Literal
from urllib.parse import urlparse

from dotenv import load_dotenv
from fastapi import Depends, FastAPI, Header, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
import httpx
from pydantic import BaseModel, ConfigDict, Field, SecretStr

load_dotenv()
logger = logging.getLogger("monarch.proxy")
# HTTPX's normal INFO logging includes upstream URLs; never log bodies or headers.
logging.getLogger("httpx").setLevel(logging.WARNING)
logging.getLogger("httpcore").setLevel(logging.WARNING)


@dataclass(frozen=True)
class Settings:
    client_id: str = ""
    secret: str = ""
    app_key: str = ""
    environment: str = "sandbox"
    redirect_uri: str = ""
    sandbox_tools: bool = False
    allow_production: bool = False
    rate_limit: int = 30
    ship24_api_key: str = ""

    @classmethod
    def from_env(cls) -> "Settings":
        return cls(
            client_id=os.getenv("PLAID_CLIENT_ID", ""),
            secret=os.getenv("PLAID_SECRET", ""),
            app_key=os.getenv("APP_KEY", ""),
            environment=os.getenv("PLAID_ENV", "sandbox"),
            redirect_uri=os.getenv("PLAID_REDIRECT_URI", ""),
            sandbox_tools=os.getenv("ENABLE_SANDBOX_TOOLS", "false").lower() == "true",
            allow_production=os.getenv("ALLOW_PRODUCTION", "false").lower() == "true",
            ship24_api_key=os.getenv("SHIP24_API_KEY", ""),
        )

    @property
    def configured(self) -> bool:
        return bool(self.client_id and self.secret and len(self.app_key) >= 32)

    def validate(self) -> None:
        if self.environment not in {"sandbox", "production"}:
            raise ValueError("PLAID_ENV must be sandbox or production")
        if self.environment == "production" and not self.allow_production:
            raise ValueError("Production requires ALLOW_PRODUCTION=true")
        if self.environment == "production" and self.sandbox_tools:
            raise ValueError("Sandbox tools must be disabled in production")
        if self.redirect_uri:
            parsed = urlparse(self.redirect_uri)
            if parsed.scheme != "https" or not parsed.netloc or parsed.query or parsed.fragment:
                raise ValueError("PLAID_REDIRECT_URI must be an HTTPS Universal Link without query/fragment")
        if self.environment == "production" and not self.redirect_uri:
            raise ValueError("Production requires a registered HTTPS PLAID_REDIRECT_URI")


class Payload(BaseModel):
    model_config = ConfigDict(extra="forbid")


class AccessPayload(Payload):
    access_token: SecretStr = Field(min_length=1, max_length=512)


class LinkPayload(Payload):
    client_user_id: str = Field(min_length=1, max_length=128, pattern=r"^[A-Za-z0-9_-]+$")
    product: Literal["transactions", "liabilities", "investments"] = "transactions"
    access_token: SecretStr | None = Field(default=None, min_length=1, max_length=512)


class ExchangePayload(Payload):
    public_token: SecretStr = Field(min_length=1, max_length=512)


class SyncPayload(AccessPayload):
    cursor: str | None = Field(default=None, max_length=2048)


class SandboxPayload(Payload):
    product: Literal["transactions", "liabilities", "investments"] = "transactions"
    dynamic: bool = True


class TrackingPayload(Payload):
    tracking_number: str = Field(min_length=8, max_length=100, pattern=r"^[A-Za-z0-9_-]+$")


class ProxyFailure(Exception):
    def __init__(self, code: str, status: int = 502, message: str = "Plaid could not complete the request. Please try again."):
        self.code, self.status, self.message = code, status, message


SAFE_MESSAGES = {
    "INVALID_API_KEYS": "Check the Plaid client ID and matching secret for the sync server's environment.",
    "ITEM_LOGIN_REQUIRED": "Reconnect this bank to continue syncing.",
    "PRODUCT_NOT_READY": "Plaid is still preparing this product. Refresh again shortly.",
    "TRANSACTIONS_SYNC_MUTATION_DURING_PAGINATION": "Transaction data changed during pagination. Restart the sync.",
    "INVALID_ACCESS_TOKEN": "This connection needs to be reconnected.",
    "INVALID_LINK_TOKEN": "The bank connection session expired. Open a new session.",
    "INVALID_CREDENTIALS": "Check the Plaid client ID and secret on the sync server.",
    "RATE_LIMIT_EXCEEDED": "Plaid is busy. Wait a minute and try again.",
    "INSTITUTION_DOWN": "The institution is temporarily unavailable.",
    "PRODUCTS_NOT_SUPPORTED": "This institution does not support the selected product.",
}


class RateLimiter:
    """Only request timestamps, never tokens, bodies, or financial responses."""
    def __init__(self, limit: int):
        self.limit = limit
        self.requests: dict[str, deque[float]] = defaultdict(deque)
        self.lock = asyncio.Lock()

    async def allow(self, key: str) -> bool:
        now = time.monotonic()
        async with self.lock:
            for ip in list(self.requests):
                queue = self.requests[ip]
                while queue and queue[0] <= now - 60:
                    queue.popleft()
                if not queue:
                    del self.requests[ip]
            if key not in self.requests and len(self.requests) >= 10000:
                return False
            queue = self.requests[key]
            if len(queue) >= self.limit:
                return False
            queue.append(now)
            return True


class BodyLimitMiddleware:
    """Bound even chunked bodies before JSON decoding; keep them only for the request."""
    def __init__(self, app, limit=16384):
        self.app, self.limit = app, limit

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            return await self.app(scope, receive, send)
        chunks = []
        total = 0
        while True:
            message = await receive()
            if message["type"] == "http.disconnect":
                return
            total += len(message.get("body", b""))
            if total > self.limit:
                response = JSONResponse({"error_code": "REQUEST_TOO_LARGE", "message": "Request is too large."}, status_code=413, headers={"Cache-Control": "no-store"})
                return await response(scope, receive, send)
            chunks.append(message)
            if not message.get("more_body", False):
                break

        async def replay():
            if chunks:
                return chunks.pop(0)
            return await receive()

        await self.app(scope, replay, send)


def pick(value: dict, fields: tuple[str, ...]) -> dict:
    return {key: value[key] for key in fields if key in value}


ACCOUNT_FIELDS = ("account_id", "name", "official_name", "type", "subtype", "mask", "balances")
TRANSACTION_FIELDS = ("transaction_id", "pending_transaction_id", "account_id", "date", "amount", "name", "merchant_name", "original_description", "pending", "personal_finance_category")


def create_app(settings: Settings | None = None, transport: httpx.AsyncBaseTransport | None = None) -> FastAPI:
    settings = settings or Settings.from_env()
    settings.validate()
    limiter = RateLimiter(settings.rate_limit)

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        # Only a fixed Plaid host is reachable through this client. Standard CA
        # verification remains on; trust_env preserves the supported proxy/CA path.
        async with httpx.AsyncClient(base_url=f"https://{settings.environment}.plaid.com", timeout=50, transport=transport, trust_env=True, follow_redirects=False) as client:
            app.state.plaid = client
            async with httpx.AsyncClient(base_url="https://api.ship24.com/public/v1", timeout=55, transport=transport, trust_env=True, follow_redirects=False) as tracking_client:
                app.state.tracking = tracking_client
                yield

    app = FastAPI(title="Monarch Plaid Proxy", version="0.1.0", lifespan=lifespan, docs_url=None, redoc_url=None, openapi_url=None)
    app.add_middleware(BodyLimitMiddleware)

    @app.exception_handler(ProxyFailure)
    async def proxy_failure(_request: Request, error: ProxyFailure):
        return JSONResponse({"error_code": error.code, "message": error.message}, status_code=error.status)

    @app.exception_handler(RequestValidationError)
    async def validation_failure(_request: Request, _error: RequestValidationError):
        # Pydantic's default output can echo input (including access tokens).
        return JSONResponse({"error_code": "INVALID_REQUEST", "message": "The request is missing a required field or contains invalid fields."}, status_code=422)

    @app.middleware("http")
    async def safe_metadata(request: Request, call_next):
        start = time.monotonic()
        length = request.headers.get("content-length", "0")
        if not length.isdigit() or int(length) > 16384:
            return JSONResponse({"error_code": "REQUEST_TOO_LARGE", "message": "Request is too large."}, status_code=413)
        response = await call_next(request)
        response.headers["Cache-Control"] = "no-store"
        response.headers["Pragma"] = "no-cache"
        response.headers["X-Content-Type-Options"] = "nosniff"
        route = request.scope.get("route")
        # The registered route template cannot contain secrets from a path/query.
        safe_path = route.path if route else "unmatched"
        logger.info("%s %s %d %.0fms", request.method, safe_path, response.status_code, (time.monotonic() - start) * 1000)
        return response

    async def authorize_app(request: Request, x_app_key: str = Header(default="")):
        if not settings.app_key or not hmac.compare_digest(x_app_key.encode(), settings.app_key.encode()):
            raise ProxyFailure("UNAUTHORIZED", 401, "Check the app key in Settings.")
        # Do not trust caller-supplied X-Forwarded-For. Configure uvicorn's trusted
        # proxy IPs at deployment if a reverse proxy is used.
        ip = request.client.host if request.client else "unknown"
        if not await limiter.allow(ip):
            raise ProxyFailure("RATE_LIMITED", 429, "Wait a minute before trying again.")
    async def authorize(_auth=Depends(authorize_app)):
        if not settings.configured:
            raise ProxyFailure("SERVER_NOT_CONFIGURED", 503, "Set the Plaid credentials and a 32-character app key on the sync server.")

    async def plaid(path: str, payload: dict) -> dict:
        try:
            response = await app.state.plaid.post(path, json={"client_id": settings.client_id, "secret": settings.secret, **payload}, headers={"Plaid-Version": "2020-09-14"})
        except httpx.TimeoutException:
            raise ProxyFailure("UPSTREAM_TIMEOUT", 504, "Plaid took too long to respond. Try again.") from None
        except httpx.HTTPError:
            raise ProxyFailure("UPSTREAM_UNAVAILABLE", 502) from None
        try:
            data = response.json()
        except ValueError:
            raise ProxyFailure("INVALID_UPSTREAM_RESPONSE") from None
        if not isinstance(data, dict):
            raise ProxyFailure("INVALID_UPSTREAM_RESPONSE")
        if response.status_code >= 300:
            code = data.get("error_code", "PLAID_ERROR")
            if not isinstance(code, str) or not re.fullmatch(r"[A-Z0-9_]{1,100}", code):
                code = "PLAID_ERROR"
            raise ProxyFailure(code, 502, SAFE_MESSAGES.get(code, "Plaid could not complete this request. Check the product and try again."))
        return data

    def token(payload: AccessPayload) -> dict:
        value = payload.access_token.get_secret_value()
        if not value.startswith(f"access-{settings.environment}-"):
            raise ProxyFailure("TOKEN_ENVIRONMENT_MISMATCH", 400, "The connection token belongs to another Plaid environment.")
        return {"access_token": value}

    def require_sandbox():
        if settings.environment != "sandbox" or not settings.sandbox_tools:
            raise ProxyFailure("SANDBOX_TOOLS_DISABLED", 403, "Enable Sandbox tools on the Sandbox server to use this test control.")

    protected = [Depends(authorize)]

    @app.get("/health")
    async def health():
        return {"ok": True, "environment": settings.environment, "configured": settings.configured, "sandbox_tools": settings.sandbox_tools and settings.environment == "sandbox", "tracking_configured": bool(settings.ship24_api_key)}

    @app.post("/link/token", dependencies=protected)
    async def link(payload: LinkPayload):
        body = {"user": {"client_user_id": payload.client_user_id}, "client_name": "Monarch Personal", "country_codes": ["US"], "language": "en"}
        if settings.redirect_uri:
            body["redirect_uri"] = settings.redirect_uri
        if payload.access_token:
            access = AccessPayload(access_token=payload.access_token)
            body.update(token(access))
            # Update mode deliberately omits products and never exchanges a new token.
        else:
            body["products"] = [payload.product]
            if payload.product == "transactions":
                body["transactions"] = {"days_requested": 365}
        data = await plaid("/link/token/create", body)
        return pick(data, ("link_token", "expiration"))

    @app.post("/session/check", dependencies=[Depends(authorize_app)])
    async def session_check():
        return {"ok": True}

    @app.post("/tracking", dependencies=[Depends(authorize_app)])
    async def tracking(payload: TrackingPayload):
        fallback = {"available": False, "status": None, "eta": None, "last_event": "Live tracking is unavailable. Open the carrier link for updates.", "events": []}
        if not settings.ship24_api_key or payload.tracking_number.upper().startswith(("TBA", "LINK")):
            return fallback
        try:
            response = await app.state.tracking.post("/trackers/track", json={"trackingNumber": payload.tracking_number}, headers={"Authorization": "Bearer " + settings.ship24_api_key, "Content-Type": "application/json"})
            if response.status_code not in (200, 201):
                return fallback
            data = response.json()
            trackings = data.get("data", {}).get("trackings", [])
            if not trackings:
                return fallback
            result = trackings[0]
            shipment = result.get("shipment") or {}
            states = {"info_received": "labelCreated", "in_transit": "inTransit", "out_for_delivery": "outForDelivery", "delivered": "delivered", "failed_attempt": "exception", "exception": "exception", "available_for_pickup": "inTransit"}
            status = states.get(shipment.get("statusMilestone"))
            events = []
            for event in (result.get("events") or [])[:100]:
                events.append({"id": str(event.get("eventId") or len(events)), "date": event.get("occurrenceDatetime"), "description": str(event.get("status") or "Tracking update")[:500], "location": str(event.get("location"))[:150] if event.get("location") else None})
            delivery = shipment.get("delivery") or {}
            estimate = delivery.get("estimatedDeliveryDate") or delivery.get("estimatedDeliveryDateTime")
            if isinstance(estimate, dict):
                estimate = estimate.get("to") or estimate.get("from") or estimate.get("estimatedDeliveryDateMax") or estimate.get("estimatedDeliveryDateMin")
            return {"available": bool(status or events), "status": status, "eta": estimate if isinstance(estimate, str) else None, "last_event": events[0]["description"] if events else "Awaiting a carrier update.", "events": events}
        except (httpx.HTTPError, ValueError, AttributeError, TypeError):
            return fallback

    @app.post("/item/exchange", dependencies=protected)
    async def exchange(payload: ExchangePayload):
        value = payload.public_token.get_secret_value()
        if not value.startswith(f"public-{settings.environment}-"):
            raise ProxyFailure("TOKEN_ENVIRONMENT_MISMATCH", 400)
        data = await plaid("/item/public_token/exchange", {"public_token": value})
        return pick(data, ("access_token", "item_id"))

    @app.post("/accounts", dependencies=protected)
    async def accounts(payload: AccessPayload):
        # /accounts/get includes the institution's latest available balance without
        # enabling the separately billed real-time Balance endpoint.
        data = await plaid("/accounts/get", token(payload))
        return {"accounts": [pick(account, ACCOUNT_FIELDS) for account in data.get("accounts", [])]}

    @app.post("/transactions/sync", dependencies=protected)
    async def sync(payload: SyncPayload):
        body = {**token(payload), "count": 500, "options": {"include_original_description": True}}
        if payload.cursor is not None:
            body["cursor"] = payload.cursor
        data = await plaid("/transactions/sync", body)
        return {
            "added": [pick(tx, TRANSACTION_FIELDS) for tx in data.get("added", [])],
            "modified": [pick(tx, TRANSACTION_FIELDS) for tx in data.get("modified", [])],
            "removed": [pick(tx, ("transaction_id",)) for tx in data.get("removed", [])],
            **pick(data, ("next_cursor", "has_more", "transactions_update_status")),
        }

    @app.post("/liabilities", dependencies=protected)
    async def liabilities(payload: AccessPayload):
        data = await plaid("/liabilities/get", token(payload))
        value = data.get("liabilities", {})
        student_fields = ("account_id", "interest_rate_percentage", "minimum_payment_amount", "next_payment_due_date", "outstanding_interest_amount", "loan_name")
        credit_fields = ("account_id", "minimum_payment_amount", "next_payment_due_date", "last_statement_issue_date", "last_statement_balance")
        return {"student": [pick(x, student_fields) for x in value.get("student", [])], "credit": [pick(x, credit_fields) for x in value.get("credit", [])]}

    @app.post("/investments", dependencies=protected)
    async def investments(payload: AccessPayload):
        data = await plaid("/investments/holdings/get", token(payload))
        holding_fields = ("account_id", "security_id", "quantity", "cost_basis", "institution_price", "institution_price_as_of")
        security_fields = ("security_id", "name", "ticker_symbol", "type", "close_price", "close_price_as_of")
        return {"holdings": [pick(x, holding_fields) for x in data.get("holdings", [])], "securities": [pick(x, security_fields) for x in data.get("securities", [])]}

    @app.post("/item/status", dependencies=protected)
    async def item_status(payload: AccessPayload):
        data = await plaid("/item/get", token(payload))
        item = data.get("item", {})
        error = item.get("error")
        return {"error": pick(error, ("error_code",)) if isinstance(error, dict) else None, **pick(item, ("consent_expiration_time",))}

    @app.post("/sandbox/item/create", dependencies=protected)
    async def sandbox_create(payload: SandboxPayload):
        require_sandbox()
        institutions = {
            "transactions": ("ins_109508", "First Platypus Bank"),
            "liabilities": ("ins_109509", "First Gingham Credit Union"),
            "investments": ("ins_109511", "Tartan Bank"),
        }
        institution_id, institution_name = institutions[payload.product]
        options = {"override_username": "user_transactions_dynamic", "override_password": "pass_good"} if payload.dynamic and payload.product == "transactions" else {}
        data = await plaid("/sandbox/public_token/create", {"institution_id": institution_id, "initial_products": [payload.product], "options": options})
        return {"public_token": data["public_token"], "institution_id": institution_id, "institution_name": institution_name, "account_masks": []}

    @app.post("/sandbox/item/reset-login", dependencies=protected)
    async def sandbox_reset(payload: AccessPayload):
        require_sandbox()
        await plaid("/sandbox/item/reset_login", token(payload))
        return {"ok": True}

    @app.post("/sandbox/transactions/refresh", dependencies=protected)
    async def sandbox_refresh(payload: AccessPayload):
        require_sandbox()
        await plaid("/transactions/refresh", token(payload))
        return {"ok": True}

    return app


app = create_app()

import os
import time
import json
import httpx
import logging
from datetime import datetime, timezone
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request, Response, HTTPException, Depends
from fastapi.middleware.cors import CORSMiddleware
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from prometheus_client import Counter, Histogram, generate_latest, CONTENT_TYPE_LATEST
from slowapi import Limiter, _rate_limit_exceeded_handler
from slowapi.util import get_remote_address
from slowapi.errors import RateLimitExceeded

# ── Logging ───────────────────────────────────────────────────────────────────

class JSONFormatter(logging.Formatter):
    def format(self, record):
        return json.dumps({
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "level":     record.levelname,
            "service":   "api-gateway",
            "message":   record.getMessage(),
        })

handler = logging.StreamHandler()
handler.setFormatter(JSONFormatter())
logging.basicConfig(level=logging.INFO, handlers=[handler])
logger = logging.getLogger("api-gateway")

# ── Config ────────────────────────────────────────────────────────────────────

API_KEY         = os.environ.get("API_KEY", "dev-api-key")
ORDER_SVC       = os.environ.get("ORDER_SERVICE_URL",       "http://order-service:8001")
INVENTORY_SVC   = os.environ.get("INVENTORY_SERVICE_URL",   "http://inventory-service:8002")
PAYMENT_SVC     = os.environ.get("PAYMENT_SERVICE_URL",     "http://payment-service:8003")
NOTIFICATION_SVC= os.environ.get("NOTIFICATION_SERVICE_URL","http://notification-service:8004")
SHIPPING_SVC    = os.environ.get("SHIPPING_SERVICE_URL",    "http://shipping-service:8005")
DASHBOARD_SVC   = os.environ.get("DASHBOARD_SERVICE_URL",   "http://dashboard-api:8009")

# ── Metrics ───────────────────────────────────────────────────────────────────

REQUEST_COUNT = Counter(
    "gateway_requests_total", "Total requests",
    ["method", "path", "status"]
)
REQUEST_LATENCY = Histogram(
    "gateway_request_duration_seconds", "Request latency",
    ["method", "path"],
    buckets=[0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5]
)
UPSTREAM_ERRORS = Counter(
    "gateway_upstream_errors_total", "Upstream errors",
    ["service"]
)

# ── Rate limiter ──────────────────────────────────────────────────────────────

limiter = Limiter(key_func=get_remote_address)

# ── App ───────────────────────────────────────────────────────────────────────

@asynccontextmanager
async def lifespan(app: FastAPI):
    logger.info("api-gateway starting")
    yield
    logger.info("api-gateway stopping")

app = FastAPI(title="API Gateway", version="1.0.0", lifespan=lifespan)
app.state.limiter = limiter
app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

# ── Middleware ────────────────────────────────────────────────────────────────

@app.middleware("http")
async def observe(request: Request, call_next):
    start    = time.time()
    response = await call_next(request)
    latency  = time.time() - start
    REQUEST_COUNT.labels(request.method, request.url.path, response.status_code).inc()
    REQUEST_LATENCY.labels(request.method, request.url.path).observe(latency)
    return response

# ── Auth ──────────────────────────────────────────────────────────────────────

security = HTTPBearer(auto_error=False)

def verify_api_key(
    request: Request,
    credentials: HTTPAuthorizationCredentials = Depends(security)
):
    # Skip auth for health and metrics
    if request.url.path in ["/health", "/metrics", "/ready"]:
        return True

    api_key = None

    # Check Authorization header
    if credentials:
        api_key = credentials.credentials

    # Check X-API-Key header
    if not api_key:
        api_key = request.headers.get("X-API-Key")

    if not api_key or api_key != API_KEY:
        raise HTTPException(status_code=401, detail="Invalid or missing API key")

    return True

# ── Proxy helper ──────────────────────────────────────────────────────────────

async def proxy(
    request: Request,
    upstream: str,
    path: str,
    service_name: str
):
    url = f"{upstream}{path}"
    body = await request.body()

    headers = dict(request.headers)
    headers.pop("host", None)
    headers["X-Forwarded-For"] = request.client.host
    headers["X-Request-ID"]    = request.headers.get("X-Request-ID", "")

    try:
        async with httpx.AsyncClient(timeout=30.0) as client:
            resp = await client.request(
                method  = request.method,
                url     = url,
                headers = headers,
                content = body,
                params  = request.query_params,
            )
        return Response(
            content     = resp.content,
            status_code = resp.status_code,
            media_type  = resp.headers.get("content-type", "application/json"),
        )
    except httpx.TimeoutException:
        UPSTREAM_ERRORS.labels(service_name).inc()
        logger.error(f"timeout calling {service_name}")
        raise HTTPException(status_code=504, detail=f"{service_name} timeout")
    except httpx.ConnectError:
        UPSTREAM_ERRORS.labels(service_name).inc()
        logger.error(f"connection error calling {service_name}")
        raise HTTPException(status_code=503, detail=f"{service_name} unavailable")

# ── Routes ────────────────────────────────────────────────────────────────────

@app.get("/health")
def health():
    return {"status": "ok", "service": "api-gateway"}

@app.get("/ready")
def ready():
    return {"status": "ready"}

@app.get("/metrics")
def metrics():
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)

# Orders
@app.api_route("/orders/{path:path}", methods=["GET","POST","PUT","PATCH","DELETE"])
@limiter.limit("100/minute")
async def orders_proxy(
    path: str,
    request: Request,
    _auth = Depends(verify_api_key)
):
    return await proxy(request, ORDER_SVC, f"/orders/{path}", "order-service")

@app.api_route("/orders", methods=["GET","POST"])
@limiter.limit("100/minute")
async def orders_root(
    request: Request,
    _auth = Depends(verify_api_key)
):
    return await proxy(request, ORDER_SVC, "/orders", "order-service")

# Inventory
@app.api_route("/inventory/{path:path}", methods=["GET","POST","PUT","PATCH","DELETE"])
@limiter.limit("200/minute")
async def inventory_proxy(
    path: str,
    request: Request,
    _auth = Depends(verify_api_key)
):
    return await proxy(request, INVENTORY_SVC, f"/inventory/{path}", "inventory-service")

@app.api_route("/inventory", methods=["GET","POST"])
@limiter.limit("200/minute")
async def inventory_root(
    request: Request,
    _auth = Depends(verify_api_key)
):
    return await proxy(request, INVENTORY_SVC, "/inventory", "inventory-service")

# Payments
@app.api_route("/payments/{path:path}", methods=["GET","POST","PUT","PATCH","DELETE"])
@limiter.limit("50/minute")
async def payments_proxy(
    path: str,
    request: Request,
    _auth = Depends(verify_api_key)
):
    return await proxy(request, PAYMENT_SVC, f"/payments/{path}", "payment-service")

@app.api_route("/payments", methods=["GET","POST"])
@limiter.limit("50/minute")
async def payments_root(
    request: Request,
    _auth = Depends(verify_api_key)
):
    return await proxy(request, PAYMENT_SVC, "/payments", "payment-service")

# Shipping
@app.api_route("/shipping/{path:path}", methods=["GET","POST","PUT","PATCH","DELETE"])
@limiter.limit("100/minute")
async def shipping_proxy(
    path: str,
    request: Request,
    _auth = Depends(verify_api_key)
):
    return await proxy(request, SHIPPING_SVC, f"/shipping/{path}", "shipping-service")

@app.api_route("/shipping", methods=["GET","POST"])
@limiter.limit("100/minute")
async def shipping_root(
    request: Request,
    _auth = Depends(verify_api_key)
):
    return await proxy(request, SHIPPING_SVC, "/shipping", "shipping-service")

# Dashboard
@app.api_route("/dashboard/{path:path}", methods=["GET","POST"])
@limiter.limit("200/minute")
async def dashboard_proxy(
    path: str,
    request: Request,
    _auth = Depends(verify_api_key)
):
    return await proxy(request, DASHBOARD_SVC, f"/dashboard/{path}", "dashboard-api")

@app.api_route("/dashboard", methods=["GET"])
@limiter.limit("200/minute")
async def dashboard_root(
    request: Request,
    _auth = Depends(verify_api_key)
):
    return await proxy(request, DASHBOARD_SVC, "/dashboard", "dashboard-api")
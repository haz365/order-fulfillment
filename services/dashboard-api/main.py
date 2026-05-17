import os
import json
import time
import logging
from datetime import datetime, timezone
from contextlib import asynccontextmanager
from typing import Optional

import psycopg2
from psycopg2.extras import RealDictCursor
from fastapi import FastAPI, HTTPException, Request, Response
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import HTMLResponse
from fastapi.staticfiles import StaticFiles
from prometheus_client import Counter, Histogram, generate_latest, CONTENT_TYPE_LATEST

# ── Logging ───────────────────────────────────────────────────────────────────

class JSONFormatter(logging.Formatter):
    def format(self, record):
        return json.dumps({
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "level":     record.levelname,
            "service":   "dashboard-api",
            "message":   record.getMessage(),
        })

handler = logging.StreamHandler()
handler.setFormatter(JSONFormatter())
logging.basicConfig(level=logging.INFO, handlers=[handler])
logger = logging.getLogger("dashboard-api")

# ── Config ────────────────────────────────────────────────────────────────────

DB_HOST     = os.environ["DB_HOST"]
DB_PORT     = int(os.environ.get("DB_PORT", "5432"))
DB_NAME     = os.environ["DB_NAME"]
DB_USER     = os.environ["DB_USER"]
DB_PASSWORD = os.environ["DB_PASSWORD"]
DB_SSL_MODE = os.environ.get("DB_SSL_MODE", "require")

# ── Metrics ───────────────────────────────────────────────────────────────────

REQUEST_COUNT = Counter(
    "dashboard_requests_total", "Total requests",
    ["method", "endpoint", "status"]
)
REQUEST_LATENCY = Histogram(
    "dashboard_request_duration_seconds", "Request latency",
    ["method", "endpoint"],
    buckets=[0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5]
)

# ── DB ────────────────────────────────────────────────────────────────────────

def get_db():
    return psycopg2.connect(
        host=DB_HOST, port=DB_PORT, dbname=DB_NAME,
        user=DB_USER, password=DB_PASSWORD,
        sslmode=DB_SSL_MODE,
        cursor_factory=RealDictCursor,
        connect_timeout=5,
    )

# ── App ───────────────────────────────────────────────────────────────────────

@asynccontextmanager
async def lifespan(app: FastAPI):
    logger.info("dashboard-api starting")
    yield

app = FastAPI(title="Dashboard API", version="1.0.0", lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

@app.middleware("http")
async def observe(request: Request, call_next):
    start    = time.time()
    response = await call_next(request)
    latency  = time.time() - start
    REQUEST_COUNT.labels(request.method, request.url.path, response.status_code).inc()
    REQUEST_LATENCY.labels(request.method, request.url.path).observe(latency)
    return response

# ── Frontend ──────────────────────────────────────────────────────────────────

@app.get("/", response_class=HTMLResponse)
def frontend():
    try:
        with open("/app/static/index.html") as f:
            return f.read()
    except FileNotFoundError:
        return HTMLResponse("<h1>Dashboard UI not found</h1>", status_code=404)

# ── Routes ────────────────────────────────────────────────────────────────────

@app.get("/health")
def health():
    try:
        conn = get_db()
        conn.cursor().execute("SELECT 1")
        conn.close()
        return {"status": "ok", "service": "dashboard-api", "db": "ok"}
    except Exception as e:
        return Response(
            content     = json.dumps({"status": "degraded", "db": str(e)}),
            status_code = 503,
            media_type  = "application/json"
        )

@app.get("/metrics")
def metrics():
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)

@app.get("/dashboard/summary")
def summary():
    conn = get_db()
    cur  = conn.cursor()
    try:
        cur.execute("""
            SELECT
                COUNT(*) as total_orders,
                COUNT(*) FILTER (WHERE status = 'pending')   as pending,
                COUNT(*) FILTER (WHERE status = 'confirmed') as confirmed,
                COUNT(*) FILTER (WHERE status = 'paid')      as paid,
                COUNT(*) FILTER (WHERE status = 'shipped')   as shipped,
                COUNT(*) FILTER (WHERE status = 'delivered') as delivered,
                COUNT(*) FILTER (WHERE status = 'cancelled') as cancelled,
                COALESCE(SUM(total_amount), 0) as total_revenue,
                COALESCE(AVG(total_amount), 0) as avg_order_value
            FROM orders
        """)
        orders = dict(cur.fetchone())

        cur.execute("""
            SELECT COUNT(*) as today_orders,
                   COALESCE(SUM(total_amount), 0) as today_revenue
            FROM orders
            WHERE created_at >= CURRENT_DATE
        """)
        today = dict(cur.fetchone())

        cur.execute("""
            SELECT
                COUNT(*) as total_payments,
                COALESCE(SUM(amount) FILTER (WHERE status = 'completed'), 0) as total_collected,
                COUNT(*) FILTER (WHERE status = 'failed') as failed_payments,
                COUNT(*) FILTER (WHERE status = 'refunded') as refunds
            FROM payments
        """)
        payments = dict(cur.fetchone())

        for key in orders:
            if hasattr(orders[key], '__float__'):
                orders[key] = float(orders[key])
        for key in today:
            if hasattr(today[key], '__float__'):
                today[key] = float(today[key])
        for key in payments:
            if hasattr(payments[key], '__float__'):
                payments[key] = float(payments[key])

        return {
            "orders":   orders,
            "today":    today,
            "payments": payments,
            "generated_at": datetime.now(timezone.utc).isoformat(),
        }
    finally:
        cur.close()
        conn.close()

@app.get("/dashboard/orders")
def recent_orders(
    limit:  int = 20,
    offset: int = 0,
    status: Optional[str] = None
):
    conn = get_db()
    cur  = conn.cursor()
    try:
        query  = """
            SELECT o.id, o.customer_id, o.status, o.total_amount,
                   o.currency, o.created_at, o.updated_at,
                   COUNT(i.id) as item_count
            FROM orders o
            LEFT JOIN order_items i ON i.order_id = o.id
            WHERE 1=1
        """
        params = []
        if status:
            query += " AND o.status = %s"
            params.append(status)
        query += """
            GROUP BY o.id
            ORDER BY o.created_at DESC
            LIMIT %s OFFSET %s
        """
        params += [limit, offset]
        cur.execute(query, params)
        orders = [dict(r) for r in cur.fetchall()]
        for o in orders:
            o["id"]           = str(o["id"])
            o["customer_id"]  = str(o["customer_id"])
            o["total_amount"] = float(o["total_amount"])
            o["created_at"]   = o["created_at"].isoformat()
            o["updated_at"]   = o["updated_at"].isoformat()
        return {"orders": orders, "count": len(orders)}
    finally:
        cur.close()
        conn.close()

@app.get("/dashboard/revenue")
def revenue(days: int = 7):
    conn = get_db()
    cur  = conn.cursor()
    try:
        cur.execute("""
            SELECT
                DATE_TRUNC('day', created_at) as day,
                COUNT(*) as order_count,
                COALESCE(SUM(total_amount), 0) as revenue
            FROM orders
            WHERE status IN ('paid','shipped','delivered')
            AND created_at >= NOW() - INTERVAL '%s days'
            GROUP BY DATE_TRUNC('day', created_at)
            ORDER BY day ASC
        """, (days,))
        rows = [dict(r) for r in cur.fetchall()]
        for r in rows:
            r["day"]     = r["day"].isoformat()
            r["revenue"] = float(r["revenue"])
        return {"revenue": rows, "days": days}
    finally:
        cur.close()
        conn.close()

@app.get("/dashboard/events")
def recent_events(limit: int = 50):
    conn = get_db()
    cur  = conn.cursor()
    try:
        cur.execute("""
            SELECT event_type, payload, processed_at
            FROM processed_events
            ORDER BY processed_at DESC
            LIMIT %s
        """, (limit,))
        events = [dict(r) for r in cur.fetchall()]
        for e in events:
            e["processed_at"] = e["processed_at"].isoformat()
        return {"events": events, "count": len(events)}
    finally:
        cur.close()
        conn.close()

@app.get("/dashboard/inventory")
def inventory_status():
    conn = get_db()
    cur  = conn.cursor()
    try:
        cur.execute("""
            SELECT
                COUNT(*) as total_products,
                COUNT(*) FILTER (
                    WHERE stock - reserved <= low_stock_threshold
                ) as low_stock_count,
                COUNT(*) FILTER (WHERE stock = 0) as out_of_stock,
                COALESCE(SUM(stock), 0) as total_units
            FROM products
        """)
        row = dict(cur.fetchone())
        for k in row:
            if hasattr(row[k], '__float__'):
                row[k] = float(row[k])
        return row
    finally:
        cur.close()
        conn.close()

@app.get("/dashboard/notifications")
def notification_stats():
    conn = get_db()
    cur  = conn.cursor()
    try:
        cur.execute("""
            SELECT
                type,
                channel,
                COUNT(*) as total,
                COUNT(*) FILTER (WHERE status = 'sent')   as sent,
                COUNT(*) FILTER (WHERE status = 'failed') as failed
            FROM notifications
            GROUP BY type, channel
            ORDER BY total DESC
        """)
        rows = [dict(r) for r in cur.fetchall()]
        return {"notifications": rows, "count": len(rows)}
    finally:
        cur.close()
        conn.close()

@app.get("/dashboard/scheduler")
def scheduler_status():
    conn = get_db()
    cur  = conn.cursor()
    try:
        cur.execute("""
            SELECT
                job_name,
                COUNT(*) as total_runs,
                COUNT(*) FILTER (WHERE status = 'completed') as successful,
                COUNT(*) FILTER (WHERE status = 'failed')    as failed,
                MAX(started_at) as last_run,
                AVG(EXTRACT(EPOCH FROM (ended_at - started_at)))
                    FILTER (WHERE status = 'completed') as avg_duration_seconds
            FROM scheduler_runs
            WHERE started_at > NOW() - INTERVAL '24 hours'
            GROUP BY job_name
            ORDER BY job_name
        """)
        rows = [dict(r) for r in cur.fetchall()]
        for r in rows:
            r["last_run"] = r["last_run"].isoformat() if r["last_run"] else None
            if r["avg_duration_seconds"]:
                r["avg_duration_seconds"] = float(r["avg_duration_seconds"])
        return {"jobs": rows}
    finally:
        cur.close()
        conn.close()
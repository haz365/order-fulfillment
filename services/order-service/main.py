import os
import json
import time
import uuid
import logging
import boto3
from datetime import datetime, timezone
from contextlib import asynccontextmanager
from typing import Optional

import psycopg2
from psycopg2.extras import RealDictCursor
from fastapi import FastAPI, HTTPException, Request, Response
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from prometheus_client import Counter, Histogram, generate_latest, CONTENT_TYPE_LATEST

# ── Logging ───────────────────────────────────────────────────────────────────

class JSONFormatter(logging.Formatter):
    def format(self, record):
        return json.dumps({
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "level":     record.levelname,
            "service":   "order-service",
            "message":   record.getMessage(),
        })

handler = logging.StreamHandler()
handler.setFormatter(JSONFormatter())
logging.basicConfig(level=logging.INFO, handlers=[handler])
logger = logging.getLogger("order-service")

# ── Config ────────────────────────────────────────────────────────────────────

DB_HOST     = os.environ["DB_HOST"]
DB_PORT     = int(os.environ.get("DB_PORT", "5432"))
DB_NAME     = os.environ["DB_NAME"]
DB_USER     = os.environ["DB_USER"]
DB_PASSWORD = os.environ["DB_PASSWORD"]
DB_SSL_MODE = os.environ.get("DB_SSL_MODE", "require")
SQS_QUEUE   = os.environ.get("SQS_QUEUE_URL", "")
AWS_REGION  = os.environ.get("AWS_REGION", "eu-west-2")

# ── Metrics ───────────────────────────────────────────────────────────────────

REQUEST_COUNT = Counter(
    "order_requests_total", "Total requests",
    ["method", "endpoint", "status"]
)
REQUEST_LATENCY = Histogram(
    "order_request_duration_seconds", "Request latency",
    ["method", "endpoint"],
    buckets=[0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5]
)
ORDERS_CREATED   = Counter("orders_created_total",   "Orders created")
ORDERS_CANCELLED = Counter("orders_cancelled_total", "Orders cancelled")
ORDERS_COMPLETED = Counter("orders_completed_total", "Orders completed")

# ── DB ────────────────────────────────────────────────────────────────────────

def get_db():
    return psycopg2.connect(
        host=DB_HOST, port=DB_PORT, dbname=DB_NAME,
        user=DB_USER, password=DB_PASSWORD,
        sslmode=DB_SSL_MODE,
        cursor_factory=RealDictCursor,
        connect_timeout=5,
    )

def init_db():
    conn = get_db()
    cur  = conn.cursor()
    try:
        cur.execute("""
            CREATE TABLE IF NOT EXISTS orders (
                id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                customer_id  UUID NOT NULL,
                status       VARCHAR(20) DEFAULT 'pending'
                                 CHECK (status IN (
                                   'pending','confirmed','paid',
                                   'shipped','delivered','cancelled'
                                 )),
                total_amount NUMERIC(10,2) NOT NULL DEFAULT 0,
                currency     VARCHAR(3)   NOT NULL DEFAULT 'GBP',
                notes        TEXT,
                created_at   TIMESTAMPTZ DEFAULT NOW(),
                updated_at   TIMESTAMPTZ DEFAULT NOW()
            );

            CREATE TABLE IF NOT EXISTS order_items (
                id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                order_id     UUID REFERENCES orders(id) ON DELETE CASCADE,
                product_id   UUID NOT NULL,
                quantity     INT  NOT NULL CHECK (quantity > 0),
                unit_price   NUMERIC(10,2) NOT NULL,
                created_at   TIMESTAMPTZ DEFAULT NOW()
            );

            CREATE INDEX IF NOT EXISTS idx_orders_customer
                ON orders(customer_id);
            CREATE INDEX IF NOT EXISTS idx_orders_status
                ON orders(status);
            CREATE INDEX IF NOT EXISTS idx_order_items_order
                ON order_items(order_id);
        """)
        conn.commit()
        logger.info("DB schema ready")
    except Exception as e:
        conn.rollback()
        logger.warning(f"DB init skipped: {e}")
    finally:
        cur.close()
        conn.close()

# ── SQS ───────────────────────────────────────────────────────────────────────

def publish_event(event_type: str, payload: dict):
    if not SQS_QUEUE:
        return
    try:
        sqs = boto3.client("sqs", region_name=AWS_REGION)
        sqs.send_message(
            QueueUrl    = SQS_QUEUE,
            MessageBody = json.dumps({
                "event_type": event_type,
                "payload":    payload,
                "timestamp":  datetime.now(timezone.utc).isoformat(),
            })
        )
        logger.info(f"published event: {event_type}")
    except Exception as e:
        logger.error(f"SQS publish failed: {e}")

# ── App ───────────────────────────────────────────────────────────────────────

@asynccontextmanager
async def lifespan(app: FastAPI):
    init_db()
    yield

app = FastAPI(title="Order Service", version="1.0.0", lifespan=lifespan)

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

# ── Models ────────────────────────────────────────────────────────────────────

class OrderItem(BaseModel):
    product_id: str
    quantity:   int
    unit_price: float

class OrderCreate(BaseModel):
    customer_id:  str
    items:        list[OrderItem]
    currency:     Optional[str] = "GBP"
    notes:        Optional[str] = None

class OrderUpdate(BaseModel):
    status: Optional[str] = None
    notes:  Optional[str] = None

# ── Routes ────────────────────────────────────────────────────────────────────

@app.get("/health")
def health():
    try:
        conn = get_db()
        conn.cursor().execute("SELECT 1")
        conn.close()
        return {"status": "ok", "service": "order-service", "db": "ok"}
    except Exception as e:
        return Response(
            content    = json.dumps({"status": "degraded", "db": str(e)}),
            status_code = 503,
            media_type  = "application/json"
        )

@app.get("/metrics")
def metrics():
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)

@app.get("/orders")
def list_orders(
    status:      Optional[str] = None,
    customer_id: Optional[str] = None,
    limit:       int = 50,
    offset:      int = 0
):
    conn = get_db()
    cur  = conn.cursor()
    try:
        query  = "SELECT * FROM orders WHERE 1=1"
        params = []
        if status:
            query += " AND status = %s"
            params.append(status)
        if customer_id:
            query += " AND customer_id = %s"
            params.append(customer_id)
        query += " ORDER BY created_at DESC LIMIT %s OFFSET %s"
        params += [limit, offset]
        cur.execute(query, params)
        orders = [dict(r) for r in cur.fetchall()]
        for o in orders:
            o["id"]         = str(o["id"])
            o["customer_id"]= str(o["customer_id"])
            o["created_at"] = o["created_at"].isoformat()
            o["updated_at"] = o["updated_at"].isoformat()
            o["total_amount"]= float(o["total_amount"])
        return {"orders": orders, "count": len(orders)}
    finally:
        cur.close()
        conn.close()

@app.post("/orders", status_code=201)
def create_order(body: OrderCreate):
    conn = get_db()
    cur  = conn.cursor()
    try:
        total = sum(i.quantity * i.unit_price for i in body.items)
        cur.execute(
            """INSERT INTO orders (customer_id, total_amount, currency, notes)
               VALUES (%s, %s, %s, %s) RETURNING *""",
            (body.customer_id, total, body.currency, body.notes)
        )
        order = dict(cur.fetchone())

        for item in body.items:
            cur.execute(
                """INSERT INTO order_items
                   (order_id, product_id, quantity, unit_price)
                   VALUES (%s, %s, %s, %s)""",
                (order["id"], item.product_id, item.quantity, item.unit_price)
            )

        conn.commit()
        order["id"]          = str(order["id"])
        order["customer_id"] = str(order["customer_id"])
        order["created_at"]  = order["created_at"].isoformat()
        order["updated_at"]  = order["updated_at"].isoformat()
        order["total_amount"]= float(order["total_amount"])

        publish_event("order.created", {
            "order_id":    order["id"],
            "customer_id": order["customer_id"],
            "total":       order["total_amount"],
        })

        ORDERS_CREATED.inc()
        logger.info(f"order created: {order['id']}")
        return order

    except Exception as e:
        conn.rollback()
        raise HTTPException(500, str(e))
    finally:
        cur.close()
        conn.close()

@app.get("/orders/{order_id}")
def get_order(order_id: str):
    conn = get_db()
    cur  = conn.cursor()
    try:
        cur.execute("SELECT * FROM orders WHERE id = %s", (order_id,))
        order = cur.fetchone()
        if not order:
            raise HTTPException(404, "Order not found")
        order = dict(order)
        order["id"]          = str(order["id"])
        order["customer_id"] = str(order["customer_id"])
        order["created_at"]  = order["created_at"].isoformat()
        order["updated_at"]  = order["updated_at"].isoformat()
        order["total_amount"]= float(order["total_amount"])

        cur.execute(
            "SELECT * FROM order_items WHERE order_id = %s",
            (order_id,)
        )
        items = [dict(r) for r in cur.fetchall()]
        for i in items:
            i["id"]         = str(i["id"])
            i["order_id"]   = str(i["order_id"])
            i["product_id"] = str(i["product_id"])
            i["unit_price"] = float(i["unit_price"])
            i["created_at"] = i["created_at"].isoformat()
        order["items"] = items
        return order
    finally:
        cur.close()
        conn.close()

@app.patch("/orders/{order_id}")
def update_order(order_id: str, body: OrderUpdate):
    conn = get_db()
    cur  = conn.cursor()
    try:
        updates = {"updated_at": datetime.now(timezone.utc)}
        if body.status: updates["status"] = body.status
        if body.notes:  updates["notes"]  = body.notes

        set_clause = ", ".join(f"{k} = %s" for k in updates)
        values     = list(updates.values()) + [order_id]
        cur.execute(
            f"UPDATE orders SET {set_clause} WHERE id = %s RETURNING *",
            values
        )
        order = cur.fetchone()
        if not order:
            raise HTTPException(404, "Order not found")
        conn.commit()

        order = dict(order)
        order["id"]          = str(order["id"])
        order["customer_id"] = str(order["customer_id"])
        order["created_at"]  = order["created_at"].isoformat()
        order["updated_at"]  = order["updated_at"].isoformat()
        order["total_amount"]= float(order["total_amount"])

        publish_event(f"order.{body.status}", {
            "order_id": order_id,
            "status":   body.status,
        })

        if body.status == "cancelled":
            ORDERS_CANCELLED.inc()
        if body.status == "delivered":
            ORDERS_COMPLETED.inc()

        logger.info(f"order updated: {order_id} -> {body.status}")
        return order

    except HTTPException:
        raise
    except Exception as e:
        conn.rollback()
        raise HTTPException(500, str(e))
    finally:
        cur.close()
        conn.close()

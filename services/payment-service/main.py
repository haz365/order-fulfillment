import os
import json
import time
import logging
import boto3
from datetime import datetime, timezone
from contextlib import asynccontextmanager
from typing import Optional
from enum import Enum

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
            "service":   "payment-service",
            "message":   record.getMessage(),
        })

handler = logging.StreamHandler()
handler.setFormatter(JSONFormatter())
logging.basicConfig(level=logging.INFO, handlers=[handler])
logger = logging.getLogger("payment-service")

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
    "payment_requests_total", "Total requests",
    ["method", "endpoint", "status"]
)
REQUEST_LATENCY = Histogram(
    "payment_request_duration_seconds", "Request latency",
    ["method", "endpoint"],
    buckets=[0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5]
)
PAYMENTS_PROCESSED = Counter("payments_processed_total", "Payments processed", ["status"])
PAYMENT_AMOUNT     = Counter("payments_amount_total",    "Total payment amount processed")
REFUNDS_PROCESSED  = Counter("refunds_processed_total",  "Refunds processed")

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
            CREATE TABLE IF NOT EXISTS payments (
                id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                order_id       UUID NOT NULL,
                amount         NUMERIC(10,2) NOT NULL,
                currency       VARCHAR(3) NOT NULL DEFAULT 'GBP',
                status         VARCHAR(20) DEFAULT 'pending'
                                   CHECK (status IN (
                                     'pending','processing','completed',
                                     'failed','refunded','partially_refunded'
                                   )),
                payment_method VARCHAR(50) DEFAULT 'card',
                reference      VARCHAR(255),
                failure_reason TEXT,
                created_at     TIMESTAMPTZ DEFAULT NOW(),
                updated_at     TIMESTAMPTZ DEFAULT NOW()
            );

            CREATE TABLE IF NOT EXISTS ledger (
                id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                payment_id  UUID REFERENCES payments(id),
                order_id    UUID NOT NULL,
                type        VARCHAR(20) NOT NULL
                                CHECK (type IN ('charge','refund','adjustment')),
                amount      NUMERIC(10,2) NOT NULL,
                currency    VARCHAR(3) NOT NULL DEFAULT 'GBP',
                description TEXT,
                created_at  TIMESTAMPTZ DEFAULT NOW()
            );

            CREATE INDEX IF NOT EXISTS idx_payments_order
                ON payments(order_id);
            CREATE INDEX IF NOT EXISTS idx_payments_status
                ON payments(status);
            CREATE INDEX IF NOT EXISTS idx_ledger_order
                ON ledger(order_id);
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

app = FastAPI(title="Payment Service", version="1.0.0", lifespan=lifespan)

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

# ── Models ────────────────────────────────────────────────────────────────────

class PaymentCreate(BaseModel):
    order_id:       str
    amount:         float
    currency:       Optional[str] = "GBP"
    payment_method: Optional[str] = "card"
    reference:      Optional[str] = None

class RefundCreate(BaseModel):
    amount:      float
    description: Optional[str] = None

# ── Routes ────────────────────────────────────────────────────────────────────

@app.get("/health")
def health():
    try:
        conn = get_db()
        conn.cursor().execute("SELECT 1")
        conn.close()
        return {"status": "ok", "service": "payment-service", "db": "ok"}
    except Exception as e:
        return Response(
            content     = json.dumps({"status": "degraded", "db": str(e)}),
            status_code = 503,
            media_type  = "application/json"
        )

@app.get("/metrics")
def metrics():
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)

@app.get("/payments")
def list_payments(
    order_id: Optional[str] = None,
    status:   Optional[str] = None,
    limit:    int = 50,
    offset:   int = 0
):
    conn = get_db()
    cur  = conn.cursor()
    try:
        query  = "SELECT * FROM payments WHERE 1=1"
        params = []
        if order_id:
            query += " AND order_id = %s"
            params.append(order_id)
        if status:
            query += " AND status = %s"
            params.append(status)
        query += " ORDER BY created_at DESC LIMIT %s OFFSET %s"
        params += [limit, offset]
        cur.execute(query, params)
        payments = [dict(r) for r in cur.fetchall()]
        for p in payments:
            p["id"]         = str(p["id"])
            p["order_id"]   = str(p["order_id"])
            p["amount"]     = float(p["amount"])
            p["created_at"] = p["created_at"].isoformat()
            p["updated_at"] = p["updated_at"].isoformat()
        return {"payments": payments, "count": len(payments)}
    finally:
        cur.close()
        conn.close()

@app.post("/payments", status_code=201)
def create_payment(body: PaymentCreate):
    conn = get_db()
    cur  = conn.cursor()
    try:
        cur.execute(
            """INSERT INTO payments
               (order_id, amount, currency, payment_method, reference, status)
               VALUES (%s, %s, %s, %s, %s, 'processing') RETURNING *""",
            (body.order_id, body.amount, body.currency,
             body.payment_method, body.reference)
        )
        payment = dict(cur.fetchone())

        # Simulate payment processing
        payment["status"] = "completed"
        cur.execute(
            "UPDATE payments SET status='completed', updated_at=NOW() WHERE id=%s",
            (payment["id"],)
        )

        # Write to ledger
        cur.execute(
            """INSERT INTO ledger
               (payment_id, order_id, type, amount, currency, description)
               VALUES (%s, %s, 'charge', %s, %s, %s)""",
            (payment["id"], body.order_id, body.amount,
             body.currency, f"Payment for order {body.order_id}")
        )

        conn.commit()

        payment["id"]         = str(payment["id"])
        payment["order_id"]   = str(payment["order_id"])
        payment["amount"]     = float(payment["amount"])
        payment["created_at"] = payment["created_at"].isoformat()
        payment["updated_at"] = payment["updated_at"].isoformat()

        publish_event("payment.completed", {
            "payment_id": payment["id"],
            "order_id":   body.order_id,
            "amount":     body.amount,
            "currency":   body.currency,
        })

        PAYMENTS_PROCESSED.labels("completed").inc()
        PAYMENT_AMOUNT.inc(body.amount)
        logger.info(f"payment completed: {payment['id']}")
        return payment

    except Exception as e:
        conn.rollback()
        raise HTTPException(500, str(e))
    finally:
        cur.close()
        conn.close()

@app.get("/payments/{payment_id}")
def get_payment(payment_id: str):
    conn = get_db()
    cur  = conn.cursor()
    try:
        cur.execute("SELECT * FROM payments WHERE id = %s", (payment_id,))
        payment = cur.fetchone()
        if not payment:
            raise HTTPException(404, "Payment not found")
        payment = dict(payment)
        payment["id"]         = str(payment["id"])
        payment["order_id"]   = str(payment["order_id"])
        payment["amount"]     = float(payment["amount"])
        payment["created_at"] = payment["created_at"].isoformat()
        payment["updated_at"] = payment["updated_at"].isoformat()
        return payment
    finally:
        cur.close()
        conn.close()

@app.post("/payments/{payment_id}/refund", status_code=201)
def refund_payment(payment_id: str, body: RefundCreate):
    conn = get_db()
    cur  = conn.cursor()
    try:
        cur.execute(
            "SELECT * FROM payments WHERE id = %s FOR UPDATE",
            (payment_id,)
        )
        payment = cur.fetchone()
        if not payment:
            raise HTTPException(404, "Payment not found")
        if payment["status"] not in ["completed"]:
            raise HTTPException(400, f"Cannot refund payment with status {payment['status']}")
        if body.amount > float(payment["amount"]):
            raise HTTPException(400, "Refund amount exceeds payment amount")

        new_status = "refunded" if body.amount == float(payment["amount"]) else "partially_refunded"

        cur.execute(
            "UPDATE payments SET status=%s, updated_at=NOW() WHERE id=%s",
            (new_status, payment_id)
        )

        cur.execute(
            """INSERT INTO ledger
               (payment_id, order_id, type, amount, currency, description)
               VALUES (%s, %s, 'refund', %s, %s, %s)""",
            (payment_id, str(payment["order_id"]), body.amount,
             payment["currency"], body.description or f"Refund for payment {payment_id}")
        )

        conn.commit()

        publish_event("payment.refunded", {
            "payment_id": payment_id,
            "order_id":   str(payment["order_id"]),
            "amount":     body.amount,
        })

        REFUNDS_PROCESSED.inc()
        logger.info(f"payment refunded: {payment_id}")
        return {"payment_id": payment_id, "refund_amount": body.amount, "status": new_status}

    except HTTPException:
        raise
    except Exception as e:
        conn.rollback()
        raise HTTPException(500, str(e))
    finally:
        cur.close()
        conn.close()

@app.get("/payments/ledger/{order_id}")
def get_ledger(order_id: str):
    conn = get_db()
    cur  = conn.cursor()
    try:
        cur.execute(
            "SELECT * FROM ledger WHERE order_id = %s ORDER BY created_at DESC",
            (order_id,)
        )
        entries = [dict(r) for r in cur.fetchall()]
        for e in entries:
            e["id"]         = str(e["id"])
            e["payment_id"] = str(e["payment_id"])
            e["order_id"]   = str(e["order_id"])
            e["amount"]     = float(e["amount"])
            e["created_at"] = e["created_at"].isoformat()
        return {"ledger": entries, "count": len(entries)}
    finally:
        cur.close()
        conn.close()
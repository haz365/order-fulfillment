import os
import json
import time
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
            "service":   "shipping-service",
            "message":   record.getMessage(),
        })

handler = logging.StreamHandler()
handler.setFormatter(JSONFormatter())
logging.basicConfig(level=logging.INFO, handlers=[handler])
logger = logging.getLogger("shipping-service")

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
    "shipping_requests_total", "Total requests",
    ["method", "endpoint", "status"]
)
REQUEST_LATENCY = Histogram(
    "shipping_request_duration_seconds", "Request latency",
    ["method", "endpoint"],
    buckets=[0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5]
)
SHIPMENTS_CREATED   = Counter("shipments_created_total",   "Shipments created")
SHIPMENTS_DELIVERED = Counter("shipments_delivered_total", "Shipments delivered")

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
            CREATE TABLE IF NOT EXISTS shipments (
                id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                order_id        UUID NOT NULL,
                tracking_number VARCHAR(100) UNIQUE,
                carrier         VARCHAR(50) DEFAULT 'royal-mail',
                status          VARCHAR(20) DEFAULT 'pending'
                                    CHECK (status IN (
                                      'pending','dispatched','in_transit',
                                      'out_for_delivery','delivered','failed'
                                    )),
                address_line1   VARCHAR(255) NOT NULL,
                address_line2   VARCHAR(255),
                city            VARCHAR(100) NOT NULL,
                postcode        VARCHAR(20)  NOT NULL,
                country         VARCHAR(50)  DEFAULT 'GB',
                estimated_delivery DATE,
                delivered_at    TIMESTAMPTZ,
                created_at      TIMESTAMPTZ DEFAULT NOW(),
                updated_at      TIMESTAMPTZ DEFAULT NOW()
            );

            CREATE TABLE IF NOT EXISTS tracking_events (
                id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                shipment_id UUID REFERENCES shipments(id) ON DELETE CASCADE,
                status      VARCHAR(50) NOT NULL,
                location    VARCHAR(255),
                description TEXT,
                created_at  TIMESTAMPTZ DEFAULT NOW()
            );

            CREATE INDEX IF NOT EXISTS idx_shipments_order
                ON shipments(order_id);
            CREATE INDEX IF NOT EXISTS idx_shipments_tracking
                ON shipments(tracking_number);
            CREATE INDEX IF NOT EXISTS idx_tracking_shipment
                ON tracking_events(shipment_id);
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
    except Exception as e:
        logger.error(f"SQS publish failed: {e}")

# ── App ───────────────────────────────────────────────────────────────────────

@asynccontextmanager
async def lifespan(app: FastAPI):
    init_db()
    yield

app = FastAPI(title="Shipping Service", version="1.0.0", lifespan=lifespan)

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

class ShipmentCreate(BaseModel):
    order_id:      str
    address_line1: str
    address_line2: Optional[str] = None
    city:          str
    postcode:      str
    country:       Optional[str] = "GB"
    carrier:       Optional[str] = "royal-mail"

class TrackingUpdate(BaseModel):
    status:      str
    location:    Optional[str] = None
    description: Optional[str] = None

# ── Routes ────────────────────────────────────────────────────────────────────

@app.get("/health")
def health():
    try:
        conn = get_db()
        conn.cursor().execute("SELECT 1")
        conn.close()
        return {"status": "ok", "service": "shipping-service", "db": "ok"}
    except Exception as e:
        return Response(
            content     = json.dumps({"status": "degraded", "db": str(e)}),
            status_code = 503,
            media_type  = "application/json"
        )

@app.get("/metrics")
def metrics():
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)

@app.get("/shipping")
def list_shipments(
    order_id: Optional[str] = None,
    status:   Optional[str] = None,
    limit:    int = 50
):
    conn = get_db()
    cur  = conn.cursor()
    try:
        query  = "SELECT * FROM shipments WHERE 1=1"
        params = []
        if order_id:
            query += " AND order_id = %s"
            params.append(order_id)
        if status:
            query += " AND status = %s"
            params.append(status)
        query += " ORDER BY created_at DESC LIMIT %s"
        params.append(limit)
        cur.execute(query, params)
        shipments = [dict(r) for r in cur.fetchall()]
        for s in shipments:
            s["id"]         = str(s["id"])
            s["order_id"]   = str(s["order_id"])
            s["created_at"] = s["created_at"].isoformat()
            s["updated_at"] = s["updated_at"].isoformat()
            if s["delivered_at"]:
                s["delivered_at"] = s["delivered_at"].isoformat()
            if s["estimated_delivery"]:
                s["estimated_delivery"] = str(s["estimated_delivery"])
        return {"shipments": shipments, "count": len(shipments)}
    finally:
        cur.close()
        conn.close()

@app.post("/shipping", status_code=201)
def create_shipment(body: ShipmentCreate):
    import random
    import string
    tracking = "RM" + "".join(random.choices(string.ascii_uppercase + string.digits, k=10))

    conn = get_db()
    cur  = conn.cursor()
    try:
        from datetime import timedelta
        estimated = datetime.now(timezone.utc).date() + timedelta(days=3)

        cur.execute(
            """INSERT INTO shipments
               (order_id, tracking_number, carrier, address_line1,
                address_line2, city, postcode, country, estimated_delivery)
               VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s) RETURNING *""",
            (body.order_id, tracking, body.carrier, body.address_line1,
             body.address_line2, body.city, body.postcode,
             body.country, estimated)
        )
        shipment = dict(cur.fetchone())

        cur.execute(
            """INSERT INTO tracking_events
               (shipment_id, status, description)
               VALUES (%s, 'pending', 'Shipment created')""",
            (shipment["id"],)
        )

        conn.commit()

        shipment["id"]                 = str(shipment["id"])
        shipment["order_id"]           = str(shipment["order_id"])
        shipment["created_at"]         = shipment["created_at"].isoformat()
        shipment["updated_at"]         = shipment["updated_at"].isoformat()
        shipment["estimated_delivery"] = str(shipment["estimated_delivery"])

        publish_event("shipment.created", {
            "shipment_id":     shipment["id"],
            "order_id":        body.order_id,
            "tracking_number": tracking,
        })

        SHIPMENTS_CREATED.inc()
        logger.info(f"shipment created: {shipment['id']} tracking: {tracking}")
        return shipment

    except Exception as e:
        conn.rollback()
        raise HTTPException(500, str(e))
    finally:
        cur.close()
        conn.close()

@app.get("/shipping/{shipment_id}")
def get_shipment(shipment_id: str):
    conn = get_db()
    cur  = conn.cursor()
    try:
        cur.execute("SELECT * FROM shipments WHERE id = %s", (shipment_id,))
        shipment = cur.fetchone()
        if not shipment:
            raise HTTPException(404, "Shipment not found")
        shipment = dict(shipment)
        shipment["id"]       = str(shipment["id"])
        shipment["order_id"] = str(shipment["order_id"])
        shipment["created_at"] = shipment["created_at"].isoformat()
        shipment["updated_at"] = shipment["updated_at"].isoformat()
        if shipment["delivered_at"]:
            shipment["delivered_at"] = shipment["delivered_at"].isoformat()
        if shipment["estimated_delivery"]:
            shipment["estimated_delivery"] = str(shipment["estimated_delivery"])

        cur.execute(
            """SELECT * FROM tracking_events
               WHERE shipment_id = %s ORDER BY created_at DESC""",
            (shipment_id,)
        )
        events = [dict(r) for r in cur.fetchall()]
        for e in events:
            e["id"]          = str(e["id"])
            e["shipment_id"] = str(e["shipment_id"])
            e["created_at"]  = e["created_at"].isoformat()
        shipment["tracking_events"] = events
        return shipment
    finally:
        cur.close()
        conn.close()

@app.post("/shipping/{shipment_id}/track")
def add_tracking_event(shipment_id: str, body: TrackingUpdate):
    conn = get_db()
    cur  = conn.cursor()
    try:
        cur.execute(
            "SELECT id FROM shipments WHERE id = %s", (shipment_id,)
        )
        if not cur.fetchone():
            raise HTTPException(404, "Shipment not found")

        cur.execute(
            """UPDATE shipments SET status=%s, updated_at=NOW()
               WHERE id=%s""",
            (body.status, shipment_id)
        )

        if body.status == "delivered":
            cur.execute(
                "UPDATE shipments SET delivered_at=NOW() WHERE id=%s",
                (shipment_id,)
            )

        cur.execute(
            """INSERT INTO tracking_events
               (shipment_id, status, location, description)
               VALUES (%s,%s,%s,%s) RETURNING id""",
            (shipment_id, body.status, body.location, body.description)
        )
        event_id = str(cur.fetchone()["id"])
        conn.commit()

        if body.status == "shipped":
            publish_event("order.shipped", {"shipment_id": shipment_id})
        if body.status == "delivered":
            publish_event("order.delivered", {"shipment_id": shipment_id})
            SHIPMENTS_DELIVERED.inc()

        logger.info(f"tracking updated: {shipment_id} -> {body.status}")
        return {"event_id": event_id, "status": body.status}

    except HTTPException:
        raise
    except Exception as e:
        conn.rollback()
        raise HTTPException(500, str(e))
    finally:
        cur.close()
        conn.close()

@app.get("/shipping/track/{tracking_number}")
def track_by_number(tracking_number: str):
    conn = get_db()
    cur  = conn.cursor()
    try:
        cur.execute(
            "SELECT * FROM shipments WHERE tracking_number = %s",
            (tracking_number,)
        )
        shipment = cur.fetchone()
        if not shipment:
            raise HTTPException(404, "Tracking number not found")
        shipment = dict(shipment)
        shipment["id"]       = str(shipment["id"])
        shipment["order_id"] = str(shipment["order_id"])
        shipment["created_at"] = shipment["created_at"].isoformat()
        shipment["updated_at"] = shipment["updated_at"].isoformat()
        if shipment["estimated_delivery"]:
            shipment["estimated_delivery"] = str(shipment["estimated_delivery"])
        return shipment
    finally:
        cur.close()
        conn.close()
# ADR-007: SQS as event bus

## Status
Accepted

## Context
Services need to communicate asynchronously. order-service, payment-service and shipping-service publish events. worker and notification-service consume them.

## Decision
AWS SQS standard queue with DLQ and redrive policy (maxReceiveCount=5).

## Alternatives considered
- **SNS+SQS fanout** — one SNS topic, multiple SQS subscribers. Would allow notification-service and worker to subscribe independently. Rejected because our event volume is low and the added complexity of managing topic subscriptions isn't justified yet.
- **Kafka/MSK** — high throughput, event replay, consumer groups. Rejected because MSK starts at $200+/month and our event volume doesn't justify it. SQS handles our throughput easily.
- **EventBridge** — serverless, schema registry, event routing. Rejected because it adds latency and cost at low volume. SQS is simpler and cheaper for point-to-point messaging.
- **FIFO queue** — guaranteed ordering, exactly-once delivery. Rejected because our events are idempotent and ordering between different event types doesn't matter. Standard queue throughput is higher and cheaper.

## Consequences
- Standard queue means at-least-once delivery — consumers must be idempotent
- DLQ captures failed messages after 5 retries
- CloudWatch alarms on DLQ depth and message age
- Single queue means all consumers see all events — worker and notification-service both filter by event type
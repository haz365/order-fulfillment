package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/sqs"
	_ "github.com/lib/pq"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

// ── Config ────────────────────────────────────────────────────────────────────

type Config struct {
	DBHost     string
	DBPort     string
	DBName     string
	DBUser     string
	DBPassword string
	DBSSLMode  string
	Port       string
	SQSQueue   string
	AWSRegion  string
}

func loadConfig() Config {
	return Config{
		DBHost:     mustEnv("DB_HOST"),
		DBPort:     envOr("DB_PORT", "5432"),
		DBName:     mustEnv("DB_NAME"),
		DBUser:     mustEnv("DB_USER"),
		DBPassword: mustEnv("DB_PASSWORD"),
		DBSSLMode:  envOr("DB_SSL_MODE", "require"),
		Port:       envOr("PORT", "8004"),
		SQSQueue:   os.Getenv("SQS_QUEUE_URL"),
		AWSRegion:  envOr("AWS_REGION", "eu-west-2"),
	}
}

func mustEnv(k string) string {
	v := os.Getenv(k)
	if v == "" {
		slog.Error("missing required env var", "key", k)
		os.Exit(1)
	}
	return v
}

func envOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

// ── Metrics ───────────────────────────────────────────────────────────────────

var (
	notificationsSent = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "notifications_sent_total",
		Help: "Total notifications sent",
	}, []string{"type", "channel"})

	notificationsFailed = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "notifications_failed_total",
		Help: "Total notifications failed",
	}, []string{"type", "channel"})

	messagesProcessed = prometheus.NewCounter(prometheus.CounterOpts{
		Name: "notification_messages_processed_total",
		Help: "Total SQS messages processed",
	})
)

func registerMetrics() {
	prometheus.MustRegister(
		notificationsSent,
		notificationsFailed,
		messagesProcessed,
	)
}

// ── DB ────────────────────────────────────────────────────────────────────────

func connectDB(cfg Config) (*sql.DB, error) {
	dsn := fmt.Sprintf(
		"host=%s port=%s dbname=%s user=%s password=%s sslmode=%s",
		cfg.DBHost, cfg.DBPort, cfg.DBName,
		cfg.DBUser, cfg.DBPassword, cfg.DBSSLMode,
	)
	db, err := sql.Open("postgres", dsn)
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(5)
	db.SetMaxIdleConns(2)
	db.SetConnMaxLifetime(5 * time.Minute)
	return db, nil
}

func initDB(db *sql.DB, log *slog.Logger) {
	_, err := db.Exec(`
		CREATE TABLE IF NOT EXISTS notifications (
			id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
			order_id   UUID,
			customer_id UUID,
			type       VARCHAR(50) NOT NULL,
			channel    VARCHAR(20) NOT NULL CHECK (channel IN ('email','sms','push')),
			recipient  VARCHAR(255) NOT NULL,
			subject    VARCHAR(255),
			body       TEXT NOT NULL,
			status     VARCHAR(20) DEFAULT 'pending'
			               CHECK (status IN ('pending','sent','failed')),
			error      TEXT,
			created_at TIMESTAMPTZ DEFAULT NOW(),
			sent_at    TIMESTAMPTZ
		);

		CREATE INDEX IF NOT EXISTS idx_notifications_order
			ON notifications(order_id);
		CREATE INDEX IF NOT EXISTS idx_notifications_status
			ON notifications(status);
	`)
	if err != nil {
		log.Warn("DB init skipped", "err", err)
		return
	}
	log.Info("DB schema ready")
}

// ── Models ────────────────────────────────────────────────────────────────────

type SQSEvent struct {
	EventType string                 `json:"event_type"`
	Payload   map[string]interface{} `json:"payload"`
	Timestamp string                 `json:"timestamp"`
}

type NotificationRequest struct {
	OrderID    string `json:"order_id"`
	CustomerID string `json:"customer_id"`
	Type       string `json:"type"`
	Channel    string `json:"channel"`
	Recipient  string `json:"recipient"`
	Subject    string `json:"subject"`
	Body       string `json:"body"`
}

// ── Notification logic ────────────────────────────────────────────────────────

func sendNotification(db *sql.DB, log *slog.Logger, n NotificationRequest) error {
	// In production this would call SES/SNS
	// For now we simulate and record
	log.Info("sending notification",
		"type", n.Type,
		"channel", n.Channel,
		"recipient", n.Recipient,
	)

	var id string
	err := db.QueryRow(`
		INSERT INTO notifications
		(order_id, customer_id, type, channel, recipient, subject, body, status, sent_at)
		VALUES ($1, $2, $3, $4, $5, $6, $7, 'sent', NOW())
		RETURNING id
	`, n.OrderID, n.CustomerID, n.Type, n.Channel,
		n.Recipient, n.Subject, n.Body).Scan(&id)

	if err != nil {
		notificationsFailed.WithLabelValues(n.Type, n.Channel).Inc()
		return err
	}

	notificationsSent.WithLabelValues(n.Type, n.Channel).Inc()
	log.Info("notification sent", "id", id, "type", n.Type)
	return nil
}

func handleEvent(db *sql.DB, log *slog.Logger, event SQSEvent) {
	payload := event.Payload
	orderID, _ := payload["order_id"].(string)

	switch event.EventType {
	case "order.created":
		sendNotification(db, log, NotificationRequest{
			OrderID:   orderID,
			Type:      "order_confirmation",
			Channel:   "email",
			Recipient: "customer@example.com",
			Subject:   "Order Confirmed",
			Body:      fmt.Sprintf("Your order %s has been confirmed.", orderID),
		})

	case "payment.completed":
		sendNotification(db, log, NotificationRequest{
			OrderID:   orderID,
			Type:      "payment_receipt",
			Channel:   "email",
			Recipient: "customer@example.com",
			Subject:   "Payment Received",
			Body:      fmt.Sprintf("Payment received for order %s.", orderID),
		})

	case "order.shipped":
		sendNotification(db, log, NotificationRequest{
			OrderID:   orderID,
			Type:      "shipping_update",
			Channel:   "email",
			Recipient: "customer@example.com",
			Subject:   "Your Order Has Shipped",
			Body:      fmt.Sprintf("Order %s has been shipped.", orderID),
		})

	case "order.delivered":
		sendNotification(db, log, NotificationRequest{
			OrderID:   orderID,
			Type:      "delivery_confirmation",
			Channel:   "email",
			Recipient: "customer@example.com",
			Subject:   "Order Delivered",
			Body:      fmt.Sprintf("Order %s has been delivered.", orderID),
		})

	default:
		log.Info("unhandled event", "type", event.EventType)
	}

	messagesProcessed.Inc()
}

// ── SQS Consumer ─────────────────────────────────────────────────────────────

func consumeSQS(cfg Config, db *sql.DB, log *slog.Logger) {
	if cfg.SQSQueue == "" {
		log.Warn("SQS_QUEUE_URL not set - skipping consumer")
		return
	}

	customResolver := aws.EndpointResolverWithOptionsFunc(
		func(service, region string, options ...interface{}) (aws.Endpoint, error) {
			endpoint := os.Getenv("AWS_ENDPOINT_URL")
			if endpoint != "" {
				return aws.Endpoint{
					URL:           endpoint,
					SigningRegion: region,
				}, nil
			}
			return aws.Endpoint{}, &aws.EndpointNotFoundError{}
		},
	)

	awsCfg, err := config.LoadDefaultConfig(
		context.Background(),
		config.WithRegion(cfg.AWSRegion),
		config.WithEndpointResolverWithOptions(customResolver),
	)
	if err != nil {
		log.Error("AWS config failed", "err", err)
		return
	}

	client := sqs.NewFromConfig(awsCfg)
	log.Info("SQS consumer started", "queue", cfg.SQSQueue)

	for {
		result, err := client.ReceiveMessage(context.Background(), &sqs.ReceiveMessageInput{
			QueueUrl:            &cfg.SQSQueue,
			MaxNumberOfMessages: 10,
			WaitTimeSeconds:     20,
		})
		if err != nil {
			log.Error("SQS receive failed", "err", err)
			time.Sleep(5 * time.Second)
			continue
		}

		for _, msg := range result.Messages {
			var event SQSEvent
			if err := json.Unmarshal([]byte(*msg.Body), &event); err != nil {
				log.Error("failed to parse event", "err", err)
				client.DeleteMessage(context.Background(), &sqs.DeleteMessageInput{
					QueueUrl:      &cfg.SQSQueue,
					ReceiptHandle: msg.ReceiptHandle,
				})
				continue
			}

			handleEvent(db, log, event)

			client.DeleteMessage(context.Background(), &sqs.DeleteMessageInput{
				QueueUrl:      &cfg.SQSQueue,
				ReceiptHandle: msg.ReceiptHandle,
			})
		}
	}
}

// ── HTTP Server ───────────────────────────────────────────────────────────────

type Server struct {
	db  *sql.DB
	log *slog.Logger
}

func (s *Server) health(w http.ResponseWriter, r *http.Request) {
	if err := s.db.Ping(); err != nil {
		w.WriteHeader(503)
		json.NewEncoder(w).Encode(map[string]string{"status": "degraded"})
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{
		"status": "ok", "service": "notification-service",
	})
}

func (s *Server) listNotifications(w http.ResponseWriter, r *http.Request) {
	rows, err := s.db.Query(`
		SELECT id, order_id, customer_id, type, channel,
		       recipient, subject, status, created_at
		FROM notifications
		ORDER BY created_at DESC
		LIMIT 100
	`)
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	defer rows.Close()

	type Row struct {
		ID         string  `json:"id"`
		OrderID    *string `json:"order_id"`
		CustomerID *string `json:"customer_id"`
		Type       string  `json:"type"`
		Channel    string  `json:"channel"`
		Recipient  string  `json:"recipient"`
		Subject    *string `json:"subject"`
		Status     string  `json:"status"`
		CreatedAt  string  `json:"created_at"`
	}

	var results []Row
	for rows.Next() {
		var row Row
		var createdAt time.Time
		rows.Scan(
			&row.ID, &row.OrderID, &row.CustomerID,
			&row.Type, &row.Channel, &row.Recipient,
			&row.Subject, &row.Status, &createdAt,
		)
		row.CreatedAt = createdAt.Format(time.RFC3339)
		results = append(results, row)
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"notifications": results,
		"count":         len(results),
	})
}

// ── Main ──────────────────────────────────────────────────────────────────────

func main() {
	log := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	cfg := loadConfig()
	registerMetrics()

	db, err := connectDB(cfg)
	if err != nil {
		log.Error("DB connect failed", "err", err)
		os.Exit(1)
	}
	defer db.Close()

	for i := 0; i < 10; i++ {
		if err := db.Ping(); err == nil {
			break
		}
		log.Info("waiting for DB...", "attempt", i+1)
		time.Sleep(2 * time.Second)
	}

	initDB(db, log)

	go consumeSQS(cfg, db, log)

	srv := &Server{db: db, log: log}
	mux := http.NewServeMux()
	mux.HandleFunc("/health", srv.health)
	mux.Handle("/metrics",    promhttp.Handler())
	mux.HandleFunc("GET /notifications", srv.listNotifications)

	log.Info("notification-service listening", "port", cfg.Port)
	http.ListenAndServe(":"+cfg.Port, mux)
}
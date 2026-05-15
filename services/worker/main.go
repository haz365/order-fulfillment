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
	SQSDLQueue string
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
		Port:       envOr("PORT", "8006"),
		SQSQueue:   mustEnv("SQS_QUEUE_URL"),
		SQSDLQueue: os.Getenv("SQS_DLQ_URL"),
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
	messagesProcessed = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "worker_messages_processed_total",
		Help: "Messages processed by event type",
	}, []string{"event_type"})

	messagesFailed = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "worker_messages_failed_total",
		Help: "Messages failed by event type",
	}, []string{"event_type"})

	processingDuration = prometheus.NewHistogramVec(prometheus.HistogramOpts{
		Name:    "worker_processing_duration_seconds",
		Help:    "Message processing duration",
		Buckets: []float64{0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1, 5},
	}, []string{"event_type"})

	queueDepth = prometheus.NewGauge(prometheus.GaugeOpts{
		Name: "worker_queue_depth",
		Help: "Approximate SQS queue depth",
	})

	inflightMessages = prometheus.NewGauge(prometheus.GaugeOpts{
		Name: "worker_inflight_messages",
		Help: "Messages currently being processed",
	})
)

func registerMetrics() {
	prometheus.MustRegister(
		messagesProcessed,
		messagesFailed,
		processingDuration,
		queueDepth,
		inflightMessages,
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
	db.SetMaxOpenConns(10)
	db.SetMaxIdleConns(5)
	db.SetConnMaxLifetime(5 * time.Minute)
	return db, nil
}

func initDB(db *sql.DB, log *slog.Logger) {
	_, err := db.Exec(`
		CREATE TABLE IF NOT EXISTS processed_events (
			id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
			event_type VARCHAR(100) NOT NULL,
			payload    JSONB,
			processed_at TIMESTAMPTZ DEFAULT NOW()
		);

		CREATE TABLE IF NOT EXISTS event_errors (
			id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
			event_type VARCHAR(100),
			payload    TEXT,
			error      TEXT,
			created_at TIMESTAMPTZ DEFAULT NOW()
		);

		CREATE INDEX IF NOT EXISTS idx_processed_events_type
			ON processed_events(event_type);
		CREATE INDEX IF NOT EXISTS idx_processed_events_at
			ON processed_events(processed_at);
	`)
	if err != nil {
		log.Warn("DB init skipped", "err", err)
		return
	}
	log.Info("DB schema ready")
}

// ── Event handlers ────────────────────────────────────────────────────────────

type Event struct {
	EventType string                 `json:"event_type"`
	Payload   map[string]interface{} `json:"payload"`
	Timestamp string                 `json:"timestamp"`
}

func handleEvent(db *sql.DB, log *slog.Logger, event Event) error {
	start := time.Now()
	defer func() {
		processingDuration.WithLabelValues(event.EventType).Observe(
			time.Since(start).Seconds(),
		)
	}()

	log.Info("processing event", "type", event.EventType)

	payloadJSON, _ := json.Marshal(event.Payload)

	switch event.EventType {
	case "order.created":
		log.Info("order created - triggering inventory check",
			"order_id", event.Payload["order_id"])

	case "order.confirmed":
		log.Info("order confirmed - ready for payment",
			"order_id", event.Payload["order_id"])

	case "payment.completed":
		log.Info("payment completed - triggering fulfillment",
			"order_id", event.Payload["order_id"],
			"amount",   event.Payload["amount"])

	case "order.shipped":
		log.Info("order shipped - notifying customer",
			"shipment_id", event.Payload["shipment_id"])

	case "order.delivered":
		log.Info("order delivered - closing order",
			"shipment_id", event.Payload["shipment_id"])

	case "order.cancelled":
		log.Info("order cancelled - releasing inventory",
			"order_id", event.Payload["order_id"])

	case "payment.refunded":
		log.Info("payment refunded",
			"payment_id", event.Payload["payment_id"],
			"amount",     event.Payload["amount"])

	case "shipment.created":
		log.Info("shipment created",
			"shipment_id",     event.Payload["shipment_id"],
			"tracking_number", event.Payload["tracking_number"])

	default:
		log.Warn("unhandled event type", "type", event.EventType)
	}

	// Record processed event
	_, err := db.Exec(`
		INSERT INTO processed_events (event_type, payload)
		VALUES ($1, $2)
	`, event.EventType, string(payloadJSON))

	if err != nil {
		return fmt.Errorf("failed to record event: %w", err)
	}

	messagesProcessed.WithLabelValues(event.EventType).Inc()
	return nil
}

// ── SQS Consumer ─────────────────────────────────────────────────────────────

func consumeSQS(cfg Config, db *sql.DB, log *slog.Logger) {
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
		os.Exit(1)
	}

	client := sqs.NewFromConfig(awsCfg)
	log.Info("worker started", "queue", cfg.SQSQueue)

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

		inflightMessages.Set(float64(len(result.Messages)))

		for _, msg := range result.Messages {
			var event Event
			if err := json.Unmarshal([]byte(*msg.Body), &event); err != nil {
				log.Error("parse failed", "err", err)
				messagesFailed.WithLabelValues("unknown").Inc()
				client.DeleteMessage(context.Background(), &sqs.DeleteMessageInput{
					QueueUrl:      &cfg.SQSQueue,
					ReceiptHandle: msg.ReceiptHandle,
				})
				continue
			}

			if err := handleEvent(db, log, event); err != nil {
				log.Error("event handler failed",
					"type", event.EventType, "err", err)
				messagesFailed.WithLabelValues(event.EventType).Inc()
				db.Exec(`
					INSERT INTO event_errors (event_type, payload, error)
					VALUES ($1, $2, $3)
				`, event.EventType, *msg.Body, err.Error())
				continue
			}

			client.DeleteMessage(context.Background(), &sqs.DeleteMessageInput{
				QueueUrl:      &cfg.SQSQueue,
				ReceiptHandle: msg.ReceiptHandle,
			})
		}

		inflightMessages.Set(0)
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
		json.NewEncoder(w).Encode(map[string]string{
			"status": "degraded", "db": err.Error(),
		})
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{
		"status": "ok", "service": "worker",
	})
}

func (s *Server) stats(w http.ResponseWriter, r *http.Request) {
	rows, err := s.db.Query(`
		SELECT event_type, COUNT(*) as count
		FROM processed_events
		WHERE processed_at > NOW() - INTERVAL '24 hours'
		GROUP BY event_type
		ORDER BY count DESC
	`)
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	defer rows.Close()

	type Stat struct {
		EventType string `json:"event_type"`
		Count     int    `json:"count"`
	}

	var stats []Stat
	for rows.Next() {
		var s Stat
		rows.Scan(&s.EventType, &s.Count)
		stats = append(stats, s)
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"stats":  stats,
		"period": "24h",
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
	mux.HandleFunc("/stats",  srv.stats)
	mux.Handle("/metrics",    promhttp.Handler())

	log.Info("worker HTTP server listening", "port", cfg.Port)
	http.ListenAndServe(":"+cfg.Port, mux)
}
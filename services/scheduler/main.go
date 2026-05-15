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
		Port:       envOr("PORT", "8007"),
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
	jobsRun = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "scheduler_jobs_run_total",
		Help: "Total scheduler jobs run",
	}, []string{"job"})

	jobDuration = prometheus.NewHistogramVec(prometheus.HistogramOpts{
		Name:    "scheduler_job_duration_seconds",
		Help:    "Scheduler job duration",
		Buckets: []float64{0.01, 0.05, 0.1, 0.5, 1, 5, 10},
	}, []string{"job"})

	expiredOrders    = prometheus.NewCounter(prometheus.CounterOpts{
		Name: "scheduler_expired_orders_total",
		Help: "Orders expired by scheduler",
	})

	abandonedOrders = prometheus.NewCounter(prometheus.CounterOpts{
		Name: "scheduler_abandoned_orders_total",
		Help: "Abandoned orders detected",
	})

	retriesTriggered = prometheus.NewCounter(prometheus.CounterOpts{
		Name: "scheduler_retries_triggered_total",
		Help: "Payment retries triggered",
	})
)

func registerMetrics() {
	prometheus.MustRegister(
		jobsRun,
		jobDuration,
		expiredOrders,
		abandonedOrders,
		retriesTriggered,
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
		CREATE TABLE IF NOT EXISTS scheduler_runs (
			id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
			job_name   VARCHAR(100) NOT NULL,
			status     VARCHAR(20)  NOT NULL DEFAULT 'running',
			records    INT          DEFAULT 0,
			error      TEXT,
			started_at TIMESTAMPTZ  DEFAULT NOW(),
			ended_at   TIMESTAMPTZ
		);

		CREATE INDEX IF NOT EXISTS idx_scheduler_runs_job
			ON scheduler_runs(job_name);
		CREATE INDEX IF NOT EXISTS idx_scheduler_runs_started
			ON scheduler_runs(started_at);
	`)
	if err != nil {
		log.Warn("DB init skipped", "err", err)
		return
	}
	log.Info("DB schema ready")
}

// ── SQS ───────────────────────────────────────────────────────────────────────

func publishEvent(cfg Config, log *slog.Logger, eventType string, payload map[string]interface{}) {
	if cfg.SQSQueue == "" {
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
	body, _ := json.Marshal(map[string]interface{}{
		"event_type": eventType,
		"payload":    payload,
		"timestamp":  time.Now().UTC().Format(time.RFC3339),
	})

	bodyStr := string(body)
	_, err = client.SendMessage(context.Background(), &sqs.SendMessageInput{
		QueueUrl:    &cfg.SQSQueue,
		MessageBody: &bodyStr,
	})
	if err != nil {
		log.Error("SQS publish failed", "err", err)
	}
}

// ── Jobs ──────────────────────────────────────────────────────────────────────

func runJob(db *sql.DB, log *slog.Logger, jobName string, fn func() (int, error)) {
	start := time.Now()
	log.Info("job started", "job", jobName)

	var runID string
	db.QueryRow(`
		INSERT INTO scheduler_runs (job_name) VALUES ($1) RETURNING id
	`, jobName).Scan(&runID)

	records, err := fn()

	duration := time.Since(start).Seconds()
	jobDuration.WithLabelValues(jobName).Observe(duration)
	jobsRun.WithLabelValues(jobName).Inc()

	if err != nil {
		log.Error("job failed", "job", jobName, "err", err, "duration", duration)
		db.Exec(`
			UPDATE scheduler_runs
			SET status='failed', error=$1, ended_at=NOW()
			WHERE id=$2
		`, err.Error(), runID)
		return
	}

	log.Info("job complete", "job", jobName, "records", records, "duration", duration)
	db.Exec(`
		UPDATE scheduler_runs
		SET status='completed', records=$1, ended_at=NOW()
		WHERE id=$2
	`, records, runID)
}

// expireOrders cancels orders that have been pending for too long
func expireOrders(db *sql.DB, cfg Config, log *slog.Logger) (int, error) {
	rows, err := db.Query(`
		UPDATE orders
		SET status = 'cancelled', updated_at = NOW()
		WHERE status = 'pending'
		AND created_at < NOW() - INTERVAL '30 minutes'
		RETURNING id
	`)
	if err != nil {
		return 0, err
	}
	defer rows.Close()

	count := 0
	for rows.Next() {
		var orderID string
		rows.Scan(&orderID)
		publishEvent(cfg, log, "order.expired", map[string]interface{}{
			"order_id": orderID,
			"reason":   "payment_timeout",
		})
		count++
	}

	expiredOrders.Add(float64(count))
	return count, nil
}

// detectAbandoned flags orders stuck in processing
func detectAbandoned(db *sql.DB, cfg Config, log *slog.Logger) (int, error) {
	rows, err := db.Query(`
		SELECT id FROM orders
		WHERE status = 'confirmed'
		AND updated_at < NOW() - INTERVAL '1 hour'
	`)
	if err != nil {
		return 0, err
	}
	defer rows.Close()

	count := 0
	for rows.Next() {
		var orderID string
		rows.Scan(&orderID)
		publishEvent(cfg, log, "order.abandoned", map[string]interface{}{
			"order_id": orderID,
			"reason":   "stuck_in_processing",
		})
		count++
	}

	abandonedOrders.Add(float64(count))
	return count, nil
}

// retryFailedPayments retries recent failed payments
func retryFailedPayments(db *sql.DB, cfg Config, log *slog.Logger) (int, error) {
	rows, err := db.Query(`
		SELECT id, order_id, amount, currency
		FROM payments
		WHERE status = 'failed'
		AND created_at > NOW() - INTERVAL '24 hours'
		AND created_at < NOW() - INTERVAL '5 minutes'
	`)
	if err != nil {
		return 0, err
	}
	defer rows.Close()

	count := 0
	for rows.Next() {
		var id, orderID, currency string
		var amount float64
		rows.Scan(&id, &orderID, &amount, &currency)
		publishEvent(cfg, log, "payment.retry", map[string]interface{}{
			"payment_id": id,
			"order_id":   orderID,
			"amount":     amount,
			"currency":   currency,
		})
		count++
	}

	retriesTriggered.Add(float64(count))
	return count, nil
}

// cleanupOldRuns removes old scheduler run records
func cleanupOldRuns(db *sql.DB) (int, error) {
	result, err := db.Exec(`
		DELETE FROM scheduler_runs
		WHERE started_at < NOW() - INTERVAL '7 days'
	`)
	if err != nil {
		return 0, err
	}
	n, _ := result.RowsAffected()
	return int(n), nil
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
		"status": "ok", "service": "scheduler",
	})
}

func (s *Server) recentRuns(w http.ResponseWriter, r *http.Request) {
	rows, err := s.db.Query(`
		SELECT job_name, status, records, error, started_at, ended_at
		FROM scheduler_runs
		ORDER BY started_at DESC
		LIMIT 50
	`)
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	defer rows.Close()

	type Run struct {
		JobName   string  `json:"job_name"`
		Status    string  `json:"status"`
		Records   int     `json:"records"`
		Error     *string `json:"error"`
		StartedAt string  `json:"started_at"`
		EndedAt   *string `json:"ended_at"`
	}

	var runs []Run
	for rows.Next() {
		var run Run
		var startedAt time.Time
		var endedAt *time.Time
		rows.Scan(
			&run.JobName, &run.Status, &run.Records,
			&run.Error, &startedAt, &endedAt,
		)
		run.StartedAt = startedAt.Format(time.RFC3339)
		if endedAt != nil {
			s := endedAt.Format(time.RFC3339)
			run.EndedAt = &s
		}
		runs = append(runs, run)
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"runs":  runs,
		"count": len(runs),
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

	// Start scheduler loop
	go func() {
		ticker := time.NewTicker(1 * time.Minute)
		defer ticker.Stop()

		// Run immediately on start
		runJob(db, log, "expire_orders",      func() (int, error) { return expireOrders(db, cfg, log) })
		runJob(db, log, "detect_abandoned",   func() (int, error) { return detectAbandoned(db, cfg, log) })
		runJob(db, log, "retry_payments",     func() (int, error) { return retryFailedPayments(db, cfg, log) })
		runJob(db, log, "cleanup_runs",       func() (int, error) { return cleanupOldRuns(db) })

		for range ticker.C {
			runJob(db, log, "expire_orders",    func() (int, error) { return expireOrders(db, cfg, log) })
			runJob(db, log, "detect_abandoned", func() (int, error) { return detectAbandoned(db, cfg, log) })
			runJob(db, log, "retry_payments",   func() (int, error) { return retryFailedPayments(db, cfg, log) })
			runJob(db, log, "cleanup_runs",     func() (int, error) { return cleanupOldRuns(db) })
		}
	}()

	srv := &Server{db: db, log: log}
	mux := http.NewServeMux()
	mux.HandleFunc("/health",     srv.health)
	mux.HandleFunc("/runs",       srv.recentRuns)
	mux.Handle("/metrics",        promhttp.Handler())

	log.Info("scheduler listening", "port", cfg.Port)
	http.ListenAndServe(":"+cfg.Port, mux)
}
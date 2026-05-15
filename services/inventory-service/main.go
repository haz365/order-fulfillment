package main

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"time"

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
}

func loadConfig() Config {
	return Config{
		DBHost:     mustEnv("DB_HOST"),
		DBPort:     envOr("DB_PORT", "5432"),
		DBName:     mustEnv("DB_NAME"),
		DBUser:     mustEnv("DB_USER"),
		DBPassword: mustEnv("DB_PASSWORD"),
		DBSSLMode:  envOr("DB_SSL_MODE", "require"),
		Port:       envOr("PORT", "8002"),
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
	requestCount = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "inventory_requests_total",
		Help: "Total requests",
	}, []string{"method", "path", "status"})

	requestLatency = prometheus.NewHistogramVec(prometheus.HistogramOpts{
		Name:    "inventory_request_duration_seconds",
		Help:    "Request latency",
		Buckets: []float64{0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5},
	}, []string{"method", "path"})

	stockReservations = prometheus.NewCounter(prometheus.CounterOpts{
		Name: "inventory_reservations_total",
		Help: "Total stock reservations",
	})

	stockReleases = prometheus.NewCounter(prometheus.CounterOpts{
		Name: "inventory_releases_total",
		Help: "Total stock releases",
	})

	lowStockItems = prometheus.NewGauge(prometheus.GaugeOpts{
		Name: "inventory_low_stock_items",
		Help: "Number of items with low stock",
	})
)

func registerMetrics() {
	prometheus.MustRegister(
		requestCount,
		requestLatency,
		stockReservations,
		stockReleases,
		lowStockItems,
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
		CREATE TABLE IF NOT EXISTS products (
			id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
			sku          VARCHAR(100) UNIQUE NOT NULL,
			name         VARCHAR(255) NOT NULL,
			description  TEXT,
			stock        INT NOT NULL DEFAULT 0 CHECK (stock >= 0),
			reserved     INT NOT NULL DEFAULT 0 CHECK (reserved >= 0),
			low_stock_threshold INT NOT NULL DEFAULT 10,
			created_at   TIMESTAMPTZ DEFAULT NOW(),
			updated_at   TIMESTAMPTZ DEFAULT NOW()
		);

		CREATE TABLE IF NOT EXISTS reservations (
			id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
			product_id UUID REFERENCES products(id),
			order_id   UUID NOT NULL,
			quantity   INT  NOT NULL CHECK (quantity > 0),
			status     VARCHAR(20) DEFAULT 'active'
			               CHECK (status IN ('active','released','fulfilled')),
			created_at TIMESTAMPTZ DEFAULT NOW()
		);

		CREATE INDEX IF NOT EXISTS idx_products_sku
			ON products(sku);
		CREATE INDEX IF NOT EXISTS idx_reservations_order
			ON reservations(order_id);
	`)
	if err != nil {
		log.Warn("DB init skipped", "err", err)
		return
	}
	log.Info("DB schema ready")
}

// ── Models ────────────────────────────────────────────────────────────────────

type Product struct {
	ID                UUID      `json:"id"`
	SKU               string    `json:"sku"`
	Name              string    `json:"name"`
	Description       string    `json:"description"`
	Stock             int       `json:"stock"`
	Reserved          int       `json:"reserved"`
	Available         int       `json:"available"`
	LowStockThreshold int       `json:"low_stock_threshold"`
	CreatedAt         time.Time `json:"created_at"`
	UpdatedAt         time.Time `json:"updated_at"`
}

type UUID = string

type ProductCreate struct {
	SKU               string `json:"sku"`
	Name              string `json:"name"`
	Description       string `json:"description"`
	Stock             int    `json:"stock"`
	LowStockThreshold int    `json:"low_stock_threshold"`
}

type ReserveRequest struct {
	OrderID  string `json:"order_id"`
	Quantity int    `json:"quantity"`
}

// ── Handlers ──────────────────────────────────────────────────────────────────

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
		"status": "ok", "service": "inventory-service",
	})
}

func (s *Server) listProducts(w http.ResponseWriter, r *http.Request) {
	rows, err := s.db.Query(`
		SELECT id, sku, name, description, stock, reserved,
		       stock - reserved AS available,
		       low_stock_threshold, created_at, updated_at
		FROM products ORDER BY created_at DESC
	`)
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	defer rows.Close()

	products := []Product{}
	for rows.Next() {
		var p Product
		rows.Scan(
			&p.ID, &p.SKU, &p.Name, &p.Description,
			&p.Stock, &p.Reserved, &p.Available,
			&p.LowStockThreshold, &p.CreatedAt, &p.UpdatedAt,
		)
		products = append(products, p)
	}

	// Update low stock metric
	count := 0
	for _, p := range products {
		if p.Available <= p.LowStockThreshold {
			count++
		}
	}
	lowStockItems.Set(float64(count))

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"products": products,
		"count":    len(products),
	})
}

func (s *Server) createProduct(w http.ResponseWriter, r *http.Request) {
	var body ProductCreate
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		http.Error(w, err.Error(), 400)
		return
	}

	threshold := body.LowStockThreshold
	if threshold == 0 {
		threshold = 10
	}

	var p Product
	err := s.db.QueryRow(`
		INSERT INTO products (sku, name, description, stock, low_stock_threshold)
		VALUES ($1, $2, $3, $4, $5)
		RETURNING id, sku, name, description, stock, reserved,
		          stock - reserved AS available,
		          low_stock_threshold, created_at, updated_at
	`, body.SKU, body.Name, body.Description, body.Stock, threshold).Scan(
		&p.ID, &p.SKU, &p.Name, &p.Description,
		&p.Stock, &p.Reserved, &p.Available,
		&p.LowStockThreshold, &p.CreatedAt, &p.UpdatedAt,
	)
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}

	s.log.Info("product created", "id", p.ID, "sku", p.SKU)
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(201)
	json.NewEncoder(w).Encode(p)
}

func (s *Server) reserveStock(w http.ResponseWriter, r *http.Request) {
	productID := r.PathValue("id")

	var body ReserveRequest
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		http.Error(w, err.Error(), 400)
		return
	}

	tx, err := s.db.Begin()
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	defer tx.Rollback()

	// Check available stock
	var available int
	err = tx.QueryRow(`
		SELECT stock - reserved FROM products
		WHERE id = $1 FOR UPDATE
	`, productID).Scan(&available)
	if err == sql.ErrNoRows {
		http.Error(w, "product not found", 404)
		return
	}
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}

	if available < body.Quantity {
		w.WriteHeader(409)
		json.NewEncoder(w).Encode(map[string]interface{}{
			"error":     "insufficient stock",
			"available": available,
			"requested": body.Quantity,
		})
		return
	}

	// Reserve
	_, err = tx.Exec(`
		UPDATE products SET reserved = reserved + $1, updated_at = NOW()
		WHERE id = $2
	`, body.Quantity, productID)
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}

	// Create reservation record
	var reservationID string
	err = tx.QueryRow(`
		INSERT INTO reservations (product_id, order_id, quantity)
		VALUES ($1, $2, $3) RETURNING id
	`, productID, body.OrderID, body.Quantity).Scan(&reservationID)
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}

	tx.Commit()
	stockReservations.Inc()
	s.log.Info("stock reserved", "product", productID, "order", body.OrderID, "qty", body.Quantity)

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(201)
	json.NewEncoder(w).Encode(map[string]interface{}{
		"reservation_id": reservationID,
		"product_id":     productID,
		"order_id":       body.OrderID,
		"quantity":       body.Quantity,
		"status":         "active",
	})
}

func (s *Server) releaseStock(w http.ResponseWriter, r *http.Request) {
	orderID := r.PathValue("order_id")

	tx, err := s.db.Begin()
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	defer tx.Rollback()

	rows, err := tx.Query(`
		SELECT id, product_id, quantity FROM reservations
		WHERE order_id = $1 AND status = 'active'
		FOR UPDATE
	`, orderID)
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	defer rows.Close()

	released := 0
	for rows.Next() {
		var resID, productID string
		var qty int
		rows.Scan(&resID, &productID, &qty)

		tx.Exec(`
			UPDATE products SET reserved = reserved - $1, updated_at = NOW()
			WHERE id = $2
		`, qty, productID)

		tx.Exec(`
			UPDATE reservations SET status = 'released' WHERE id = $1
		`, resID)

		released++
	}

	tx.Commit()
	stockReleases.Add(float64(released))
	s.log.Info("stock released", "order", orderID, "reservations", released)

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"order_id": orderID,
		"released": released,
	})
}

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

	srv := &Server{db: db, log: log}
	mux := http.NewServeMux()

	mux.HandleFunc("/health", srv.health)
	mux.Handle("/metrics",    promhttp.Handler())
	mux.HandleFunc("GET /inventory",                            srv.listProducts)
	mux.HandleFunc("POST /inventory",                           srv.createProduct)
	mux.HandleFunc("POST /inventory/{id}/reserve",              srv.reserveStock)
	mux.HandleFunc("DELETE /inventory/reservations/{order_id}", srv.releaseStock)

	log.Info("inventory-service listening", "port", cfg.Port)
	http.ListenAndServe(":"+cfg.Port, mux)
}
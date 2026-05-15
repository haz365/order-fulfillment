FROM golang:1.22-bookworm AS builder
WORKDIR /build
ENV GOFLAGS=-mod=mod GOPROXY=direct
COPY services/notification-service/go.mod go.mod
COPY services/notification-service/main.go main.go
RUN go mod tidy
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -trimpath -ldflags="-s -w" -o notification-service .

FROM scratch
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=builder /build/notification-service /notification-service
EXPOSE 8004
USER 65532:65532
ENTRYPOINT ["/notification-service"]
FROM golang:1.22-bookworm@sha256:3d699e4d15d0f8f13c9195c0632a16702b8cbdece2955af1c23b37ae5d55a253 AS builder
WORKDIR /build
ENV GOFLAGS=-mod=mod GOPROXY=direct
COPY services/inventory-service/go.mod go.mod
COPY services/inventory-service/main.go main.go
RUN go mod tidy
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -trimpath -ldflags="-s -w" -o inventory-service .

FROM scratch
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=builder /build/inventory-service /inventory-service
EXPOSE 8002
USER 65532:65532
ENTRYPOINT ["/inventory-service"]
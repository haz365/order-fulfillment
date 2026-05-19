FROM golang:1.22-bookworm@sha256:3d699e4d15d0f8f13c9195c0632a16702b8cbdece2955af1c23b37ae5d55a253 AS builder
WORKDIR /build
ENV GOFLAGS=-mod=mod GOPROXY=direct
COPY services/scheduler/go.mod go.mod
COPY services/scheduler/main.go main.go
RUN go mod tidy
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -trimpath -ldflags="-s -w" -o scheduler .

FROM scratch
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=builder /build/scheduler /scheduler
EXPOSE 8007
USER 65532:65532
ENTRYPOINT ["/scheduler"]
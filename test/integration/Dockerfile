# syntax=docker/dockerfile:1.7
# Hermetic end-to-end suite: builds skit, then runs the integration tests
# against the real binary in a throwaway HOME. Run with: just integration

FROM golang:1.26-bookworm AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/root/.cache/go-build \
    --mount=type=cache,target=/go/pkg/mod \
    go mod download
COPY . .
RUN --mount=type=cache,target=/root/.cache/go-build \
    --mount=type=cache,target=/go/pkg/mod \
    CGO_ENABLED=0 go build -ldflags "-X main.version=integration" -o /out/skit ./cmd/skit

FROM debian:stable-slim AS runtime
RUN apt-get update \
    && apt-get install -y --no-install-recommends bash ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=golang:1.26-bookworm /usr/local/go /usr/local/go
ENV PATH=/usr/local/go/bin:/usr/local/bin:/usr/bin:/bin GOPATH=/go GOCACHE=/root/.cache/go-build
COPY --from=build /out/skit /usr/local/bin/skit
WORKDIR /src
CMD ["go", "test", "-tags=integration", "-v", "-count=1", "./test/integration"]

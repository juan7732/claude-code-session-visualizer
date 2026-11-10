# skit — development task runner. Install just: brew install just
# Usage: just <recipe>    |    just --list

default:
    @just --list

version := `git describe --tags --always --dirty 2>/dev/null || echo "dev"`
ldflags := "-X main.version=" + version

# ─── Setup ────────────────────────────────────────────────────────────────────

# One-time: install the git pre-commit hook (gofmt + prettier) and Prettier itself
setup:
    git config core.hooksPath .githooks
    npm install --silent
    @echo "hooks installed (.githooks), prettier ready"

# ─── Build ────────────────────────────────────────────────────────────────────

# Build the skit binary into bin/
build:
    CGO_ENABLED=0 go build -ldflags "{{ldflags}}" -o bin/skit ./cmd/skit

# Install skit to $GOBIN (default ~/go/bin)
install:
    CGO_ENABLED=0 go install -ldflags "{{ldflags}}" ./cmd/skit

# Build and run with args, e.g. just run doctor --json
run *args:
    go run -ldflags "{{ldflags}}" ./cmd/skit {{args}}

# Remove build artifacts
clean:
    rm -rf bin/ coverage.out coverage.html
    go clean -testcache

# ─── Test ─────────────────────────────────────────────────────────────────────

# Unit tests
test:
    go test ./...

# Unit tests, verbose
test-v:
    go test -v ./...

# Unit tests with the race detector
test-race:
    go test -race ./...

# Tests matching a pattern, e.g. just test-run TestInspect
test-run pattern:
    go test -v -run {{pattern}} ./...

# Coverage report → coverage.html
test-cover:
    go test -coverprofile=coverage.out ./...
    go tool cover -html=coverage.out -o coverage.html
    @echo "Coverage report: coverage.html"

# ─── Integration (Docker, hermetic) ──────────────────────────────────────────

integration_tag := "skit-integration:latest"

# Build the integration image and run the end-to-end suite against the real binary
integration:
    docker build -f test/integration/Dockerfile -t {{integration_tag}} .
    docker run --rm -v "$PWD":/src {{integration_tag}} \
        go test -tags=integration -v -count=1 ./test/integration

# Integration suite with the race detector
integration-race:
    docker build -f test/integration/Dockerfile -t {{integration_tag}} .
    docker run --rm -v "$PWD":/src {{integration_tag}} \
        go test -tags=integration -race -v -count=1 ./test/integration

# Integration suite outside Docker, against a fresh local build (fast loop; less hermetic)
integration-local: build
    SKIT_TEST_BINARY="$PWD/bin/skit" go test -tags=integration -v -count=1 ./test/integration

# Shell inside the integration image
integration-shell:
    docker build -f test/integration/Dockerfile -t {{integration_tag}} .
    docker run --rm -it -v "$PWD":/src --entrypoint /bin/bash {{integration_tag}}

# ─── Lint & Format ───────────────────────────────────────────────────────────

vet:
    go vet ./...
    go vet -tags=integration ./test/...

# Format Go (gofmt) and docs/config (prettier)
fmt:
    gofmt -w .
    node_modules/.bin/prettier --write . --log-level warn

# Fail if any file needs formatting (CI)
fmt-check:
    @test -z "$(gofmt -l .)" || (echo "Go files need formatting:" && gofmt -l . && exit 1)
    node_modules/.bin/prettier --check . --log-level warn

tidy:
    go mod tidy
    go mod verify

# Fail if go.mod or go.sum are not tidy (CI's first step)
tidy-check:
    go mod tidy -diff

# Everything CI runs, locally: tidy-check, fmt-check, vet, race tests, integration
check: tidy-check fmt-check vet test-race integration

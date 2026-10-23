# HealthSync - reproducible release build
# NIST SP 800-218: PO.3.2 (Example 4: reproducible builds), PW.6.1, PW.6.2
#
# Same commit + same pinned toolchain  =>  bit-for-bit identical release
# archives, on any machine, in any directory, at any time.
#
#   Pin every input    commit, Go toolchain (go.mod `toolchain`), vendored deps
#   Remove the clock   timestamps derive from SOURCE_DATE_EPOCH = commit time
#   Remove the machine -trimpath, CGO off, no VCS stamping, deterministic tar.gz
#
# Works with GNU make 3.81 (macOS) and 4.x (Linux / CI).

SHELL := /bin/bash

VERSION  := 1.0.0
TARGETS  := linux/amd64 darwin/arm64
DIST     ?= dist

# --- Pin every input --------------------------------------------------------
# Exact toolchain from go.mod; if the local `go` differs, the go command fetches
# this exact release and checks it against the Go checksum database.
GO_PINNED := $(shell sed -n 's/^toolchain //p' go.mod)
export GOTOOLCHAIN := $(GO_PINNED)
# Dependencies come only from vendor/ (locked by go.sum); the build needs no network.
export GOFLAGS     := -mod=vendor
# Pure-Go build: no host C compiler or libc leaks into the binary.
export CGO_ENABLED := 0
export TZ          := UTC
export LC_ALL      := C

COMMIT            ?= $(shell git rev-parse HEAD 2>/dev/null)
# --- Remove the clock -------------------------------------------------------
SOURCE_DATE_EPOCH ?= $(shell git log -1 --format=%ct 2>/dev/null)
BUILD_DATE := $(shell date -u -d @$(SOURCE_DATE_EPOCH) +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
                      date -u -r $(SOURCE_DATE_EPOCH) +%Y-%m-%dT%H:%M:%SZ)

# --- Remove the machine -----------------------------------------------------
# TRIMPATH is a variable only so run_lab.sh can prove the fix is necessary.
TRIMPATH := -trimpath
LDFLAGS  := -buildid= -X main.version=$(VERSION) -X main.commit=$(COMMIT) -X main.buildDate=$(BUILD_DATE)
GOBUILD   = go build $(TRIMPATH) -buildvcs=false -ldflags "$(LDFLAGS)"

.PHONY: release verify-toolchain check-inputs test clean print-inputs

release: check-inputs verify-toolchain
	@set -euo pipefail; \
	rm -rf "$(DIST)"; mkdir -p "$(DIST)/.stage"; \
	go build -trimpath -buildvcs=false -o "$(DIST)/.stage/reprotar" ./tools/reprotar; \
	for t in $(TARGETS); do \
	  os=$${t%/*}; arch=$${t#*/}; pkg=healthsync-$(VERSION)-$$os-$$arch; \
	  mkdir -p "$(DIST)/.stage/$$pkg"; \
	  GOOS=$$os GOARCH=$$arch $(GOBUILD) -o "$(DIST)/.stage/$$pkg/healthsync" ./cmd/healthsync; \
	  cp README.md LICENSE "$(DIST)/.stage/$$pkg/"; \
	  "$(DIST)/.stage/reprotar" -o "$(DIST)/$$pkg.tar.gz" -mtime $(SOURCE_DATE_EPOCH) \
	      -dir "$$pkg" "$(DIST)/.stage/$$pkg"/*; \
	done; \
	rm -rf "$(DIST)/.stage"; \
	cd "$(DIST)" && shasum -a 256 *.tar.gz

check-inputs:
	@test -n "$(COMMIT)" || { echo "COMMIT unknown: build from a git checkout or set COMMIT=<sha>" >&2; exit 1; }
	@test -n "$(SOURCE_DATE_EPOCH)" || { echo "SOURCE_DATE_EPOCH unknown: refusing to fall back to the wall clock" >&2; exit 1; }

verify-toolchain:
	@have="$$(go env GOVERSION)"; \
	if [ "$$have" != "$(GO_PINNED)" ]; then \
	  echo "toolchain mismatch: $$have != pinned $(GO_PINNED)" >&2; exit 1; fi; \
	echo "toolchain OK: $$have (pinned in go.mod), GOFLAGS=$$GOFLAGS CGO_ENABLED=$$CGO_ENABLED"

print-inputs:
	@echo "COMMIT=$(COMMIT)"; echo "SOURCE_DATE_EPOCH=$(SOURCE_DATE_EPOCH)"; \
	 echo "BUILD_DATE=$(BUILD_DATE)"; echo "GO_PINNED=$(GO_PINNED)"; \
	 echo "GOFLAGS=$(GOFLAGS)"; echo "CGO_ENABLED=$(CGO_ENABLED)"; echo "TRIMPATH=$(TRIMPATH)"; \
	 echo "LDFLAGS=$(LDFLAGS)"

test:
	go vet ./... && go test ./...

clean:
	rm -rf "$(DIST)"

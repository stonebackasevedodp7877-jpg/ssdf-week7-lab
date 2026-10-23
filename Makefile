# HealthSync release build

VERSION    := 1.0.0
BUILD_DATE := $(shell date -u +%Y-%m-%dT%H:%M:%SZ)
COMMIT     := $(shell git rev-parse HEAD)
DIST       ?= dist
TARGETS    := linux/amd64 darwin/arm64

.PHONY: release clean

release:
	rm -rf $(DIST) && mkdir -p $(DIST)
	for t in $(TARGETS); do \
	  os=$${t%/*}; arch=$${t#*/}; pkg=healthsync-$(VERSION)-$$os-$$arch; \
	  mkdir -p $(DIST)/$$pkg || exit 1; \
	  GOOS=$$os GOARCH=$$arch go build \
	    -ldflags "-X main.version=$(VERSION) -X main.commit=$(COMMIT) -X main.buildDate=$(BUILD_DATE)" \
	    -o $(DIST)/$$pkg/healthsync ./cmd/healthsync || exit 1; \
	  cp README.md LICENSE $(DIST)/$$pkg/ || exit 1; \
	  tar -czf $(DIST)/$$pkg.tar.gz -C $(DIST) $$pkg || exit 1; \
	done
	cd $(DIST) && shasum -a 256 *.tar.gz

clean:
	rm -rf $(DIST)

BINARY := acm-virt-tests-ext
GO_PKG_NAME := github.com/RedHatQE/interop-testing/acm-virt/openshift-tests-ext

.PHONY: build test validate clean

build:
	CGO_ENABLED=0 go build -o $(BINARY) ./cmd/acm-virt-tests-ext/...

test: build
	./$(BINARY) run-suite acm-virt/cclm/all

validate: build
	@echo "==> Validating extension info..."
	./$(BINARY) info
	@echo "==> Listing tests..."
	./$(BINARY) list tests --output names
	@echo "==> Listing suites..."
	./$(BINARY) list suites
	@echo "==> Validation passed."

clean:
	rm -f $(BINARY)

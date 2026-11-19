FROM registry.ci.openshift.org/ocp/builder:rhel-9-golang-1.23 AS builder
COPY . /src/
WORKDIR /src
RUN CGO_ENABLED=0 go build -o acm-virt-tests-ext ./cmd/acm-virt-tests-ext/...
RUN gzip -c acm-virt-tests-ext > /usr/bin/acm-virt-tests.gz

FROM registry.ci.openshift.org/ocp/4.22:tools
COPY --from=builder /usr/bin/acm-virt-tests.gz /usr/bin/acm-virt-tests.gz

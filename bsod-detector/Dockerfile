FROM registry.access.redhat.com/ubi9/ubi-minimal:latest

RUN microdnf install -y openssh-clients jq python3 && microdnf clean all

COPY ci/ /opt/bsod-detector/ci/
COPY scripts/ /opt/bsod-detector/scripts/
COPY data/ /opt/bsod-detector/data/
COPY test-driver/crashme.sys test-driver/crashme-ctl.exe /opt/bsod-detector/driver/

RUN chmod +x /opt/bsod-detector/ci/*.sh

ENTRYPOINT ["/opt/bsod-detector/ci/entrypoint.sh"]

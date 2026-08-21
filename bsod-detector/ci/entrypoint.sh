#!/usr/bin/env bash
set -euo pipefail

case "${BSOD_MODE:-self-test}" in
  self-test)    exec /opt/bsod-detector/ci/trigger-crash.sh ;;
  post-mortem)  exec /opt/bsod-detector/ci/collect-evidence.sh ;;
  *)            echo "Unknown BSOD_MODE: $BSOD_MODE" >&2; exit 2 ;;
esac

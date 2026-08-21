#!/bin/bash

set -euo pipefail

export BSOD_MODE=post-mortem
exec /opt/bsod-detector/ci/entrypoint.sh

#!/usr/bin/env bash
set -euo pipefail

VMI_NAME="${1:?Usage: capture-screenshot.sh <vmi-name> [namespace] [output-dir] [max-polls]}"
NAMESPACE="${2:-${NAMESPACE}}"
OUT_DIR="${3:-${ARTIFACT_DIR:-.}}"
MAX_POLLS="${4:-60}"

mkdir -p "$OUT_DIR"

captured=0
for i in $(seq 1 "$MAX_POLLS"); do
  outfile="$OUT_DIR/bsod-screenshot-$(printf '%03d' "$i").png"

  oc get --raw \
    "/apis/subresources.kubevirt.io/v1/namespaces/$NAMESPACE/virtualmachineinstances/$VMI_NAME/vnc/screenshot" \
    > "$outfile" 2>/dev/null || { sleep 0.5; continue; }

  size=$(stat -c%s "$outfile" 2>/dev/null || echo 0)
  if [ "$size" -lt 100 ]; then
    rm -f "$outfile"
    sleep 0.5
    continue
  fi

  if [ "$size" -gt 10000 ]; then
    echo "[screenshot] Frame $i: $size bytes (likely BSOD)" >&2
    captured=$((captured + 1))
  fi

  sleep 0.5
done

if [ "$captured" -gt 0 ]; then
  echo "[screenshot] Captured $captured frames with significant content" >&2
else
  echo "[screenshot] WARNING: No BSOD frames captured in $MAX_POLLS polls" >&2
fi

echo "$captured"

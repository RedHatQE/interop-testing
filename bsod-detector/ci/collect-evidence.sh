#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

SSH_KEY="${SHARED_DIR}/ssh-privatekey"
SSHOPTS=(-i "$SSH_KEY" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=30 -o ServerAliveInterval=20)
BUGCHECK_CODE="${BUGCHECK_CODE:-}"

discover_vm
log "Collecting BSOD evidence from $VM_IP..."

if ! wait_ssh "$VM_IP" 5; then
  log "WARNING: VM unreachable via SSH; skipping collection"
  echo '{"ok":false,"error":"VM unreachable via SSH","warnings":["VM may still be crashed or powered off"]}' \
    > "${ARTIFACT_DIR}/collect-guest.json"
  exit 0
fi

GUEST_OUT='C:\bsod-detector\output\ci-collect'
COLLECT_JSON=$(run_guest "
  Remove-Item -Recurse -Force '$GUEST_OUT' -ErrorAction SilentlyContinue
  & C:\\bsod-detector\\scripts\\collect-guest.ps1 -OutputDir '$GUEST_OUT'
" 2>/dev/null || true)

if [ -z "$COLLECT_JSON" ]; then
  log "WARNING: collect-guest.ps1 produced no output"
  echo '{"ok":false,"error":"collect-guest.ps1 produced no output","warnings":[]}' \
    > "${ARTIFACT_DIR}/collect-guest.json"
  exit 0
fi

echo "$COLLECT_JSON" > "${ARTIFACT_DIR}/collect-guest.json"

CODE=$(echo "$COLLECT_JSON" | jq -r '.crash.bugCheckCode // "none"')
NAME=$(echo "$COLLECT_JSON" | jq -r '.crash.bugCheckName // "unknown"')
DUMPS=$(echo "$COLLECT_JSON" | jq -r '.crash.dumpFiles | length')
WARNINGS=$(echo "$COLLECT_JSON" | jq -r '.warnings | length')

log "Bug-check: $CODE ($NAME)"
log "Dump files: $DUMPS"

if [ "$CODE" != "none" ] && [ "$CODE" != "null" ]; then
  log "BSOD DETECTED: $CODE ($NAME)"

  log "Pulling dump files to artifacts..."
  scp -r "${SSHOPTS[@]}" "Administrator@${VM_IP}:${GUEST_OUT}\\*" "${ARTIFACT_DIR}/" 2>/dev/null || true

  if [ -n "$BUGCHECK_CODE" ]; then
    EXPECTED=$(normalize_code "$BUGCHECK_CODE")
    if [ "$CODE" = "$EXPECTED" ]; then
      log "PASS: observed $CODE matches expected $EXPECTED"
    else
      log "FAIL: expected $EXPECTED, observed $CODE"
      exit 1
    fi
  fi
else
  log "No BSOD detected (bugCheckCode is null)"
fi

if [ "$WARNINGS" -gt 0 ]; then
  log "Warnings from collector:"
  echo "$COLLECT_JSON" | jq -r '.warnings[]' | while read -r w; do log "  - $w"; done
fi

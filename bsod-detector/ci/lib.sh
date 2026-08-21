#!/usr/bin/env bash

log() { echo "[bsod-detector] $*" >&2; }
fatal() { log "FATAL: $*"; exit 1; }

discover_vm() {
  if [ -n "${VM_IP:-}" ]; then
    return 0
  fi

  if [ -d "${SHARED_DIR:-}" ]; then
    local instance_file
    instance_file=$(find "$SHARED_DIR" -name '*_windows_instance.txt' 2>/dev/null | head -1)
    if [ -n "$instance_file" ]; then
      VM_IP=$(cat "$instance_file" | tr -d '[:space:]')
      log "Discovered VM IP from $instance_file: $VM_IP"
    fi
  fi

  if [ -z "${VM_IP:-}" ] && [ -n "${VMI_NAME:-}" ] && command -v oc &>/dev/null; then
    VM_IP=$(oc get vmi "$VMI_NAME" -n "${NAMESPACE}" -o jsonpath='{.status.interfaces[0].ipAddress}' 2>/dev/null || true)
    log "Discovered VM IP from VMI status: $VM_IP"
  fi

  if [ -z "${VM_IP:-}" ]; then
    fatal "Cannot determine VM IP. Set VM_IP, VMI_NAME, or place an instance file in SHARED_DIR."
  fi

  if [ -z "${VMI_NAME:-}" ] && command -v oc &>/dev/null; then
    VMI_NAME=$(oc get vmi -n "${NAMESPACE}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  fi

  if [ -z "${NAMESPACE:-}" ]; then
    NAMESPACE=$(oc project -q 2>/dev/null || echo "default")
  fi

  export VM_IP VMI_NAME NAMESPACE
}

wait_ssh() {
  local ip="$1"
  local max="${2:-25}"
  local ssh_key="${SHARED_DIR:-}/ssh-privatekey"
  local opts=(-i "$ssh_key" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10)

  for _ in $(seq 1 "$max"); do
    if ssh "${opts[@]}" "Administrator@${ip}" "echo up" 2>/dev/null | grep -q up; then
      return 0
    fi
    sleep 8
  done
  return 1
}

run_guest() {
  local cmd="$1"
  local ssh_key="${SHARED_DIR:-}/ssh-privatekey"
  local opts=(-i "$ssh_key" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=30 -o ServerAliveInterval=20)

  ssh "${opts[@]}" "Administrator@${VM_IP}" "powershell -Command \"$cmd\"" 2>/dev/null
}

normalize_code() {
  local code="$1"
  python3 -c "
c = '$code'.upper()
if c.startswith('0X'): c = c[2:]
print('0x' + c.zfill(8))
"
}

virtctl_restart() {
  local vmi="$1"
  local ns="$2"
  if command -v virtctl &>/dev/null; then
    virtctl restart "$vmi" -n "$ns" 2>/dev/null || true
  elif command -v oc &>/dev/null; then
    oc patch vm "$vmi" -n "$ns" --type=merge -p '{"spec":{"runStrategy":"Always"}}' 2>/dev/null || true
  fi
}

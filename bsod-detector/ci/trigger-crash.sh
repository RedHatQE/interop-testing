#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

SSH_KEY="${SHARED_DIR}/ssh-privatekey"
SSHOPTS=(-i "$SSH_KEY" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=30 -o ServerAliveInterval=20)
BUGCHECK_CODE="${BUGCHECK_CODE:-0x19}"
BUGCHECK_PARAMS="${BUGCHECK_PARAMS:-0x3 0x0 0x0 0x0}"
VMI_NAME="${VMI_NAME:-}"
NAMESPACE="${NAMESPACE:-}"

discover_vm
log "Target VM: $VM_IP (VMI: $VMI_NAME in $NAMESPACE)"

log "Waiting for SSH..."
wait_ssh "$VM_IP" || fatal "SSH never came up"

log "Pushing CrashMe driver to guest..."
scp "${SSHOPTS[@]}" /opt/bsod-detector/driver/crashme.sys /opt/bsod-detector/driver/crashme-ctl.exe \
  "Administrator@${VM_IP}:C:/Windows/Temp/" 2>/dev/null

log "Installing and starting CrashMe driver..."
run_guest "
  \$sysFile = 'C:\\Windows\\Temp\\crashme.sys'
  \$svc = Get-Service -Name CrashMe -ErrorAction SilentlyContinue
  if (-not \$svc) {
    sc.exe create CrashMe type= kernel binPath= \$sysFile start= demand | Out-Null
  }
  sc.exe start CrashMe 2>&1 | Out-Null
  (Get-Service CrashMe).Status
"

log "Disabling AutoReboot (keep BSOD on screen for screenshot)..."
run_guest "Set-ItemProperty -Path 'HKLM:\\SYSTEM\\CurrentControlSet\\Control\\CrashControl' -Name AutoReboot -Value 0 -Type DWord"

log "Triggering BSOD: code=$BUGCHECK_CODE params=$BUGCHECK_PARAMS"
ssh "${SSHOPTS[@]}" "Administrator@${VM_IP}" \
  "C:\\Windows\\Temp\\crashme-ctl.exe $BUGCHECK_CODE $BUGCHECK_PARAMS" 2>&1 || true

log "Starting screenshot capture..."
"$SCRIPT_DIR/capture-screenshot.sh" "$VMI_NAME" "$NAMESPACE" "${ARTIFACT_DIR}" 60

log "Force-restarting VM and re-enabling AutoReboot..."
if command -v oc &>/dev/null && [ -n "$VMI_NAME" ]; then
  oc patch vm "$VMI_NAME" -n "$NAMESPACE" --type=merge -p '{"spec":{"running":true}}' 2>/dev/null || true
  virtctl_restart "$VMI_NAME" "$NAMESPACE"
fi

log "Waiting for VM reboot and SSH..."
sleep 30
wait_ssh "$VM_IP" || fatal "SSH never came back after crash"

log "Re-enabling AutoReboot..."
run_guest "Set-ItemProperty -Path 'HKLM:\\SYSTEM\\CurrentControlSet\\Control\\CrashControl' -Name AutoReboot -Value 1 -Type DWord"

log "Collecting post-mortem evidence..."
"$SCRIPT_DIR/collect-evidence.sh"

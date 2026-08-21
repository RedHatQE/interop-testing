# BSOD Detector - OpenShift CI Integration

Detects Windows Blue Screen of Death (BSOD) events on OpenShift Virtualization
VMs and collects post-mortem evidence (crash dumps, event logs, screenshots) as
Prow artifacts.

## Modes

### Self-test (`BSOD_MODE=self-test`)

Validates that BSOD detection works end-to-end:
1. Pushes the CrashMe kernel driver to the Windows guest
2. Disables auto-reboot (keeps BSOD on screen for screenshot capture)
3. Triggers a deliberate BSOD with a specified bug-check code
4. Captures screenshots of the BSOD via the KubeVirt screenshot API
5. Restarts the VM, collects post-mortem evidence, validates the code matches

### Post-mortem (`BSOD_MODE=post-mortem`)

Runs as a `post` step (always, even on test failure):
1. SSHes into the Windows VM
2. Runs the collector to check if a BSOD occurred
3. If yes, uploads evidence (dumps, event logs, JSON report) to artifacts
4. Does not fail the job if no BSOD occurred or VM is unreachable

## Environment variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `BSOD_MODE` | no | `self-test` | `self-test` or `post-mortem` |
| `BUGCHECK_CODE` | self-test | `0x19` | Hex bug-check code to trigger |
| `BUGCHECK_PARAMS` | self-test | `0x3 0x0 0x0 0x0` | Four hex parameters |
| `VM_IP` | no | auto-discovered | Windows VM IP address |
| `VMI_NAME` | no | auto-discovered | KubeVirt VMI name |
| `NAMESPACE` | no | current project | Namespace of the VMI |
| `SHARED_DIR` | yes | (ci-operator) | Directory with ssh-privatekey and instance files |
| `ARTIFACT_DIR` | yes | (ci-operator) | Directory for Prow artifact upload |

## VM discovery

The scripts discover the Windows VM via (in order):
1. `VM_IP` env var (explicit)
2. `${SHARED_DIR}/*_windows_instance.txt` (written by provisioners)
3. `oc get vmi $VMI_NAME` status (KubeVirt API)

## Screenshot capture

Uses the KubeVirt `vnc/screenshot` subresource API (backed by libvirt's
`virDomainScreenshot`). Polls every 0.5s for up to 30s after the crash trigger.
With `AutoReboot=0`, Windows halts at the BSOD screen while writing the dump,
keeping the framebuffer visible.

Requires RBAC for `virtualmachineinstances/vnc/screenshot` (admin-level in
KubeVirt 1.8+).

## Artifacts produced

| File | Description |
|------|-------------|
| `collect-guest.json` | Full structured report (bug-check code, params, dumps, events) |
| `bsod-screenshot-*.png` | BSOD screen captures (one per poll frame) |
| `Minidump/*.dmp` | Windows minidump files |
| `MEMORY.DMP` | Full kernel dump (if configured) |

## Building the container image

```bash
podman build -t bsod-detector bsod-detector/
```

## Local testing (without CI)

```bash
export SHARED_DIR=/tmp/shared
export ARTIFACT_DIR=/tmp/artifacts
export VM_IP=192.168.122.200
export VMI_NAME=windows-test
export NAMESPACE=default
mkdir -p "$SHARED_DIR" "$ARTIFACT_DIR"
cp ~/.ssh/id_rsa "$SHARED_DIR/ssh-privatekey"

BSOD_MODE=self-test BUGCHECK_CODE=0x19 ./bsod-detector/ci/entrypoint.sh
```

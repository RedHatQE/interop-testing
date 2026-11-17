#!/bin/bash
# OpenShift Virtualization is installed when the HyperConverged CRD is present
# and every HyperConverged Available condition is True.
# SPOKE_INDEX, when set, checks that spoke via SHARED_DIR. Unset checks the hub KUBECONFIG.
# Exit 0 pass, 1 fail, 2 skip. Does not print kubeconfigs, tokens, or passwords.
set -euo pipefail
shopt -s inherit_errexit

# Resolve the target before xtrace so the kubeconfig path is not logged.
# A spoke check does not require the hub kubeconfig: two-spoke and upgrade
# validate CNV on the spokes, and the hub may not have it installed.
targetKubeconfig=''
if [[ -n "${SPOKE_INDEX:-}" ]]; then
  if [[ -n "${SHARED_DIR:-}" && -r "${SHARED_DIR}/managed-cluster-kubeconfig-${SPOKE_INDEX}" ]]; then
    targetKubeconfig="${SHARED_DIR}/managed-cluster-kubeconfig-${SPOKE_INDEX}"
  elif [[ "${SPOKE_INDEX}" == '1' && -n "${SHARED_DIR:-}" && -r "${SHARED_DIR}/managed-cluster-kubeconfig" ]]; then
    targetKubeconfig="${SHARED_DIR}/managed-cluster-kubeconfig"
  else
    printf 'ERROR: Spoke kubeconfig not found for index %s\n' "${SPOKE_INDEX}" >&2
    exit 2
  fi
elif [[ -z "${KUBECONFIG:-}" || ! -r "${KUBECONFIG}" ]]; then
  printf 'KUBECONFIG not set, skipping\n' >&2
  exit 2
else
  targetKubeconfig="${KUBECONFIG}"
fi
export KUBECONFIG="${targetKubeconfig}"

set -x

if ! oc get crd hyperconvergeds.hco.kubevirt.io 1>/dev/null 2>&1; then
  printf 'WARN: HyperConverged CRD is not installed\n' >&2
  exit 2
fi

typeset available=''
if ! available="$(oc get hyperconvergeds.hco.kubevirt.io -A \
  -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Available")].status}{"\n"}{end}' 2>/dev/null)"; then
  printf 'FAIL: unable to read HyperConverged status\n' >&2
  exit 1
fi
if [[ -z "${available}" ]]; then
  printf 'WARN: HyperConverged CR not found\n' >&2
  exit 2
fi

typeset oneStatus=''
typeset -i sawAvailable=0
while IFS= read -r oneStatus; do
  [[ -n "${oneStatus}" ]] || continue
  if [[ "${oneStatus}" != 'True' ]]; then
    printf 'FAIL: HyperConverged Available condition is %s, expected True\n' "${oneStatus}" >&2
    exit 1
  fi
  sawAvailable=1
done <<< "${available}"
if (( sawAvailable == 0 )); then
  printf 'FAIL: HyperConverged Available condition is missing\n' >&2
  exit 1
fi

true

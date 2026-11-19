#!/bin/bash
# ACM Hub is installed and healthy when the MultiClusterHub CRD is present and
# every MultiClusterHub status.phase is Running.
# Exit 0 pass, 1 fail, 2 skip. Does not print kubeconfigs, tokens, or passwords.
set -euo pipefail
shopt -s inherit_errexit

# KUBECONFIG is an ambient path. Check it before xtrace so the path is not logged.
if [[ -z "${KUBECONFIG:-}" || ! -r "${KUBECONFIG}" ]]; then
  printf 'KUBECONFIG not set, skipping\n' >&2
  exit 2
fi

set -x

if ! oc get crd multiclusterhubs.operator.open-cluster-management.io 1>/dev/null 2>&1; then
  printf 'WARN: MultiClusterHub CRD is not installed\n' >&2
  exit 2
fi

typeset phase=''
if ! phase="$(oc get multiclusterhubs.operator.open-cluster-management.io -A \
  -o jsonpath='{range .items[*]}{.status.phase}{"\n"}{end}' 2>/dev/null)"; then
  printf 'FAIL: unable to read MultiClusterHub status\n' >&2
  exit 1
fi
if [[ -z "${phase}" ]]; then
  printf 'WARN: MultiClusterHub CR not found\n' >&2
  exit 2
fi

typeset onePhase=''
typeset -i sawRunning=0
while IFS= read -r onePhase; do
  [[ -n "${onePhase}" ]] || continue
  if [[ "${onePhase}" != 'Running' ]]; then
    printf 'FAIL: MultiClusterHub phase is %s, expected Running\n' "${onePhase}" >&2
    exit 1
  fi
  sawRunning=1
done <<< "${phase}"
if (( sawRunning == 0 )); then
  printf 'FAIL: MultiClusterHub phase is missing\n' >&2
  exit 1
fi

true

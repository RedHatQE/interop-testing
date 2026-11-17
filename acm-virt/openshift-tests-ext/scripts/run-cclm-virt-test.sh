#!/bin/bash
# Hub-spoke CCLM migration and verification for the ACM+Virt OTE scenario.
#
# Assumes the hub, spoke, ACM, CNV, ODF, Submariner, and MTV are already installed.
# Does not install clusters. Does not write JUnit; openshift-tests records the
# extension result from this process exit code (0 pass, 1 fail, 2 skip).
#
# Each JUnit testcase is its own OTE spec. CCLM_CASE selects which result this
# process exits with. The first process runs the migration and verification once
# and records every check. Later processes wait and exit with the recorded code.
# Without CCLM_CASE the script runs the full flow and exits 0 or 1.
#
# Pass/fail conditions are ported from:
#   p2p-mtv-execute-hub-spoke-migration-commands.sh
#   p2p-mtv-verify-hub-spoke-migration-commands.sh
# Optional verify checks return 77 when their preconditions are not met. That code
# is recorded as skip (2) for that case and does not stop the remaining checks.
set -euo pipefail
shopt -s inherit_errexit

# RedactOutput — mask URLs, addresses, hostnames, kubeconfig paths, and credentials.
function RedactOutput () {
  sed -E \
    -e 's#https?://[^[:space:]]+#<REDACTED-URL>#g' \
    -e 's#ip-[0-9]+-[0-9]+-[0-9]+-[0-9]+[.a-z0-9-]*#<REDACTED-NODE>#g' \
    -e 's#[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+#<REDACTED-IP>#g' \
    -e 's#([a-z0-9]([a-z0-9-]*[a-z0-9])?\.){2,}[a-z]+#<REDACTED-HOST>#g' \
    -e 's#[^[:space:]]*kubeconfig[^[:space:]]*#<REDACTED-KUBECONFIG>#g' \
    -e 's#([Tt]oken|[Pp]assword|[Pp]asswd|[Aa]uthorization|[Bb]earer)[=:][^[:space:]]+#\1=<REDACTED>#g'
}

# WithXtraceOff — run a command with xtrace disabled so secret arguments are not logged.
function WithXtraceOff () {
  typeset wasTracing=false
  [[ $- == *x* ]] && wasTracing=true
  set +x
  typeset errFile
  errFile="$(mktemp /tmp/cclm-stderr.XXXXXX)"
  typeset -i rc=0
  "$@" 2>"${errFile}" || rc=$?
  if [[ -s "${errFile}" ]]; then
    RedactOutput < "${errFile}" >&2 || true
  fi
  rm -f "${errFile}"
  if [[ "${wasTracing}" == true ]]; then
    set -x
  fi
  return "${rc}"
}

# OcPath — oc against a cluster role. The kubeconfig path is resolved with xtrace off.
function OcPath () {
  typeset which="${1:?}"; (($#)) && shift
  typeset wasTracing=false
  [[ $- == *x* ]] && wasTracing=true
  set +x

  typeset kc=''
  case "${which}" in
    (hub|mgmt) kc="${KUBECONFIG}" ;;
    (spoke) kc="${spokeKubeconfig}" ;;
    (dest) kc="${destKubeconfig}" ;;
    (vsource) kc="${verifySourceKubeconfig}" ;;
    (vdest) kc="${verifyDestKubeconfig}" ;;
    (*)
      printf 'ERROR: unknown cluster role\n' >&2
      if [[ "${wasTracing}" == true ]]; then
        set -x
      fi
      return 1
      ;;
  esac

  typeset errFile
  errFile="$(mktemp /tmp/oc-stderr.XXXXXX)"
  typeset -i rc=0
  oc --kubeconfig="${kc}" "$@" 2>"${errFile}" || rc=$?
  if [[ -s "${errFile}" ]]; then
    RedactOutput < "${errFile}" >&2 || true
  fi
  rm -f "${errFile}"
  if [[ "${wasTracing}" == true ]]; then
    set -x
  fi
  return "${rc}"
}

function MgmtOc () { OcPath hub "$@"; }
function SourceOc () { OcPath vsource "$@"; }
function DestOc () { OcPath vdest "$@"; }

function CaseKey () {
  printf '%s' "${1:?}" | tr -c 'A-Za-z0-9' '_'
}

function RecordCase () {
  [[ -n "${CCLM_CASE:-}" ]] || return 0
  [[ -n "${cclmResultsDir:-}" ]] || return 0
  typeset name="${1:?}" rc="${2:?}"
  mkdir -p "${cclmResultsDir}"
  printf '%s\n' "${rc}" > "${cclmResultsDir}/$(CaseKey "${name}")"
  true
}

function ApplyPlanRecords () {
  typeset name="${1:?}" key
  [[ "${name}" == *'Migration: Apply Plan'* ]] || return 0
  key="$(CaseKey "${name%% (*}")"
  typeset nullglobWas=false
  if shopt -q nullglob; then
    nullglobWas=true
  fi
  shopt -s nullglob
  typeset matches=( "${cclmResultsDir}/${key}"* )
  if [[ "${nullglobWas}" == false ]]; then
    shopt -u nullglob
  fi
  if (( ${#matches[@]} == 0 )); then
    return 0
  fi
  printf '%s\n' "${matches[@]}"
  true
}

function HasCaseRecord () {
  typeset name="${1:?}" key
  key="$(CaseKey "${name}")"
  if [[ -f "${cclmResultsDir}/${key}" ]]; then
    return 0
  fi
  typeset records
  records="$(ApplyPlanRecords "${name}")"
  [[ -n "${records}" ]]
}

function ReadCaseRc () {
  typeset name="${1:?}" key records
  key="$(CaseKey "${name}")"
  if [[ -f "${cclmResultsDir}/${key}" ]]; then
    cat "${cclmResultsDir}/${key}"
    return 0
  fi
  records="$(ApplyPlanRecords "${name}")"
  if [[ -n "${records}" ]]; then
    cat "${records%%$'\n'*}"
    return 0
  fi
  printf '2\n'
  true
}

function ReleaseCaseLock () {
  [[ "${cclmCaseOwner:-false}" == true ]] || return 0
  [[ -n "${cclmResultsDir:-}" ]] || return 0
  if [[ -d "${cclmResultsDir}/lock.d" ]]; then
    rm -rf "${cclmResultsDir}/lock.d"
  fi
  true
}

function ClaimOrExitCase () {
  [[ -n "${CCLM_CASE:-}" ]] || return 0
  mkdir -p "${cclmResultsDir}"
  if command -v flock >/dev/null 2>&1; then
    exec 9>"${cclmResultsDir}/lock"
    flock 9
    if [[ -f "${cclmResultsDir}/done" ]]; then
      exit "$(ReadCaseRc "${CCLM_CASE}")"
    fi
    cclmCaseOwner=true
    return 0
  fi

  typeset lockDir="${cclmResultsDir}/lock.d"
  typeset -i waited=0
  while true; do
    if mkdir "${lockDir}" 2>/dev/null; then
      printf '%s\n' "$$" > "${lockDir}/pid"
      break
    fi
    if [[ -f "${cclmResultsDir}/done" ]]; then
      exit "$(ReadCaseRc "${CCLM_CASE}")"
    fi
    if [[ ! -f "${lockDir}/pid" ]]; then
      sleep 1
      waited=$(( waited + 1 ))
    else
      typeset holder=''
      holder="$(cat "${lockDir}/pid" 2>/dev/null || true)"
      if [[ -z "${holder}" ]] || ! kill -0 "${holder}" 2>/dev/null; then
        rm -rf "${lockDir}"
        continue
      fi
      sleep 1
      waited=$(( waited + 1 ))
    fi
    if (( waited >= 2700 )); then
      printf 'ERROR: timed out waiting for the CCLM migration result\n' >&2
      exit 1
    fi
  done
  if [[ -f "${cclmResultsDir}/done" ]]; then
    rm -rf "${lockDir}"
    exit "$(ReadCaseRc "${CCLM_CASE}")"
  fi
  cclmCaseOwner=true
  true
}

function RunCheck () {
  typeset name="${1:?}"; (($#)) && shift
  : "${name}"
  typeset -i rc=0
  "$@" || rc=$?
  RecordCase "${name}" "${rc}"
  return "${rc}"
}

# RunOptionalCheck — 77 means the check was intentionally not run (same as the verify step).
function RunOptionalCheck () {
  typeset name="${1:?}"; (($#)) && shift
  : "${name}"
  typeset -i rc=0
  "$@" || rc=$?
  if (( rc == 77 )); then
    RecordCase "${name}" 2
    return 0
  fi
  RecordCase "${name}" "${rc}"
  return "${rc}"
}

function ResolveSpokeKubeconfig () {
  typeset wasTracing=false
  [[ $- == *x* ]] && wasTracing=true
  set +x
  typeset -i rc=0

  if [[ -z "${SHARED_DIR:-}" ]]; then
    printf 'ERROR: SHARED_DIR is required to resolve the spoke kubeconfig\n' >&2
    rc=1
  elif [[ -n "${MTV_HS_SPOKE_KUBECONFIG:-}" ]]; then
    spokeKubeconfig="${MTV_HS_SPOKE_KUBECONFIG}"
  elif [[ -r "${SHARED_DIR}/managed-cluster-kubeconfig-${spokeIndex}" ]]; then
    spokeKubeconfig="${SHARED_DIR}/managed-cluster-kubeconfig-${spokeIndex}"
  elif [[ "${spokeIndex}" == '1' && -r "${SHARED_DIR}/managed-cluster-kubeconfig" ]]; then
    spokeKubeconfig="${SHARED_DIR}/managed-cluster-kubeconfig"
  else
    printf 'ERROR: spoke kubeconfig not found\n' >&2
    rc=1
  fi
  if (( rc == 0 )) && [[ ! -r "${spokeKubeconfig}" ]]; then
    printf 'ERROR: spoke kubeconfig is not readable\n' >&2
    rc=1
  fi
  if [[ "${wasTracing}" == true ]]; then
    set -x
  fi
  return "${rc}"
}

function ResolveDestKubeconfig () {
  typeset wasTracing=false
  [[ $- == *x* ]] && wasTracing=true
  set +x
  typeset -i rc=0

  if [[ -z "${SHARED_DIR:-}" ]]; then
    printf 'ERROR: SHARED_DIR is required to resolve the destination kubeconfig\n' >&2
    rc=1
  elif [[ -n "${P2P_DEST_KUBECONFIG:-}" ]]; then
    destKubeconfig="${P2P_DEST_KUBECONFIG}"
  elif [[ -n "${P2P_DEST_SPOKE_INDEX:-}" ]]; then
    if [[ -r "${SHARED_DIR}/managed-cluster-kubeconfig-${P2P_DEST_SPOKE_INDEX}" ]]; then
      destKubeconfig="${SHARED_DIR}/managed-cluster-kubeconfig-${P2P_DEST_SPOKE_INDEX}"
    else
      printf 'ERROR: destination spoke kubeconfig not found\n' >&2
      rc=1
    fi
  else
    printf 'ERROR: spoke-spoke direction requires P2P_DEST_KUBECONFIG or P2P_DEST_SPOKE_INDEX\n' >&2
    rc=1
  fi
  if (( rc == 0 )) && [[ ! -r "${destKubeconfig}" ]]; then
    printf 'ERROR: destination kubeconfig is not readable\n' >&2
    rc=1
  fi
  if [[ "${wasTracing}" == true ]]; then
    set -x
  fi
  return "${rc}"
}

function ResolveVerifyKubeconfigs () {
  typeset wasTracing=false
  [[ $- == *x* ]] && wasTracing=true
  set +x
  typeset -i rc=0

  if [[ -z "${SHARED_DIR:-}" ]]; then
    printf 'ERROR: SHARED_DIR is required to resolve verification kubeconfigs\n' >&2
    rc=1
  fi

  if (( rc == 0 )); then
    if [[ -n "${MTV_SOURCE_SPOKE_KUBECONFIG:-}" ]]; then
      verifySourceKubeconfig="${MTV_SOURCE_SPOKE_KUBECONFIG}"
    elif (( sourceSpokeIndex == 0 )); then
      verifySourceKubeconfig="${KUBECONFIG}"
    elif [[ -r "${SHARED_DIR}/managed-cluster-kubeconfig-${sourceSpokeIndex}" ]]; then
      verifySourceKubeconfig="${SHARED_DIR}/managed-cluster-kubeconfig-${sourceSpokeIndex}"
    elif (( sourceSpokeIndex == 1 )) && [[ -r "${SHARED_DIR}/managed-cluster-kubeconfig" ]]; then
      verifySourceKubeconfig="${SHARED_DIR}/managed-cluster-kubeconfig"
    else
      printf 'ERROR: source spoke kubeconfig not found\n' >&2
      rc=1
    fi
  fi
  if (( rc == 0 )) && [[ ! -r "${verifySourceKubeconfig}" ]]; then
    printf 'ERROR: source kubeconfig is not readable\n' >&2
    rc=1
  fi

  if (( rc == 0 )); then
    if [[ -n "${MTV_DEST_SPOKE_KUBECONFIG:-}" ]]; then
      verifyDestKubeconfig="${MTV_DEST_SPOKE_KUBECONFIG}"
    elif (( destSpokeIndex == 0 )); then
      verifyDestKubeconfig="${KUBECONFIG}"
    elif [[ -r "${SHARED_DIR}/managed-cluster-kubeconfig-${destSpokeIndex}" ]]; then
      verifyDestKubeconfig="${SHARED_DIR}/managed-cluster-kubeconfig-${destSpokeIndex}"
    elif (( destSpokeIndex == 1 )) && [[ -r "${SHARED_DIR}/managed-cluster-kubeconfig" ]]; then
      verifyDestKubeconfig="${SHARED_DIR}/managed-cluster-kubeconfig"
    else
      printf 'ERROR: destination spoke kubeconfig not found\n' >&2
      rc=1
    fi
  fi
  if (( rc == 0 )) && [[ ! -r "${verifyDestKubeconfig}" ]]; then
    printf 'ERROR: destination kubeconfig is not readable\n' >&2
    rc=1
  fi
  if [[ "${wasTracing}" == true ]]; then
    set -x
  fi
  return "${rc}"
}

function CleanupSecrets () {
  typeset wasTracing=false
  [[ $- == *x* ]] && wasTracing=true
  set +x
  if [[ -n "${sshKeyFile:-}" ]]; then
    rm -f "${sshKeyFile}"
  fi
  if [[ "${wasTracing}" == true ]]; then
    set -x
  fi
}

function OnExit () {
  typeset -i ec=$?
  CleanupSecrets || true
  if [[ "${cclmCaseOwner:-false}" == true && -n "${cclmResultsDir:-}" ]]; then
    mkdir -p "${cclmResultsDir}" || true
    if [[ -n "${CCLM_CASE:-}" ]] && ! HasCaseRecord "${CCLM_CASE}" && (( ec != 0 )); then
      RecordCase "${CCLM_CASE}" "${ec}" || true
    fi
    touch "${cclmResultsDir}/done" || true
    if [[ -n "${CCLM_CASE:-}" ]]; then
      ec="$(ReadCaseRc "${CCLM_CASE}")" || ec=1
    fi
    ReleaseCaseLock || true
  fi
  exit "${ec}"
}

function WaitProviderReady () {
  typeset providerName="${1:?}"; (($#)) && shift
  MgmtOc wait "provider/${providerName}" -n "${mtvNamespace}" \
    --for=condition=Ready --timeout="${planReadyTimeout}" 1>/dev/null
  true
}

function WaitMapReady () {
  typeset kind="${1:?}"; (($#)) && shift
  typeset name="${1:?}"; (($#)) && shift
  MgmtOc wait "${kind}/${name}" -n "${mtvNamespace}" \
    --for=condition=Ready --timeout="${planReadyTimeout}" 1>/dev/null
  true
}

function PreflightHub () {
  typeset srcProvider="${1:?}"; (($#)) && shift
  typeset dstProvider="${1:?}"; (($#)) && shift
  typeset netMapName="${1:?}"; (($#)) && shift
  typeset storMapName="${1:?}"; (($#)) && shift

  WaitProviderReady "${srcProvider}"
  WaitProviderReady "${dstProvider}"
  WaitMapReady networkmap "${netMapName}"
  WaitMapReady storagemap "${storMapName}"
  true
}

function HasDecentralizedLiveMigrationGate () {
  typeset clusterRole="${1:?}"; (($#)) && shift
  OcPath "${clusterRole}" get kubevirt "${kubevirtName}" \
    -n "${cnvNamespace}" -o json \
    | jq -e '.spec.configuration.developerConfiguration.featureGates // [] | contains(["DecentralizedLiveMigration"])' \
    > /dev/null
}

function WaitForDecentralizedLiveMigrationGate () {
  typeset clusterRole="${1:?}"; (($#)) && shift
  typeset -i deadline=$((SECONDS + 600))

  while (( SECONDS < deadline )); do
    HasDecentralizedLiveMigrationGate "${clusterRole}" && return 0
    sleep 10
  done
  return 1
}

function EnsureDecentralizedLiveMigrationGate () {
  typeset clusterRole="${1:?}"; (($#)) && shift
  typeset clusterLabel="${1:?}"; (($#)) && shift
  typeset hcoGate=''

  HasDecentralizedLiveMigrationGate "${clusterRole}" && return 0

  hcoGate="$(OcPath "${clusterRole}" get hyperconverged "${hcoName}" \
    -n "${cnvNamespace}" \
    -o jsonpath='{.spec.featureGates.decentralizedLiveMigration}' || true)"
  if [[ "${hcoGate}" != 'true' ]]; then
    OcPath "${clusterRole}" patch hyperconverged "${hcoName}" \
      -n "${cnvNamespace}" \
      --type merge -p '{"spec":{"featureGates":{"decentralizedLiveMigration":true}}}'
  fi

  if WaitForDecentralizedLiveMigrationGate "${clusterRole}"; then
    return 0
  fi
  printf 'ERROR: HCO did not propagate DecentralizedLiveMigration featureGate on %s\n' \
    "${clusterLabel}" >&2
  return 1
}

function MaybeEnsureDecentralizedLiveMigration () {
  typeset srcRole="${1:?}"; (($#)) && shift
  typeset dstRole="${1:?}"; (($#)) && shift
  [[ "${planType}" != 'live' ]] && return 0
  [[ "${ensureDlm}" != 'true' ]] && return 0

  EnsureDecentralizedLiveMigrationGate "${srcRole}" 'src'
  EnsureDecentralizedLiveMigrationGate "${dstRole}" 'dst'
  true
}

function WaitForSyncControllerReady () {
  typeset clusterRole="${1:?}"; (($#)) && shift
  typeset clusterLabel="${1:?}"; (($#)) && shift

  : "Waiting for virt-synchronization-controller on ${clusterLabel}"
  OcPath "${clusterRole}" wait deployment/virt-synchronization-controller \
    -n "${cnvNamespace}" --for=condition=Available \
    --timeout="${syncControllerWait}" 1>/dev/null
  true
}

function MaybeWaitForSyncControllers () {
  typeset srcRole="${1:?}"; (($#)) && shift
  typeset dstRole="${1:?}"; (($#)) && shift
  [[ "${planType}" != 'live' ]] && return 0

  WaitForSyncControllerReady "${srcRole}" 'src'
  WaitForSyncControllerReady "${dstRole}" 'dst'
  true
}

function PreflightCclm () {
  typeset srcRole="${1:?}"; (($#)) && shift
  typeset dstRole="${1:?}"; (($#)) && shift
  typeset fcGate='' envVal=''

  [[ "${planType}" != 'live' ]] && return 0

  fcGate="$(MgmtOc get "forkliftcontroller/${forkliftName}" \
    -n "${mtvNamespace}" \
    -o jsonpath='{.spec.feature_ocp_live_migration}' || true)"
  if [[ "${fcGate}" != 'true' ]]; then
    printf 'ERROR: ForkliftController feature_ocp_live_migration is not enabled (got %s)\n' \
      "${fcGate}" >&2
    return 1
  fi

  envVal="$(MgmtOc get "deployment/${forkliftName}" \
    -n "${mtvNamespace}" \
    -o jsonpath='{.spec.template.spec.containers[*].env[?(@.name=="FEATURE_OCP_LIVE_MIGRATION")].value}' \
    || true)"
  if [[ "${envVal}" != 'true' ]]; then
    printf 'ERROR: ForkliftController deployment FEATURE_OCP_LIVE_MIGRATION env is not true (got %s)\n' \
      "${envVal}" >&2
    return 1
  fi

  HasDecentralizedLiveMigrationGate "${srcRole}"
  HasDecentralizedLiveMigrationGate "${dstRole}"
}

function PreflightSubmarinerNoGlobalnet () {
  typeset clusterRole="${1:?}"; (($#)) && shift
  typeset clusterLabel="${1:?}"; (($#)) && shift

  # Same condition as the release step: pass when the Globalnet daemonset lookup fails.
  if OcPath "${clusterRole}" get daemonset submariner-globalnet \
    -n submariner-operator 1>/dev/null; then
    printf 'ERROR: Submariner Globalnet daemonset is present on %s\n' "${clusterLabel}" >&2
    return 1
  fi
  true
}

function MaybePreflightSubmarinerNoGlobalnet () {
  typeset srcRole="${1:?}"; (($#)) && shift
  typeset dstRole="${1:?}"; (($#)) && shift
  [[ "${planType}" != 'live' ]] && return 0

  PreflightSubmarinerNoGlobalnet "${srcRole}" 'src'
  PreflightSubmarinerNoGlobalnet "${dstRole}" 'dst'
  true
}

function RefreshProviderInventory () {
  typeset providerName="${1:?}"; (($#)) && shift
  typeset ts=''
  ts="$(date -u +%s)"
  MgmtOc annotate "provider/${providerName}" -n "${mtvNamespace}" \
    "forklift.konveyor.io/inventory-refresh=${ts}" --overwrite
}

function RefreshProvidersForLivePlan () {
  typeset srcProvider="${1:?}"; (($#)) && shift
  typeset dstProvider="${1:?}"; (($#)) && shift

  [[ "${planType}" != 'live' ]] && return 0

  RefreshProviderInventory "${srcProvider}"
  RefreshProviderInventory "${dstProvider}"
  MgmtOc wait "provider/${srcProvider}" -n "${mtvNamespace}" \
    --for=condition=Ready --timeout="${inventoryRefreshWait}" 1>/dev/null
  MgmtOc wait "provider/${dstProvider}" -n "${mtvNamespace}" \
    --for=condition=Ready --timeout="${inventoryRefreshWait}" 1>/dev/null
  true
}

function PreflightAllSourceVmsRunning () {
  typeset clusterRole="${1:?}"; (($#)) && shift
  typeset vmPrefix="${1:?}"; (($#)) && shift
  typeset vmNs="${1:?}"; (($#)) && shift
  typeset -i i
  typeset phase='' vmName=''

  for ((i = 1; i <= vmCount; i++)); do
    vmName="${vmPrefix}-${i}"
    OcPath "${clusterRole}" get "virtualmachine/${vmName}" -n "${vmNs}" 1>/dev/null

    if [[ "${planType}" == 'live' ]]; then
      phase="$(OcPath "${clusterRole}" get "virtualmachineinstance/${vmName}" -n "${vmNs}" \
        -o jsonpath='{.status.phase}' || true)"
      if [[ "${phase}" != 'Running' ]]; then
        printf 'ERROR: Source VM %s is not Running (phase=%s)\n' "${vmName}" "${phase}" >&2
        return 1
      fi
    fi
  done
  true
}

function GetVmRootDiskStorageClass () {
  typeset clusterRole="${1:?}"; (($#)) && shift
  typeset vmName="${1:?}"; (($#)) && shift
  typeset vmNs="${1:?}"; (($#)) && shift
  typeset dvName='' pvcName='' scName=''

  dvName="$(OcPath "${clusterRole}" get "virtualmachine/${vmName}" -n "${vmNs}" -o json \
    | jq -r 'first(.spec.template.spec.volumes[]?.dataVolume.name // empty) // ""')"
  [[ -z "${dvName}" ]] && dvName="${vmName}-rootdisk"

  pvcName="$(OcPath "${clusterRole}" get "datavolume/${dvName}" -n "${vmNs}" \
    -o jsonpath='{.status.claimName}' || true)"
  [[ -z "${pvcName}" ]] && pvcName="${dvName}"

  scName="$(OcPath "${clusterRole}" get "persistentvolumeclaim/${pvcName}" -n "${vmNs}" \
    -o jsonpath='{.spec.storageClassName}' || true)"
  if [[ -n "${scName}" ]]; then
    printf '%s' "${scName}"
    return 0
  fi
  printf 'Unable to resolve root-disk StorageClass for %s\n' "${vmName}" >&2
  return 1
}

function PreflightVmStorageMapped () {
  typeset srcRole="${1:?}"; (($#)) && shift
  typeset vmPrefix="${1:?}"; (($#)) && shift
  typeset vmNs="${1:?}"; (($#)) && shift
  typeset storMapName="${1:?}"; (($#)) && shift
  typeset vmSc='' scUid='' mapJson='' mapped=''

  vmSc="$(GetVmRootDiskStorageClass "${srcRole}" "${vmPrefix}-1" "${vmNs}")"
  [[ -n "${vmSc}" ]]

  scUid="$(OcPath "${srcRole}" get "storageclass/${vmSc}" \
    -o jsonpath='{.metadata.uid}' || true)"
  mapJson="$(MgmtOc get "storagemap/${storMapName}" -n "${mtvNamespace}" -o json)"
  typeset wasTracing=false
  [[ $- == *x* ]] && wasTracing=true
  set +x
  mapped="$(jq -r --arg sc "${vmSc}" --arg uid "${scUid}" \
    '[.spec.map[]? | select(.source.name == $sc or (.source.id != null and .source.id == $uid))] | length > 0' \
    <<< "${mapJson}")"
  if [[ "${wasTracing}" == true ]]; then
    set -x
  fi
  [[ "${mapped}" == 'true' ]]
}

function CleanupDestinationStaleResources () {
  typeset dstRole="${1:?}"; (($#)) && shift
  typeset vmPrefix="${1:?}"; (($#)) && shift
  typeset vmNs="${1:?}"; (($#)) && shift
  typeset -i count="${1:?}"; (($#)) && shift
  typeset -i i
  typeset vmName='' dvName='' vmiPhase='' pvcName=''

  for ((i = 1; i <= count; i++)); do
    vmName="${vmPrefix}-${i}"
    dvName="${vmName}-rootdisk"

    vmiPhase="$(OcPath "${dstRole}" get "virtualmachineinstance/${vmName}" \
      -n "${vmNs}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    [[ "${vmiPhase}" == 'Running' ]] && continue

    OcPath "${dstRole}" patch "virtualmachine/${vmName}" -n "${vmNs}" \
      --type merge -p '{"metadata":{"finalizers":null}}' 1>/dev/null 2>/dev/null || true
    OcPath "${dstRole}" patch "virtualmachineinstance/${vmName}" -n "${vmNs}" \
      --type merge -p '{"metadata":{"finalizers":null}}' 1>/dev/null 2>/dev/null || true
    OcPath "${dstRole}" delete "virtualmachine/${vmName}" -n "${vmNs}" \
      --ignore-not-found --wait=false 1>/dev/null || true
    OcPath "${dstRole}" delete "virtualmachineinstance/${vmName}" -n "${vmNs}" \
      --ignore-not-found --wait=false 1>/dev/null || true
    OcPath "${dstRole}" delete "datavolume/${dvName}" -n "${vmNs}" \
      --ignore-not-found --wait=false 1>/dev/null || true

    while read -r pvcName; do
      [[ -n "${pvcName}" ]] || continue
      OcPath "${dstRole}" patch "persistentvolumeclaim/${pvcName}" -n "${vmNs}" \
        --type merge -p '{"metadata":{"finalizers":null}}' 1>/dev/null || true
      OcPath "${dstRole}" delete "persistentvolumeclaim/${pvcName}" -n "${vmNs}" \
        --ignore-not-found --wait=false 1>/dev/null || true
    done < <(OcPath "${dstRole}" get pvc -n "${vmNs}" -o json 2>/dev/null \
      | jq -r --arg dv "${dvName}" \
        '.items[].metadata.name | select(. == $dv or . == ("prime-" + $dv))' \
      || true)

    OcPath "${dstRole}" wait --for=delete "virtualmachineinstance/${vmName}" \
      -n "${vmNs}" --timeout=2m 1>/dev/null 2>/dev/null || true
    OcPath "${dstRole}" wait --for=delete "virtualmachine/${vmName}" \
      -n "${vmNs}" --timeout=2m 1>/dev/null 2>/dev/null || true
    OcPath "${dstRole}" wait --for=delete "datavolume/${dvName}" \
      -n "${vmNs}" --timeout=3m 1>/dev/null 2>/dev/null || true
  done
  true
}

function BuildVmsJson () {
  typeset vmPrefix="${1:?}"; (($#)) && shift
  typeset vmNs="${1:?}"; (($#)) && shift
  typeset -i i
  typeset vmsJson='[]'

  for ((i = 1; i <= vmCount; i++)); do
    vmsJson="$(jq -c \
      --arg name "${vmPrefix}-${i}" \
      --arg ns "${vmNs}" \
      '. += [{"name": $name, "namespace": $ns}]' <<< "${vmsJson}")"
  done
  printf '%s' "${vmsJson}"
}

function ApplyPlan () {
  typeset planName="${1:?}"; (($#)) && shift
  typeset srcProvider="${1:?}"; (($#)) && shift
  typeset dstProvider="${1:?}"; (($#)) && shift
  typeset netMapName="${1:?}"; (($#)) && shift
  typeset storMapName="${1:?}"; (($#)) && shift
  typeset targetNs="${1:?}"; (($#)) && shift
  typeset vmsJson="${1:?}"; (($#)) && shift

  jq -cn \
    --arg name "${planName}" \
    --arg ns "${mtvNamespace}" \
    --arg srcProv "${srcProvider}" \
    --arg dstProv "${dstProvider}" \
    --arg netMap "${netMapName}" \
    --arg storMap "${storMapName}" \
    --arg tgtNs "${targetNs}" \
    --argjson vms "${vmsJson}" \
    --arg planTypeArg "${planType}" \
    '{
      apiVersion: "forklift.konveyor.io/v1beta1",
      kind: "Plan",
      metadata: {name: $name, namespace: $ns},
      spec: {
        provider: {
          source: {name: $srcProv, namespace: $ns},
          destination: {name: $dstProv, namespace: $ns}
        },
        targetNamespace: $tgtNs,
        map: {
          network: {name: $netMap, namespace: $ns},
          storage: {name: $storMap, namespace: $ns}
        },
        vms: $vms,
        type: $planTypeArg
      }
    }' | MgmtOc create -f - --dry-run=client -o yaml --save-config | MgmtOc apply -f -
}

function WaitPlanReady () {
  typeset planName="${1:?}"; (($#)) && shift
  MgmtOc wait "plan/${planName}" -n "${mtvNamespace}" \
    --for=condition=Ready --timeout="${planReadyTimeout}" 1>/dev/null
  true
}

function ApplyMigration () {
  typeset migName="${1:?}"; (($#)) && shift
  typeset planName="${1:?}"; (($#)) && shift

  MgmtOc create -f - --dry-run=client -o yaml --save-config <<EOF | MgmtOc apply -f -
apiVersion: forklift.konveyor.io/v1beta1
kind: Migration
metadata:
  name: ${migName}
  namespace: ${mtvNamespace}
spec:
  plan:
    name: ${planName}
    namespace: ${mtvNamespace}
EOF
}

function ParseOcWaitDurationSeconds () {
  typeset duration="${1:?}"; (($#)) && shift
  if [[ "${duration}" =~ ^([0-9]+)h$ ]]; then
    printf '%d\n' $(( BASH_REMATCH[1] * 3600 ))
  elif [[ "${duration}" =~ ^([0-9]+)m$ ]]; then
    printf '%d\n' $(( BASH_REMATCH[1] * 60 ))
  elif [[ "${duration}" =~ ^([0-9]+)s$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  else
    printf '%d\n' 7200
  fi
}

function PrintMigrationPipeline () {
  typeset migName="${1:?}"; (($#)) && shift
  MgmtOc get "migration/${migName}" -n "${mtvNamespace}" \
    -o jsonpath='{range .status.vms[*]}{.name}{"\n"}{range .pipeline[*]}  {.name}: {.phase}{"\n"}{end}{"\n"}{end}' \
    || true
}

function MigrationPipelinePhase () {
  typeset migName="${1:?}"; (($#)) && shift
  typeset vmName="${1:?}"; (($#)) && shift
  typeset stepName="${1:?}"; (($#)) && shift
  typeset migJson='' phase=''

  migJson="$(MgmtOc get "migration/${migName}" -n "${mtvNamespace}" -o json || true)"
  [[ -n "${migJson}" ]] || return 0

  typeset wasTracing=false
  [[ $- == *x* ]] && wasTracing=true
  set +x
  phase="$(jq -r --arg vm "${vmName}" --arg step "${stepName}" \
    '.status.vms[]? | select(.name == $vm) | .pipeline[]? | select(.name == $step) | .phase' \
    <<< "${migJson}" | head -1)"
  if [[ -n "${phase}" && "${phase}" != 'null' ]]; then
    printf '%s' "${phase}"
  fi
  if [[ "${wasTracing}" == true ]]; then
    set -x
  fi
}

function CheckSyncStuck () {
  typeset migName="${1:?}"; (($#)) && shift
  typeset vmPrefix="${1:?}"; (($#)) && shift
  typeset srcRole="${1:?}"; (($#)) && shift
  typeset srcNs="${1:?}"; (($#)) && shift
  typeset dstRole="${1:?}"; (($#)) && shift
  typeset dstNs="${1:?}"; (($#)) && shift
  typeset -n syncStartedAtRef="${1:?}"; (($#)) && shift

  [[ "${planType}" != 'live' ]] && return 0
  (( syncStuckMinutes > 0 )) || return 0

  typeset syncPhase=''
  syncPhase="$(MigrationPipelinePhase "${migName}" "${vmPrefix}-1" 'Synchronization')"
  if [[ "${syncPhase}" != 'Running' ]]; then
    syncStartedAtRef=0
    return 0
  fi

  (( syncStartedAtRef )) || syncStartedAtRef="${SECONDS}"
  if (( SECONDS - syncStartedAtRef < syncStuckMinutes * 60 )); then
    return 0
  fi

  typeset srcVmimPhase='' destVmimPhase=''
  srcVmimPhase="$(OcPath "${srcRole}" get vmim -n "${srcNs}" \
    -o jsonpath='{.items[0].status.phase}' || true)"
  destVmimPhase="$(OcPath "${dstRole}" get vmim -n "${dstNs}" \
    -o jsonpath='{.items[0].status.phase}' || true)"
  if [[ "${srcVmimPhase}" == 'Synchronizing' && "${destVmimPhase}" == 'WaitingForSync' ]]; then
    printf 'ERROR: sync stuck >%sm (src=%s dst=%s)\n' \
      "${syncStuckMinutes}" "${srcVmimPhase}" "${destVmimPhase}" >&2
    return 1
  fi
  return 0
}

function WaitMigrationSucceeded () {
  typeset migName="${1:?}"; (($#)) && shift
  typeset vmPrefix="${1:?}"; (($#)) && shift
  typeset srcRole="${1:?}"; (($#)) && shift
  typeset srcNs="${1:?}"; (($#)) && shift
  typeset dstRole="${1:?}"; (($#)) && shift
  typeset dstNs="${1:?}"; (($#)) && shift
  # shellcheck disable=SC2034  # syncStartedAt is passed by name to CheckSyncStuck.
  typeset -i deadline syncStartedAt=0
  typeset succeededStatus='' failedStatus='' msg=''

  deadline=$((SECONDS + $(ParseOcWaitDurationSeconds "${migrationTimeout}")))

  while (( SECONDS < deadline )); do
    succeededStatus="$(MgmtOc get "migration/${migName}" -n "${mtvNamespace}" \
      -o jsonpath='{.status.conditions[?(@.type=="Succeeded")].status}' || true)"
    failedStatus="$(MgmtOc get "migration/${migName}" -n "${mtvNamespace}" \
      -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' || true)"
    msg="$(MgmtOc get "migration/${migName}" -n "${mtvNamespace}" \
      -o jsonpath='{.status.conditions[?(@.type=="Succeeded")].message}' || true)"

    [[ "${succeededStatus}" == 'True' ]] && return 0

    if [[ "${failedStatus}" == 'True' ]]; then
      MgmtOc get "migration/${migName}" -n "${mtvNamespace}" \
        -o jsonpath='{range .status.conditions[*]}{.type}{": "}{.status}{" "}{.message}{"\n"}{end}' \
        | RedactOutput >&2 || true
      PrintMigrationPipeline "${migName}" >&2 || true
      return 1
    fi

    CheckSyncStuck "${migName}" "${vmPrefix}" \
      "${srcRole}" "${srcNs}" "${dstRole}" "${dstNs}" syncStartedAt

    PrintMigrationPipeline "${migName}"
    : "Migration ${migName} in progress${msg:+: ${msg}} (${SECONDS}/${deadline}s)"
    sleep "${migrationPollInterval}"
  done
  return 1
}

function VerifyAllVmsMigrated () {
  typeset dstRole="${1:?}"; (($#)) && shift
  typeset vmPrefix="${1:?}"; (($#)) && shift
  typeset vmNs="${1:?}"; (($#)) && shift
  typeset -i i
  typeset phase='' vmName=''

  for ((i = 1; i <= vmCount; i++)); do
    vmName="${vmPrefix}-${i}"
    phase="$(OcPath "${dstRole}" get "virtualmachineinstance/${vmName}" -n "${vmNs}" \
      -o jsonpath='{.status.phase}' || true)"
    if [[ "${phase}" != 'Running' ]]; then
      printf 'ERROR: Migrated VM %s not Running on destination (phase=%s)\n' "${vmName}" "${phase}" >&2
      return 1
    fi
  done
  true
}

function RunOneMigrationDirection () {
  typeset direction="${1:?}"; (($#)) && shift
  typeset srcProvider="${1:?}"; (($#)) && shift
  typeset dstProvider="${1:?}"; (($#)) && shift
  typeset netMapName="${1:?}"; (($#)) && shift
  typeset storMapName="${1:?}"; (($#)) && shift
  typeset planName="${1:?}"; (($#)) && shift
  typeset migName="${1:?}"; (($#)) && shift
  typeset vmPrefix="${1:?}"; (($#)) && shift
  typeset vmNs="${1:?}"; (($#)) && shift
  typeset targetNs="${1:?}"; (($#)) && shift
  typeset srcRole="${1:?}"; (($#)) && shift
  typeset dstRole="${1:?}"; (($#)) && shift
  typeset vmsJson=''

  : "Starting ${direction} migration (${vmCount} VMs)"

  RunCheck "[${direction}] Preflight: Providers and Maps Ready" \
    PreflightHub "${srcProvider}" "${dstProvider}" "${netMapName}" "${storMapName}"
  RunCheck "[${direction}] Preflight: DecentralizedLiveMigration Gates" \
    MaybeEnsureDecentralizedLiveMigration "${srcRole}" "${dstRole}"
  RunCheck "[${direction}] Preflight: Sync Controllers Available (src + dst)" \
    MaybeWaitForSyncControllers "${srcRole}" "${dstRole}"
  RunCheck "[${direction}] Preflight: MTV CCLM Feature Gate Active" \
    PreflightCclm "${srcRole}" "${dstRole}"
  RunCheck "[${direction}] Preflight: Submariner No Globalnet" \
    MaybePreflightSubmarinerNoGlobalnet "${srcRole}" "${dstRole}"
  RunCheck "[${direction}] Preflight: Provider Inventory Refresh" \
    RefreshProvidersForLivePlan "${srcProvider}" "${dstProvider}"
  RunCheck "[${direction}] Preflight: All Source VMs Running" \
    PreflightAllSourceVmsRunning "${srcRole}" "${vmPrefix}" "${vmNs}"
  RunCheck "[${direction}] Preflight: VM Storage Class Mapped" \
    PreflightVmStorageMapped "${srcRole}" "${vmPrefix}" "${vmNs}" "${storMapName}"

  vmsJson="$(BuildVmsJson "${vmPrefix}" "${vmNs}")"

  RunCheck "[${direction}] Pre-migration: Cleanup stale destination resources" \
    CleanupDestinationStaleResources "${dstRole}" "${vmPrefix}" "${targetNs}" "${vmCount}"
  RunCheck "[${direction}] Migration: Apply Plan (${vmCount} VMs)" \
    ApplyPlan "${planName}" "${srcProvider}" "${dstProvider}" \
      "${netMapName}" "${storMapName}" "${targetNs}" "${vmsJson}"
  RunCheck "[${direction}] Migration: Plan Ready" \
    WaitPlanReady "${planName}"
  RunCheck "[${direction}] Migration: Apply Migration" \
    ApplyMigration "${migName}" "${planName}"
  RunCheck "[${direction}] Migration: Succeeded" \
    WaitMigrationSucceeded "${migName}" "${vmPrefix}" \
      "${srcRole}" "${vmNs}" "${dstRole}" "${targetNs}"
  RunCheck "[${direction}] Verification: All Destination VMIs Running" \
    VerifyAllVmsMigrated "${dstRole}" "${vmPrefix}" "${targetNs}"
  true
}

function RunMigrations () {
  [[ "${planType}" == 'live' || "${planType}" == 'cold' ]]
  (( vmCount >= 1 ))
  [[ "${cclmDirection}" == 'both' \
    || "${cclmDirection}" == 'hub-to-spoke' \
    || "${cclmDirection}" == 'spoke-to-hub' \
    || "${cclmDirection}" == 'spoke-to-spoke' \
    || "${cclmDirection}" == 'spoke-round-trip-ss' ]] || {
    printf 'ERROR: P2P_MIGRATION_DIRECTION must be one of: both, hub-to-spoke, spoke-to-hub, spoke-to-spoke, spoke-round-trip-ss (got %s)\n' \
      "${cclmDirection}" >&2
    return 1
  }

  ResolveSpokeKubeconfig
  if [[ "${cclmDirection}" == 'spoke-to-spoke' || "${cclmDirection}" == 'spoke-round-trip-ss' ]]; then
    ResolveDestKubeconfig
  else
    typeset wasTracing=false
    [[ $- == *x* ]] && wasTracing=true
    set +x
    destKubeconfig="${KUBECONFIG}"
    if [[ "${wasTracing}" == true ]]; then
      set -x
    fi
  fi

  typeset hubToSpokeTargetNs="${MTV_HS_HUB_TO_SPOKE_TARGET_NAMESPACE:-}"
  typeset spokeToHubTargetNs="${MTV_HS_SPOKE_TO_HUB_TARGET_NAMESPACE:-}"
  hubToSpokeTargetNs="${hubToSpokeTargetNs:-${fwdVmNs}}"
  spokeToHubTargetNs="${spokeToHubTargetNs:-${revVmNs}}"

  MgmtOc get ns "${mtvNamespace}" 1>/dev/null

  if [[ "${cclmDirection}" == 'spoke-to-hub' || "${cclmDirection}" == 'both' ]]; then
    RunOneMigrationDirection 'spoke-to-hub' \
      "${revSrcProv}" "${revDstProv}" \
      "${revNetMap}" "${revStorMap}" \
      "${revPlan}" "${revMig}" \
      "${revVmPrefix}" "${revVmNs}" "${spokeToHubTargetNs}" \
      spoke hub

    if [[ "${cclmDirection}" == 'both' ]]; then
      RunCheck '[both] Post-leg-1: Cleanup source spoke VM resources' \
        CleanupDestinationStaleResources \
          spoke "${revVmPrefix}" "${revVmNs}" "${vmCount}"

      RunOneMigrationDirection 'hub-to-spoke-return' \
        "${fwdSrcProv}" "${fwdDstProv}" \
        "${fwdNetMap}" "${fwdStorMap}" \
        "${fwdPlan}" "${fwdMig}" \
        "${revVmPrefix}" "${spokeToHubTargetNs}" "${hubToSpokeTargetNs}" \
        hub spoke
    fi
  fi

  if [[ "${cclmDirection}" == 'hub-to-spoke' ]]; then
    RunOneMigrationDirection 'hub-to-spoke' \
      "${fwdSrcProv}" "${fwdDstProv}" \
      "${fwdNetMap}" "${fwdStorMap}" \
      "${fwdPlan}" "${fwdMig}" \
      "${fwdVmPrefix}" "${fwdVmNs}" "${hubToSpokeTargetNs}" \
      hub spoke
  fi

  if [[ "${cclmDirection}" == 'spoke-to-spoke' ]]; then
    RunOneMigrationDirection 'spoke-to-spoke' \
      "${fwdSrcProv}" "${fwdDstProv}" \
      "${fwdNetMap}" "${fwdStorMap}" \
      "${fwdPlan}" "${fwdMig}" \
      "${fwdVmPrefix}" "${fwdVmNs}" "${hubToSpokeTargetNs}" \
      spoke dest
  fi

  if [[ "${cclmDirection}" == 'spoke-round-trip-ss' ]]; then
    RunOneMigrationDirection 'spoke-to-spoke-fwd' \
      "${fwdSrcProv}" "${fwdDstProv}" \
      "${fwdNetMap}" "${fwdStorMap}" \
      "${fwdPlan}" "${fwdMig}" \
      "${fwdVmPrefix}" "${fwdVmNs}" "${hubToSpokeTargetNs}" \
      spoke dest

    RunCheck '[spoke-round-trip-ss] Post-leg-1: Cleanup spoke-1 source VM resources' \
      CleanupDestinationStaleResources \
        spoke "${fwdVmPrefix}" "${fwdVmNs}" "${vmCount}"

    RunOneMigrationDirection 'spoke-to-spoke-rev' \
      "${revSrcProv}" "${revDstProv}" \
      "${revNetMap}" "${revStorMap}" \
      "${revPlan}" "${revMig}" \
      "${fwdVmPrefix}" "${hubToSpokeTargetNs}" "${spokeToHubTargetNs}" \
      dest spoke
  fi
  true
}

function VmName () {
  typeset -i idx="${1:?}"; (($#)) && shift
  if (( verifyVmCount == 1 )); then
    printf '%s' "${vmNameSingle}"
  else
    printf '%s-%d' "${spokeVmPrefix}" "${idx}"
  fi
}

function VmimPhase () {
  typeset ns="${1:?}"; (($#)) && shift
  typeset vmName="${1:?}"; (($#)) && shift
  SourceOc get vmim -n "${ns}" -o json \
    | WithXtraceOff jq -r --arg vm "${vmName}" \
      'first(.items[] | select(.spec.vmiName == $vm) | .status.phase) // ""'
}

function VerifyMigration () {
  typeset -i i
  typeset vmName='' destPhase=''

  for ((i = 1; i <= verifyVmCount; i++)); do
    vmName="$(VmName "${i}")"
    destPhase="$(DestOc get "virtualmachineinstance/${vmName}" -n "${verifyTargetNs}" \
      -o jsonpath='{.status.phase}' || true)"
    if [[ "${destPhase}" != 'Running' ]]; then
      printf 'ERROR: VMI %s not Running on destination (phase=%s)\n' "${vmName}" "${destPhase}" >&2
      return 1
    fi
  done
  true
}

function VerifyDestVmsRunStrategy () {
  typeset -i i
  typeset vmName='' strategy=''

  for ((i = 1; i <= verifyVmCount; i++)); do
    vmName="$(VmName "${i}")"
    strategy="$(DestOc get "virtualmachine/${vmName}" -n "${verifyTargetNs}" \
      -o jsonpath='{.spec.runStrategy}' || true)"
    if [[ "${strategy}" != 'Always' ]]; then
      printf 'ERROR: VM %s runStrategy=%s, expected Always (OCPBUGS-101771)\n' "${vmName}" "${strategy}" >&2
      return 1
    fi
  done
  true
}

function VerifySourceVmimNotFailed () {
  typeset -i i
  typeset vmName='' srcVmimPhase=''

  for ((i = 1; i <= verifyVmCount; i++)); do
    vmName="$(VmName "${i}")"
    if ! srcVmimPhase="$(VmimPhase "${verifyVmNs}" "${vmName}")"; then
      printf 'ERROR: failed to query source VMIM for %s\n' "${vmName}" >&2
      return 1
    fi
    if [[ "${srcVmimPhase}" == 'Failed' ]]; then
      printf 'ERROR: Source VMIM for %s is Failed (OCPBUGS-99403)\n' "${vmName}" >&2
      return 1
    fi
  done
  true
}

function KubeQuantityToBytes () {
  typeset q="${1:-}"; (($#)) && shift
  [[ -n "${q}" ]] || return 1
  typeset num='' suffix=''
  if [[ "${q}" =~ ^([0-9]+)([A-Za-z]*)$ ]]; then
    num="${BASH_REMATCH[1]}"
    suffix="${BASH_REMATCH[2]}"
  else
    return 1
  fi
  typeset -i bytes=0
  case "${suffix}" in
    ('') bytes="${num}" ;;
    (Ki) bytes=$(( num * 1024 )) ;;
    (Mi) bytes=$(( num * 1024 ** 2 )) ;;
    (Gi) bytes=$(( num * 1024 ** 3 )) ;;
    (Ti) bytes=$(( num * 1024 ** 4 )) ;;
    (Pi) bytes=$(( num * 1024 ** 5 )) ;;
    (Ei) bytes=$(( num * 1024 ** 6 )) ;;
    (k) bytes=$(( num * 1000 )) ;;
    (M) bytes=$(( num * 1000 ** 2 )) ;;
    (G) bytes=$(( num * 1000 ** 3 )) ;;
    (T) bytes=$(( num * 1000 ** 4 )) ;;
    (P) bytes=$(( num * 1000 ** 5 )) ;;
    (E) bytes=$(( num * 1000 ** 6 )) ;;
    (*) return 1 ;;
  esac
  printf '%s' "${bytes}"
}

function EnsurePasswdEntry () {
  whoami 1>/dev/null && return 0
  if [[ ! -w /etc/passwd ]]; then
    printf 'ERROR: no passwd entry for the current uid and /etc/passwd is not writable\n' >&2
    return 1
  fi
  printf '%s:x:%s:0:%s user:%s:/sbin/nologin\n' \
    "${USER_NAME:-default}" "$(id -u)" "${USER_NAME:-default}" "${HOME}" >> /etc/passwd
}

function InstallVirtctl () {
  typeset binDir="${TMPDIR:-/tmp}/cclm-verify-bin"
  mkdir -p "${binDir}"
  typeset wasTracing=false
  [[ $- == *x* ]] && wasTracing=true
  set +x
  typeset host=''
  typeset -i rc=0
  host="$(DestOc get route hyperconverged-cluster-cli-download -n "${cnvNamespace}" \
    -o jsonpath='{.spec.host}')" || rc=$?
  if (( rc == 0 )) && [[ -z "${host}" ]]; then
    rc=1
  fi
  if (( rc == 0 )); then
    curl -kfsSL "https://${host}/amd64/linux/virtctl.tar.gz" | tar -xz -C "${binDir}" || rc=$?
  fi
  if [[ "${wasTracing}" == true ]]; then
    set -x
  fi
  (( rc == 0 )) || return 1
  virtctlBin="${binDir}/virtctl"
  "${virtctlBin}" version --client 1>/dev/null
}

function PrepareSshAccess () {
  typeset wasTracing=false
  [[ $- == *x* ]] && wasTracing=true
  set +x
  typeset -i rc=0
  typeset srcKey="${SHARED_DIR}/${sshKeyName}"
  if [[ ! -s "${srcKey}" ]]; then
    printf 'ERROR: VM SSH key %s not found in SHARED_DIR\n' "${sshKeyName}" >&2
    rc=1
  fi
  if (( rc == 0 )); then
    sshKeyFile="/tmp/cclm-verify-ssh-key-$$"
    install -m 0600 "${srcKey}" "${sshKeyFile}" || rc=$?
  fi
  if [[ "${wasTracing}" == true ]]; then
    set -x
  fi
  (( rc == 0 )) || return 1
  [[ -w "${HOME:-/}" ]] || export HOME="${TMPDIR:-/tmp}"
  EnsurePasswdEntry || return 1
  if ! command -v ssh 1>/dev/null; then
    printf 'ERROR: ssh client not found\n' >&2
    return 1
  fi
  if ! InstallVirtctl; then
    printf 'ERROR: failed to install virtctl from the destination cluster\n' >&2
    return 1
  fi
  true
}

function VmSsh () {
  typeset vmName="${1:?}"; (($#)) && shift
  typeset cmd="${1:?}"; (($#)) && shift
  typeset wasTracing=false
  [[ $- == *x* ]] && wasTracing=true
  set +x
  typeset -i rc=0
  KUBECONFIG="${verifyDestKubeconfig}" "${virtctlBin}" ssh "${sshUser}@vmi/${vmName}" \
    --namespace="${verifyTargetNs}" --identity-file="${sshKeyFile}" --known-hosts=/dev/null \
    --local-ssh-opts='-o StrictHostKeyChecking=no' \
    --local-ssh-opts='-o UserKnownHostsFile=/dev/null' \
    --local-ssh-opts='-o BatchMode=yes' \
    --local-ssh-opts='-o ConnectTimeout=15' \
    --local-ssh-opts='-o LogLevel=ERROR' \
    --command="${cmd}" 0</dev/null || rc=$?
  if [[ "${wasTracing}" == true ]]; then
    set -x
  fi
  return "${rc}"
}

function VmSshChecked () {
  typeset vmName="${1:?}"
  typeset errFile="/tmp/cclm-verify-ssh-err-$$"
  typeset -i rc=0
  VmSsh "$@" 2>"${errFile}" || rc=$?
  if (( rc != 0 )); then
    printf 'ERROR: ssh command on %s failed (rc=%d): %s\n' "${vmName}" "${rc}" \
      "$(RedactOutput < "${errFile}" | tail -n 3 | tr '\n' ' ')" >&2
  fi
  rm -f "${errFile}"
  return "${rc}"
}

function WaitDestSshReady () {
  if [[ "${dataIntegrity}" != 'true' && "${vmGuestExec}" != 'true' ]]; then
    return 77
  fi
  PrepareSshAccess || return 1

  typeset errFile="/tmp/cclm-verify-ssh-err-$$"
  typeset -i i deadline=$((SECONDS + sshWaitSeconds))
  for ((i = 1; i <= verifyVmCount; i++)); do
    typeset vmName=''
    vmName="$(VmName "${i}")"
    typeset -i ready=0
    while :; do
      if ( set +x; VmSsh "${vmName}" true 1>/dev/null 2>"${errFile}" ); then
        ready=1
        break
      fi
      (( SECONDS < deadline )) || break
      sleep 10
    done
    if (( ready == 0 )); then
      printf 'ERROR: SSH login to %s still failing after the %ss wait budget; last error: %s\n' \
        "${vmName}" "${sshWaitSeconds}" \
        "$(RedactOutput < "${errFile}" | tail -n 3 | tr '\n' ' ')" >&2
      rm -f "${errFile}"
      return 1
    fi
  done
  rm -f "${errFile}"
  sshReady=true
  true
}

function VerifyVmDataIntegrity () {
  [[ "${dataIntegrity}" == 'true' ]] || return 77
  if [[ "${sshReady}" != 'true' ]]; then
    printf 'ERROR: destination SSH not ready; data integrity not checked\n' >&2
    return 1
  fi

  typeset wasTracing=false
  [[ $- == *x* ]] && wasTracing=true
  set +x
  typeset -i rc=0
  {
    typeset -i i failed=0
    for ((i = 1; i <= verifyVmCount; i++)); do
      typeset vmName='' actualMarker=''
      vmName="$(VmName "${i}")"
      if ! actualMarker="$(VmSshChecked "${vmName}" 'cat /home/cloud-user/migration-marker.txt')"; then
        printf 'ERROR: Integrity marker missing or unreadable on %s\n' "${vmName}" >&2
        (( ++failed ))
        continue
      fi
      if [[ "${actualMarker%$'\r'}" == "${vmName}" ]]; then
        printf 'INFO: data integrity verified for %s\n' "${vmName}" >&2
      else
        printf 'ERROR: Data integrity FAIL for %s (marker mismatch)\n' "${vmName}" >&2
        (( ++failed ))
      fi
    done
    (( failed == 0 ))
  } || rc=$?
  if [[ "${wasTracing}" == true ]]; then
    set -x
  fi
  return "${rc}"
}

function CollectDestLaunchers () {
  typeset -n namesRef="${1:?}"; (($#)) && shift
  typeset -n podsRef="${1:?}"; (($#)) && shift
  typeset -i i
  namesRef=()
  podsRef=()

  typeset wasTracing=false
  [[ $- == *x* ]] && wasTracing=true
  set +x
  typeset -i rc=0
  {
    typeset podsJson=''
    podsJson="$(DestOc get pods -n "${verifyTargetNs}" -l kubevirt.io=virt-launcher -o json || true)"
    for ((i = 1; i <= verifyVmCount; i++)); do
      typeset vmn='' pod=''
      vmn="$(VmName "${i}")"
      namesRef+=("${vmn}")
      pod="$(printf '%s' "${podsJson}" \
        | WithXtraceOff jq -r --arg d "${vmn}" \
          'first(.items[]
           | select(.metadata.labels["kubevirt.io/domain"]==$d)
           | select(.status.phase=="Running")
           | .metadata.name) // ""' \
        || true)"
      if [[ -z "${pod}" ]]; then
        pod="$(printf '%s' "${podsJson}" \
          | WithXtraceOff jq -r --arg n "${vmn}" \
            'first(.items[]
             | select(.metadata.name | startswith("virt-launcher-" + $n + "-"))
             | select(.status.phase=="Running")
             | .metadata.name) // ""' \
          || true)"
      fi
      podsRef+=("${pod}")
    done
  } || rc=$?
  if [[ "${wasTracing}" == true ]]; then
    set -x
  fi
  return "${rc}"
}

function VerifyAllVmsSsh () {
  [[ "${vmSshVerify}" == 'true' ]] || return 77
  [[ "${verifyPlanType}" == 'live' ]] || return 77
  (( verifyVmCount > 1 )) || return 77

  typeset -a vmNamesArr=()
  typeset -a launcherPodsArr=()
  CollectDestLaunchers vmNamesArr launcherPodsArr

  typeset -i i failed=0
  for ((i = 0; i < verifyVmCount; i++)); do
    typeset vmName=''
    vmName="${vmNamesArr[${i}]}"
    typeset -i anchorIdx=$(( (i + 1) % verifyVmCount ))
    if [[ -z "${launcherPodsArr[${anchorIdx}]}" ]]; then
      printf 'ERROR: no probe anchor for SSH check on %s\n' "${vmName}" >&2
      (( ++failed ))
      continue
    fi

    typeset -i probeRc=0
    ( set +x
      typeset vmIp='' anchorPod=''
      vmIp="$(DestOc get "virtualmachineinstance/${vmName}" -n "${verifyTargetNs}" \
        -o jsonpath='{.status.interfaces[0].ipAddress}' || true)"
      anchorPod="${launcherPodsArr[${anchorIdx}]}"
      [[ -n "${vmIp}" ]] || exit 2
      DestOc exec -n "${verifyTargetNs}" "${anchorPod}" -c compute -- \
        timeout 15 bash -c "echo > /dev/tcp/${vmIp}/22"
    ) || probeRc=$?

    case "${probeRc}" in
      (0) : "SSH port 22 reachable on ${vmName}" ;;
      (2)
        printf 'ERROR: no IP on VMI %s for SSH probe\n' "${vmName}" >&2
        (( ++failed ))
        ;;
      (*)
        printf 'ERROR: SSH port 22 not reachable on %s (rc=%d)\n' "${vmName}" "${probeRc}" >&2
        (( ++failed ))
        ;;
    esac
  done
  (( failed == 0 ))
}

function VerifyGuestDiskIo () {
  [[ "${vmGuestExec}" == 'true' ]] || return 77
  if [[ "${sshReady}" != 'true' ]]; then
    printf 'ERROR: destination SSH not ready; guest disk I/O not checked\n' >&2
    return 1
  fi

  typeset ioCmd='dd if=/dev/zero of=/tmp/cclm-io.bin bs=1M count=4 conv=fsync status=none && sha256sum /tmp/cclm-io.bin && rm -f /tmp/cclm-io.bin'
  typeset -i i failed=0
  for ((i = 1; i <= verifyVmCount; i++)); do
    typeset vmName=''
    vmName="$(VmName "${i}")"
    if VmSshChecked "${vmName}" "${ioCmd}" 1>/dev/null; then
      : "Guest disk I/O succeeded on ${vmName}"
    else
      printf 'ERROR: guest disk I/O command failed on %s\n' "${vmName}" >&2
      (( ++failed ))
    fi
  done
  (( failed == 0 ))
}

function VerifyGuestNetwork () {
  [[ "${vmGuestExec}" == 'true' ]] || return 77
  (( verifyVmCount > 1 )) || return 77
  if [[ "${sshReady}" != 'true' ]]; then
    printf 'ERROR: destination SSH not ready; guest network not checked\n' >&2
    return 1
  fi

  typeset -i i failed=0
  for ((i = 1; i <= verifyVmCount; i++)); do
    typeset vmName='' peerName=''
    vmName="$(VmName "${i}")"
    peerName="$(VmName $(( i % verifyVmCount + 1 )))"
    typeset -i probeRc=0
    ( set +x
      typeset peerIp=''
      peerIp="$(DestOc get "virtualmachineinstance/${peerName}" -n "${verifyTargetNs}" \
        -o jsonpath='{.status.interfaces[0].ipAddress}' || true)"
      [[ -n "${peerIp}" ]] || exit 2
      VmSshChecked "${vmName}" "ping -c 2 -W 5 ${peerIp}" 1>/dev/null
    ) || probeRc=$?

    case "${probeRc}" in
      (0) : "Guest ping to peer succeeded on ${vmName}" ;;
      (2)
        printf 'ERROR: no IP on peer VMI for guest network check on %s\n' "${vmName}" >&2
        (( ++failed ))
        ;;
      (*)
        printf 'ERROR: guest ping to peer failed on %s (rc=%d)\n' "${vmName}" "${probeRc}" >&2
        (( ++failed ))
        ;;
    esac
  done
  (( failed == 0 ))
}

function VerifyPvcAttachment () {
  [[ "${pvcCheck}" == 'true' ]] || return 77

  typeset wasTracing=false
  [[ $- == *x* ]] && wasTracing=true
  set +x
  typeset -i rc=0
  {
    typeset -i i failed=0
    for ((i = 1; i <= verifyVmCount; i++)); do
      typeset vmName=''
      vmName="$(VmName "${i}")"
      typeset expectedPvc="${vmName}-rootdisk"
      typeset -i attached=0
      typeset vmJson=''
      if ! vmJson="$(DestOc get "virtualmachine/${vmName}" -n "${verifyTargetNs}" -o json)"; then
        printf 'ERROR: Cannot read VM %s on destination\n' "${vmName}" >&2
        (( ++failed ))
        continue
      fi
      if printf '%s' "${vmJson}" | WithXtraceOff jq -e --arg pvc "${expectedPvc}" \
        'any(.spec.template.spec.volumes[]?;
          .dataVolume.name==$pvc or .persistentVolumeClaim.claimName==$pvc)' \
        1>/dev/null; then
        attached=1
      fi
      if (( attached == 0 )); then
        printf 'ERROR: VM %s on destination does not have PVC %s attached as a volume\n' \
          "${vmName}" "${expectedPvc}" >&2
        (( ++failed ))
      fi
    done
    (( failed == 0 ))
  } || rc=$?
  if [[ "${wasTracing}" == true ]]; then
    set -x
  fi
  return "${rc}"
}

function VerifyPvcIntegrity () {
  [[ "${pvcCheck}" == 'true' ]] || return 77

  typeset wasTracing=false
  [[ $- == *x* ]] && wasTracing=true
  set +x
  typeset -i rc=0
  {
    typeset -i i failed=0
    for ((i = 1; i <= verifyVmCount; i++)); do
      typeset vmName=''
      vmName="$(VmName "${i}")"
      typeset pvcName="${vmName}-rootdisk"
      typeset pvcJson=''
      if ! pvcJson="$(DestOc get "pvc/${pvcName}" -n "${verifyTargetNs}" -o json)"; then
        printf 'ERROR: PVC %s not found or unreadable on destination for VM %s\n' "${pvcName}" "${vmName}" >&2
        (( ++failed ))
        continue
      fi

      typeset phase=''
      phase="$(printf '%s' "${pvcJson}" | WithXtraceOff jq -r '.status.phase // ""')"
      if [[ "${phase}" != 'Bound' ]]; then
        printf 'ERROR: PVC %s on destination has phase=%s, expected Bound\n' "${pvcName}" "${phase}" >&2
        (( ++failed ))
      fi

      typeset capacityStr=''
      capacityStr="$(printf '%s' "${pvcJson}" | WithXtraceOff jq -r '.status.capacity.storage // ""')"
      printf 'INFO: PVC %s status.capacity.storage=%s\n' "${pvcName}" "${capacityStr:-<empty>}" >&2

      typeset srcPvcJson=''
      typeset -i srcLookupRc=0
      srcPvcJson="$(SourceOc get "pvc/${pvcName}" -n "${verifyVmNs}" \
        -o json --ignore-not-found)" || srcLookupRc=$?
      if (( srcLookupRc != 0 )); then
        printf 'ERROR: source PVC %s lookup failed (rc=%d); not treating as absent\n' \
          "${pvcName}" "${srcLookupRc}" >&2
        (( ++failed ))
      elif [[ -n "${srcPvcJson}" ]]; then
        typeset srcSize='' dstSize='' srcModes='' dstModes='' srcVolMode='' dstVolMode=''
        srcSize="$(printf '%s' "${srcPvcJson}" | WithXtraceOff jq -r '.spec.resources.requests.storage // ""')"
        dstSize="$(printf '%s' "${pvcJson}" | WithXtraceOff jq -r '.spec.resources.requests.storage // ""')"
        srcModes="$(printf '%s' "${srcPvcJson}" | WithXtraceOff jq -r '(.spec.accessModes // []) | sort | join(",")')"
        dstModes="$(printf '%s' "${pvcJson}" | WithXtraceOff jq -r '(.spec.accessModes // []) | sort | join(",")')"
        srcVolMode="$(printf '%s' "${srcPvcJson}" | WithXtraceOff jq -r '.spec.volumeMode // ""')"
        dstVolMode="$(printf '%s' "${pvcJson}" | WithXtraceOff jq -r '.spec.volumeMode // ""')"
        typeset srcBytes='' dstBytes=''
        srcBytes="$(KubeQuantityToBytes "${srcSize}")" || srcBytes=''
        dstBytes="$(KubeQuantityToBytes "${dstSize}")" || dstBytes=''
        if [[ -z "${srcBytes}" || -z "${dstBytes}" || "${dstBytes}" != "${srcBytes}" ]]; then
          printf 'ERROR: PVC %s requested storage dest=%s source=%s\n' \
            "${pvcName}" "${dstSize}" "${srcSize}" >&2
          (( ++failed ))
        fi
        if [[ "${dstModes}" != "${srcModes}" ]]; then
          printf 'ERROR: PVC %s accessModes dest=%s source=%s\n' \
            "${pvcName}" "${dstModes}" "${srcModes}" >&2
          (( ++failed ))
        fi
        if [[ "${dstVolMode}" != "${srcVolMode}" ]]; then
          printf 'ERROR: PVC %s volumeMode dest=%s source=%s\n' \
            "${pvcName}" "${dstVolMode}" "${srcVolMode}" >&2
          (( ++failed ))
        fi
      else
        printf 'INFO: source PVC %s not present; comparing destination against expected env only\n' \
          "${pvcName}" >&2
      fi

      if [[ -n "${rootdiskSize}" ]]; then
        typeset requestedSize='' requestedBytes='' expectedBytes=''
        requestedSize="$(printf '%s' "${pvcJson}" | WithXtraceOff jq -r '.spec.resources.requests.storage // ""')"
        requestedBytes="$(KubeQuantityToBytes "${requestedSize}")" || requestedBytes=''
        expectedBytes="$(KubeQuantityToBytes "${rootdiskSize}")" || expectedBytes=''
        if [[ -z "${requestedBytes}" || -z "${expectedBytes}" || "${requestedBytes}" != "${expectedBytes}" ]]; then
          printf 'ERROR: PVC %s requested storage=%s, expected %s (MTV_VM_ROOTDISK_SIZE)\n' \
            "${pvcName}" "${requestedSize}" "${rootdiskSize}" >&2
          (( ++failed ))
        fi
      fi

      if [[ -n "${rootdiskAccessMode}" ]]; then
        typeset hasMode=''
        hasMode="$(printf '%s' "${pvcJson}" | WithXtraceOff jq -r --arg m "${rootdiskAccessMode}" \
          'any(.spec.accessModes[]?; . == $m)')"
        if [[ "${hasMode}" != 'true' ]]; then
          printf 'ERROR: PVC %s accessModes missing %s (MTV_VM_ROOTDISK_ACCESS_MODE)\n' \
            "${pvcName}" "${rootdiskAccessMode}" >&2
          (( ++failed ))
        fi
      fi

      if [[ -n "${rootdiskVolumeMode}" ]]; then
        typeset volMode=''
        volMode="$(printf '%s' "${pvcJson}" | WithXtraceOff jq -r '.spec.volumeMode // ""')"
        if [[ "${volMode}" != "${rootdiskVolumeMode}" ]]; then
          printf 'ERROR: PVC %s volumeMode=%s, expected %s (MTV_VM_ROOTDISK_VOLUME_MODE)\n' \
            "${pvcName}" "${volMode}" "${rootdiskVolumeMode}" >&2
          (( ++failed ))
        fi
      fi
    done
    (( failed == 0 ))
  } || rc=$?
  if [[ "${wasTracing}" == true ]]; then
    set -x
  fi
  return "${rc}"
}

function RunVerification () {
  ResolveVerifyKubeconfigs
  typeset -i verifyRc=0
  RunOptionalCheck 'Verification: Destination VMIs Running' VerifyMigration || verifyRc=$?
  RunOptionalCheck 'Verification: Destination VM runStrategy' VerifyDestVmsRunStrategy || verifyRc=$?
  RunOptionalCheck 'Verification: Source VMIM Not Failed' VerifySourceVmimNotFailed || verifyRc=$?
  RunOptionalCheck 'Verification: VM SSH Port Probe' VerifyAllVmsSsh || verifyRc=$?
  RunOptionalCheck 'Verification: Destination SSH Login' WaitDestSshReady || verifyRc=$?
  RunOptionalCheck 'Verification: VM Data Integrity' VerifyVmDataIntegrity || verifyRc=$?
  RunOptionalCheck 'Verification: Guest Disk I/O' VerifyGuestDiskIo || verifyRc=$?
  RunOptionalCheck 'Verification: Guest Network Reachability' VerifyGuestNetwork || verifyRc=$?
  RunOptionalCheck 'Verification: PVC Attachment' VerifyPvcAttachment || verifyRc=$?
  RunOptionalCheck 'Verification: PVC Integrity' VerifyPvcIntegrity || verifyRc=$?
  return "${verifyRc}"
}

# KUBECONFIG is checked before xtrace so the path is not logged.
if [[ -z "${KUBECONFIG:-}" || ! -r "${KUBECONFIG}" ]]; then
  printf 'KUBECONFIG not set, skipping\n' >&2
  exit 2
fi

if [[ -n "${SHARED_DIR:-}" && -s "${SHARED_DIR}/proxy-conf.sh" ]]; then
  # shellcheck disable=SC1091
  source "${SHARED_DIR}/proxy-conf.sh"
fi

set -x

command -v oc 1>/dev/null || { printf 'ERROR: oc not found\n' >&2; exit 1; }
command -v jq 1>/dev/null || { printf 'ERROR: jq not found\n' >&2; exit 1; }

typeset -i vmCount="${P2P_HS_VM_COUNT:-2}"
typeset -i migrationPollInterval="${MTV_HS_MIGRATION_POLL_INTERVAL_SECONDS:-30}"
typeset -i syncStuckMinutes="${MTV_HS_SYNC_STUCK_MINUTES:-20}"
typeset -i verifyVmCount="${MTV_TEST_VM_COUNT:-2}"
typeset -i sshWaitSeconds="${MTV_VM_SSH_WAIT_SECONDS:-600}"
typeset -i sourceSpokeIndex="${MTV_SOURCE_SPOKE_INDEX:-0}"
typeset -i destSpokeIndex="${MTV_DEST_SPOKE_INDEX:-1}"
typeset spokeIndex="${MTV_HS_SPOKE_INDEX:-1}"
typeset isCclmDebugMode="${P2P_CCLM_DEBUG_MODE:-false}"
typeset cclmDirection="${P2P_MIGRATION_DIRECTION:-both}"
typeset mtvNamespace="${MTV_NAMESPACE:-openshift-mtv}"
typeset planType="${MTV_HS_PLAN_TYPE:-live}"
typeset verifyPlanType="${MTV_PLAN_TYPE:-live}"
typeset cnvNamespace="${MTV_HS_CNV_NAMESPACE:-openshift-cnv}"
typeset kubevirtName="${MTV_HS_KUBEVIRT_NAME:-kubevirt-kubevirt-hyperconverged}"
typeset hcoName="${MTV_HS_HCO_NAME:-kubevirt-hyperconverged}"
typeset ensureDlm="${MTV_HS_ENSURE_DECENTRALIZED_LIVE_MIGRATION:-true}"
typeset forkliftName="${MTV_HS_FORKLIFT_CONTROLLER_NAME:-forklift-controller}"
typeset planReadyTimeout="${MTV_HS_PLAN_READY_TIMEOUT:-15m}"
typeset migrationTimeout="${MTV_HS_MIGRATION_TIMEOUT:-15m}"
typeset inventoryRefreshWait="${MTV_HS_PROVIDER_INVENTORY_REFRESH_WAIT:-5m}"
typeset syncControllerWait="${MTV_HS_SYNC_CONTROLLER_WAIT:-10m}"
typeset vmSshVerify="${MTV_VM_SSH_VERIFY:-true}"
typeset vmGuestExec="${MTV_VM_GUEST_EXEC:-true}"
typeset dataIntegrity="${MTV_VM_DATA_INTEGRITY:-true}"
typeset pvcCheck="${MTV_PVC_CHECK:-true}"
typeset sshUser="${MTV_VM_SSH_USER:-cloud-user}"
typeset sshKeyName="${MTV_VM_SSH_KEY_NAME:-cclm-vm-ssh-key}"
typeset vmNameSingle="${MTV_TEST_VM_NAME:-test-vm-1}"
typeset spokeVmPrefix="${P2P_HS_SPOKE_VM_PREFIX:-test-vm}"
typeset verifyVmNs="${MTV_TEST_VM_NAMESPACE:-vm-migration-test}"
typeset verifyTargetNs="${MTV_TEST_VM_TARGET_NAMESPACE:-${verifyVmNs}}"
# Unset-only defaults: an explicit empty value skips that PVC assertion.
typeset rootdiskSize="${MTV_VM_ROOTDISK_SIZE-32Gi}"
typeset rootdiskAccessMode="${MTV_VM_ROOTDISK_ACCESS_MODE-ReadWriteMany}"
typeset rootdiskVolumeMode="${MTV_VM_ROOTDISK_VOLUME_MODE-Block}"

typeset hubProvider="${MTV_HS_HUB_PROVIDER:-host}"
typeset spokeProvider="${MTV_HS_SPOKE_PROVIDER:-spoke-1}"
typeset fwdSrcProv="${MTV_SRC_PROVIDER:-${hubProvider}}"
typeset fwdDstProv="${MTV_DST_PROVIDER:-${spokeProvider}}"
typeset fwdNetMap="${MTV_FWD_NETWORK_MAP:-${MTV_HS_HUB_TO_SPOKE_NETWORK_MAP:-hub-to-spoke-network-map}}"
typeset fwdStorMap="${MTV_FWD_STORAGE_MAP:-${MTV_HS_HUB_TO_SPOKE_STORAGE_MAP:-hub-to-spoke-storage-map}}"
typeset fwdPlan="${MTV_FWD_PLAN:-${MTV_HS_HUB_TO_SPOKE_PLAN:-cclm-hub-to-spoke-plan}}"
typeset fwdMig="${MTV_FWD_MIGRATION:-${MTV_HS_HUB_TO_SPOKE_MIGRATION:-cclm-hub-to-spoke-run-1}}"
typeset fwdVmPrefix="${MTV_FWD_VM_PREFIX:-${MTV_HS_HUB_VM_PREFIX:-hub-vm}}"
typeset fwdVmNs="${MTV_FWD_VM_NAMESPACE:-${MTV_HS_HUB_VM_NAMESPACE:-vm-migration-test}}"
typeset revSrcProv="${MTV_REV_SRC_PROVIDER:-${spokeProvider}}"
typeset revDstProv="${MTV_REV_DST_PROVIDER:-${hubProvider}}"
typeset revNetMap="${MTV_REV_NETWORK_MAP:-${MTV_HS_SPOKE_TO_HUB_NETWORK_MAP:-spoke-to-hub-network-map}}"
typeset revStorMap="${MTV_REV_STORAGE_MAP:-${MTV_HS_SPOKE_TO_HUB_STORAGE_MAP:-spoke-to-hub-storage-map}}"
typeset revPlan="${MTV_REV_PLAN:-${MTV_HS_SPOKE_TO_HUB_PLAN:-cclm-spoke-to-hub-plan}}"
typeset revMig="${MTV_REV_MIGRATION:-${MTV_HS_SPOKE_TO_HUB_MIGRATION:-cclm-spoke-to-hub-run-1}}"
typeset revVmPrefix="${MTV_REV_VM_PREFIX:-${MTV_HS_SPOKE_VM_PREFIX:-${spokeVmPrefix}}}"
typeset revVmNs="${MTV_REV_VM_NAMESPACE:-${MTV_HS_SPOKE_VM_NAMESPACE:-${verifyVmNs}}}"

typeset spokeKubeconfig='' destKubeconfig=''
typeset verifySourceKubeconfig='' verifyDestKubeconfig=''
typeset virtctlBin='' sshKeyFile='' sshReady=false
typeset cclmCaseOwner=false
typeset cclmResultsDir="${CCLM_RESULTS_DIR:-/tmp/cclm-ote-results}"
trap OnExit EXIT
ClaimOrExitCase

if [[ "${isCclmDebugMode}" == 'true' ]]; then
  set +e
  ( set -euo pipefail; shopt -s inherit_errexit; RunMigrations )
  typeset -i migRc=$?
  set -e
  if (( migRc != 0 )); then
    printf 'WARNING: migration checks failed (rc=%d); debug mode continues\n' "${migRc}" >&2
  fi
else
  RunMigrations
fi

RunVerification
true

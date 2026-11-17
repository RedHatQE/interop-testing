#!/bin/bash
# Two-spoke CCLM forward and return migration for the ACM+Virt OTE scenarios.
#
# Assumes the hub, both spokes, ACM, CNV, ODF, Submariner, and MTV are already
# installed. Does not install clusters. Does not write JUnit. openshift-tests
# records each case from this process exit code (0 pass, 1 fail, 2 skip).
#
# The four step JUnit files reuse the same testcase names. Each OTE name is the
# JUnit name prefixed with the suite that emitted it:
#   [cclm-live-migration]              spoke-1 to spoke-2
#   [cclm-migration-verify]            post-migration checks on spoke-2
#   [cclm-live-migration-return]       spoke-2 back to spoke-1
#   [cclm-migration-verify-return]     post-migration checks on spoke-1
#
# CCLM_CASE selects which recorded result this process exits with. The first
# process runs both legs once. Later processes wait and reuse that result.
#
# Pass/fail conditions are ported from:
#   p2p-mtv-execute-live-migration-commands.sh
#   p2p-mtv-verify-migration-commands.sh
# The return leg is the same code with the return-step defaults.
set -euo pipefail
shopt -s inherit_errexit

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

function HasCaseRecord () {
  typeset key
  key="$(CaseKey "${1:?}")"
  [[ -f "${cclmResultsDir}/${key}" ]]
}

function ReadCaseRc () {
  typeset key
  key="$(CaseKey "${1:?}")"
  if [[ -f "${cclmResultsDir}/${key}" ]]; then
    cat "${cclmResultsDir}/${key}"
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
    if (( waited >= 5400 )); then
      printf 'ERROR: timed out waiting for the two-spoke CCLM result\n' >&2
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

# RunCheckContinue — record the check result and keep going.
# The execute step treats the SSH probe as best-effort.
function RunCheckContinue () {
  typeset name="${1:?}"; (($#)) && shift
  : "${name}"
  typeset -i rc=0
  "$@" || rc=$?
  RecordCase "${name}" "${rc}"
  return 0
}

# RunOptionalCheck — 77 is a skip. A failure is recorded and does not stop later checks.
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

function CleanupSecrets () {
  typeset wasTracing=false
  if [[ $- == *x* ]]; then
    wasTracing=true
  fi
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

function DumpDiagnostics () { true; }

function ResolveProviderName () {
    typeset -n _out="${1:?}"; (($#)) && shift
    typeset spokeIndex="${1:?}"; (($#)) && shift
    typeset sharedFile="${SHARED_DIR}/mtv-acm-provider-name-${spokeIndex}"

    [[ -n "${_out}" ]] && return 0
    [[ -s "${sharedFile}" ]] || {
        printf 'ERROR: no provider name for spoke index %s (set MTV_SOURCE_PROVIDER/' "${spokeIndex}" >&2
        printf 'MTV_DESTINATION_PROVIDER, or run p2p-mtv-wait-acm-providers first)\n' >&2
        return 1
    }
    _out="$(tr -d '[:space:]' < "${sharedFile}")"
}

# ResolveProviderNames — fill in sourceProvider/destinationProvider from ACM discovery
# (p2p-mtv-wait-acm-providers), keyed by the same spoke index used for kubeconfig resolution,
# unless MTV_SOURCE_PROVIDER/MTV_DESTINATION_PROVIDER pinned them explicitly.

function ResolveProviderNames () {
    ResolveProviderName sourceProvider "${sourceSpokeIndex}"
    ResolveProviderName destinationProvider "${destSpokeIndex}"
}

# DumpDiagnostics — write MTV and VM state to ARTIFACT_DIR on failure.

function WaitProviderReady () {
    typeset providerName="${1:?}"; (($#)) && shift
    HubOc wait "provider/${providerName}" -n "${MTV_PROVIDER_NAMESPACE}" \
        --for=condition=Ready --timeout="${MTV_PLAN_READY_TIMEOUT}"
}

# WaitMapReady — gate until NetworkMap or StorageMap is Ready.

function WaitMapReady () {
    typeset kind="${1:?}"; (($#)) && shift
    typeset name="${1:?}"; (($#)) && shift
    HubOc wait "${kind}/${name}" -n "${MTV_PROVIDER_NAMESPACE}" \
        --for=condition=Ready --timeout="${MTV_PLAN_READY_TIMEOUT}"
}

# PreflightSourceVm — all source VMs must exist and be Running (live plan).

function PreflightSourceVm () {
    typeset -i i
    typeset vmName phase

    for (( i = 1; i <= vmCount; i++ )); do
        vmName="$(VmName "${i}")"
        SourceOc get "virtualmachine/${vmName}" -n "${MTV_TEST_VM_NAMESPACE}"

        phase="$(SourceOc get "virtualmachineinstance/${vmName}" -n "${MTV_TEST_VM_NAMESPACE}" \
            -o jsonpath='{.status.phase}' || true)"

        if [[ "${MTV_PLAN_TYPE}" == "live" ]]; then
            [[ "${phase}" == "Running" ]] \
                || { : "VMI ${vmName} not Running on source (phase=${phase})"; false; }
        fi
    done
}

# GetVmRootDiskStorageClass — resolve root disk StorageClass from source VM.

function GetVmRootDiskStorageClass () {
    typeset vmName="${1:?}"; (($#)) && shift
    typeset dvName pvcName scName

    dvName="$(SourceOc get "virtualmachine/${vmName}" -n "${MTV_TEST_VM_NAMESPACE}" \
        -o json |
        jq -r 'first(.spec.template.spec.volumes[]?.dataVolume.name // empty) // ""')"
    [[ -z "${dvName}" ]] && dvName="${vmName}-rootdisk"

    pvcName="$(SourceOc get "datavolume/${dvName}" -n "${MTV_TEST_VM_NAMESPACE}" \
        -o jsonpath='{.status.claimName}' || true)"
    [[ -z "${pvcName}" ]] && pvcName="${dvName}"

    scName="$(SourceOc get "persistentvolumeclaim/${pvcName}" -n "${MTV_TEST_VM_NAMESPACE}" \
        -o jsonpath='{.spec.storageClassName}' || true)"
    [[ -n "${scName}" ]] && printf '%s' "${scName}" && return 0

    SourceOc get pvc -n "${MTV_TEST_VM_NAMESPACE}" -o json |
        jq -r --arg pvc "${pvcName}" '
            (first(.items[] | select(.metadata.name == $pvc) | .spec.storageClassName) //
             first(.items[].spec.storageClassName) //
             "") // ""
        '
}

# PreflightVmStorageMapped — all source VM root disks must appear in StorageMap.

function PreflightVmStorageMapped () {
    typeset -i i
    typeset vmName vmSc scUid mapJson mapped

    mapJson="$(HubOc get "storagemap/${MTV_STORAGE_MAP_NAME}" -n "${MTV_PROVIDER_NAMESPACE}" -o json)"

    for (( i = 1; i <= vmCount; i++ )); do
        vmName="$(VmName "${i}")"
        vmSc="$(GetVmRootDiskStorageClass "${vmName}")"
        [[ -n "${vmSc}" ]] || { : "No StorageClass found for ${vmName}"; false; }

        scUid="$(SourceOc get "storageclass/${vmSc}" -o jsonpath='{.metadata.uid}' || true)"
        mapped="$(jq -r --arg sc "${vmSc}" --arg uid "${scUid}" \
            '[.spec.map[]? | select(.source.name == $sc or (.source.id != null and .source.id == $uid))] | length > 0' \
            <<<"${mapJson}")"
        [[ "${mapped}" == "true" ]] \
            || { : "VM ${vmName} root disk StorageClass ${vmSc} not mapped in ${MTV_STORAGE_MAP_NAME}"; false; }
    done
}

# PreflightHub — providers and maps must be Ready before Plan creation.

function PreflightHub () {
    WaitProviderReady "${sourceProvider}"
    WaitProviderReady "${destinationProvider}"
    WaitMapReady networkmap "${MTV_NETWORK_MAP_NAME}"
    WaitMapReady storagemap "${MTV_STORAGE_MAP_NAME}"
}

# HasDecentralizedLiveMigrationGate — KubeVirt must list DecentralizedLiveMigration.

function HasDecentralizedLiveMigrationGate () {
    typeset kc="${1:?}"; (($#)) && shift

    OcRole "${kc}" get kubevirt "${MTV_KUBEVIRT_NAME}" -n "${MTV_CNV_NAMESPACE}" -o json \
        | jq -e '.spec.configuration.developerConfiguration.featureGates // [] | contains(["DecentralizedLiveMigration"])' \
        1>&2
}

# EnsureDecentralizedLiveMigrationGate — enable CCLM via HCO featureGates.

function EnsureDecentralizedLiveMigrationGate () {
    typeset kc="${1:?}"; (($#)) && shift
    typeset hcoGate

    HasDecentralizedLiveMigrationGate "${kc}" && return 0

    hcoGate="$(OcRole "${kc}" get hyperconverged "${MTV_HCO_NAME}" -n "${MTV_CNV_NAMESPACE}" \
        -o jsonpath='{.spec.featureGates.decentralizedLiveMigration}' || true)"
    if [[ "${hcoGate}" != "true" ]]; then
        OcRole "${kc}" patch hyperconverged "${MTV_HCO_NAME}" -n "${MTV_CNV_NAMESPACE}" \
            --type merge -p '{"spec":{"featureGates":{"decentralizedLiveMigration":true}}}'
    fi

    WaitForDecentralizedLiveMigrationGate "${kc}" && return 0

    OcRole "${kc}" patch kubevirt "${MTV_KUBEVIRT_NAME}" -n "${MTV_CNV_NAMESPACE}" \
        --type merge -p '{"spec":{"configuration":{"developerConfiguration":{"featureGates":["DecentralizedLiveMigration"]}}}}'

    WaitForDecentralizedLiveMigrationGate "${kc}"
}

# WaitForDecentralizedLiveMigrationGate — poll KubeVirt until gate appears.

function WaitForDecentralizedLiveMigrationGate () {
    typeset kc="${1:?}"; (($#)) && shift
    typeset -i deadline=$((SECONDS + 600))

    while (( SECONDS < deadline )); do
        HasDecentralizedLiveMigrationGate "${kc}" && return 0
        sleep 10
    done
    false
}

# MaybeEnsureDecentralizedLiveMigration — enable CCLM gate on both spokes.

function MaybeEnsureDecentralizedLiveMigration () {
    [[ "${MTV_PLAN_TYPE}" != "live" ]] && return 0
    [[ "${MTV_ENSURE_DECENTRALIZED_LIVE_MIGRATION}" != "true" ]] && return 0

    EnsureDecentralizedLiveMigrationGate source
    EnsureDecentralizedLiveMigrationGate dest
}

# PreflightCclm — verify MTV controller and KubeVirt gates.

function PreflightCclm () {
    typeset fcGate envVal

    [[ "${MTV_PLAN_TYPE}" != "live" ]] && return 0

    fcGate="$(HubOc get "forkliftcontroller/${MTV_FORKLIFT_CONTROLLER_NAME}" -n "${MTV_NAMESPACE}" \
        -o jsonpath='{.spec.feature_ocp_live_migration}' || true)"
    [[ "${fcGate}" == "true" ]]

    envVal="$(HubOc get "deployment/${MTV_FORKLIFT_CONTROLLER_NAME}" -n "${MTV_NAMESPACE}" \
        -o jsonpath='{.spec.template.spec.containers[*].env[?(@.name=="FEATURE_OCP_LIVE_MIGRATION")].value}' \
        || true)"
    [[ "${envVal}" == "true" ]]

    HasDecentralizedLiveMigrationGate source
    HasDecentralizedLiveMigrationGate dest
}

# WaitForSyncControllerReady — CCLM requires sync controller on both spokes.

function WaitForSyncControllerReady () {
    typeset kc="${1:?}"; (($#)) && shift

    OcRole "${kc}" wait deployment/virt-synchronization-controller \
        -n "${MTV_CNV_NAMESPACE}" --for=condition=Available --timeout="${MTV_SYNC_CONTROLLER_WAIT}"
}

# MaybeWaitForSyncControllers — wait for sync controller deployments on both spokes.

function MaybeWaitForSyncControllers () {
    [[ "${MTV_PLAN_TYPE}" != "live" ]] && return 0

    WaitForSyncControllerReady source
    WaitForSyncControllerReady dest
}

# PreflightSubmarinerNoGlobalnet — Globalnet breaks pod IP CCLM sync routing.

function PreflightSubmarinerNoGlobalnet () {
    typeset kc="${1:?}"; (($#)) && shift

    ! OcRole "${kc}" get daemonset submariner-globalnet \
        -n submariner-operator
}

# MaybePreflightSubmarinerNoGlobalnet — both spokes must not run Globalnet.

function MaybePreflightSubmarinerNoGlobalnet () {
    [[ "${MTV_PLAN_TYPE}" != "live" ]] && return 0

    PreflightSubmarinerNoGlobalnet source
    PreflightSubmarinerNoGlobalnet dest
}

# MigrationPipelinePhase — read one pipeline step phase for a VM from Migration status.

function MigrationPipelinePhase () {
    typeset vmName="${1:?}"; (($#)) && shift
    typeset stepName="${1:?}"; (($#)) && shift
    typeset migJson phase

    migJson="$(HubOc get "migration/${MTV_MIGRATION_NAME}" -n "${MTV_PROVIDER_NAMESPACE}" -o json || true)"
    [[ -n "${migJson}" ]] || return 0

    phase="$(jq -r --arg vm "${vmName}" --arg step "${stepName}" \
        '.status.vms[]? | select(.name == $vm) | .pipeline[]? | select(.name == $step) | .phase' \
        <<<"${migJson}" | head -1)"
    [[ -n "${phase}" && "${phase}" != "null" ]] && printf '%s' "${phase}"
    true
}

# VmimPhase — read VirtualMachineInstanceMigration phase for a specific VM on a spoke.
# Filters by the vmim's vmi name label to handle multi-VM migration plans correctly.

function CheckSyncStuck () {
    typeset -i i anyRunning=0
    typeset syncPhase vmName

    [[ "${MTV_PLAN_TYPE}" != "live" ]] && return 0
    (( syncStuckMinutes > 0 )) || return 0

    for (( i = 1; i <= vmCount; i++ )); do
        vmName="$(VmName "${i}")"
        syncPhase="$(MigrationPipelinePhase "${vmName}" "Synchronization")"
        [[ "${syncPhase}" == "Running" ]] || continue

        (( anyRunning++ )) || true
        (( syncPhaseStartedAt )) || syncPhaseStartedAt="${SECONDS}"

        if (( SECONDS - syncPhaseStartedAt >= syncStuckMinutes * 60 )); then
            typeset srcVmimPhase destVmimPhase
            srcVmimPhase="$(VmimPhase source "${MTV_TEST_VM_NAMESPACE}" "${vmName}")"
            destVmimPhase="$(VmimPhase dest "${targetNs}" "${vmName}")"

            if [[ "${srcVmimPhase}" == "Synchronizing" && "${destVmimPhase}" == "WaitingForSync" ]]; then
                printf 'ERROR: Synchronization stuck >%dm on %s (source=%s, dest=%s)\n' \
                    "${syncStuckMinutes}" "${vmName}" "${srcVmimPhase}" "${destVmimPhase}" >&2
                DumpDiagnostics
                false
            fi
        fi
    done

    (( anyRunning )) || syncPhaseStartedAt=0
    true
}

# RefreshProviderInventory — re-scan spoke KubeVirt inventory before live Plan validation.

function RefreshProviderInventory () {
    typeset providerName="${1:?}"; (($#)) && shift
    typeset ts

    ts="$(date -u +%s)"
    HubOc annotate "provider/${providerName}" -n "${MTV_PROVIDER_NAMESPACE}" \
        "forklift.konveyor.io/inventory-refresh=${ts}" --overwrite
}

# RefreshProvidersForLivePlan — both providers must reflect current KubeVirt feature gates.

function RefreshProvidersForLivePlan () {
    [[ "${MTV_PLAN_TYPE}" != "live" ]] && return 0

    RefreshProviderInventory "${sourceProvider}"
    RefreshProviderInventory "${destinationProvider}"
    HubOc wait "provider/${sourceProvider}" -n "${MTV_PROVIDER_NAMESPACE}" \
        --for=condition=Ready --timeout="${MTV_PROVIDER_INVENTORY_REFRESH_WAIT}"
    HubOc wait "provider/${destinationProvider}" -n "${MTV_PROVIDER_NAMESPACE}" \
        --for=condition=Ready --timeout="${MTV_PROVIDER_INVENTORY_REFRESH_WAIT}"
}

# CleanupDestinationStaleResources — remove stale VM/DV/PVC artifacts on the destination.
# Required before a return-leg Plan when the destination may still hold the original
# pre-migration VMs (MTV leaves them in Stopped state after the forward migration).
# --ignore-not-found=true handles the "already gone" case; real delete failures
# (e.g. timeout) are propagated so the caller can decide whether to abort.

function CleanupDestinationStaleResources () {
    typeset -i i
    typeset vmName dvName

    for (( i = 1; i <= vmCount; i++ )); do
        vmName="$(VmName "${i}")"
        dvName="${vmName}-rootdisk"

        DestOc delete "virtualmachine/${vmName}" -n "${targetNs}" \
            --ignore-not-found=true --timeout=2m
        DestOc delete "datavolume/${dvName}" -n "${targetNs}" \
            --ignore-not-found=true --timeout=2m
        DestOc delete "pvc/${dvName}" -n "${targetNs}" \
            --ignore-not-found=true --timeout=2m
    done
    true
}

# ApplyPlan — create or update MTV Plan CR including all VMs via jq marshalling.

function ApplyPlan () {
    typeset -i i
    typeset vmsJson="[]"
    typeset planJson

    for (( i = 1; i <= vmCount; i++ )); do
        vmsJson="$(jq -cn \
            --argjson vms "${vmsJson}" \
            --arg name "$(VmName "${i}")" \
            --arg ns "${MTV_TEST_VM_NAMESPACE}" \
            '$vms + [{"name": $name, "namespace": $ns}]')"
    done

    planJson="$(jq -cn \
        --arg planName "${MTV_PLAN_NAME}" \
        --arg ns "${MTV_PROVIDER_NAMESPACE}" \
        --arg srcProvider "${sourceProvider}" \
        --arg dstProvider "${destinationProvider}" \
        --arg tgtNs "${targetNs}" \
        --arg netMap "${MTV_NETWORK_MAP_NAME}" \
        --arg storMap "${MTV_STORAGE_MAP_NAME}" \
        --argjson vms "${vmsJson}" \
        --arg planType "${MTV_PLAN_TYPE}" \
        '{
            "apiVersion": "forklift.konveyor.io/v1beta1",
            "kind": "Plan",
            "metadata": {"name": $planName, "namespace": $ns},
            "spec": {
                "provider": {
                    "source": {"name": $srcProvider, "namespace": $ns},
                    "destination": {"name": $dstProvider, "namespace": $ns}
                },
                "targetNamespace": $tgtNs,
                "map": {
                    "network": {"name": $netMap, "namespace": $ns},
                    "storage": {"name": $storMap, "namespace": $ns}
                },
                "vms": $vms,
                "type": $planType
            }
        }')"

    printf '%s\n' "${planJson}" | {
        HubOc create -f - --dry-run=client -o json --save-config |
        jq -c .
    } | HubOc apply -f -
}

# WaitPlanReady — wait for Plan Ready condition.

function WaitPlanReady () {
    HubOc wait "plan/${MTV_PLAN_NAME}" -n "${MTV_PROVIDER_NAMESPACE}" \
        --for=condition=Ready --timeout="${MTV_PLAN_READY_TIMEOUT}"
}

# ApplyMigration — create Migration CR referencing the Plan.

function ApplyMigration () {
    # jq marshalling avoids raw heredoc expansion of YAML-special chars,
    # consistent with ApplyNetworkMap / ApplyStorageMap / ApplyPlan.
    jq -cn \
        --arg migName  "${MTV_MIGRATION_NAME}" \
        --arg ns       "${MTV_PROVIDER_NAMESPACE}" \
        --arg planName "${MTV_PLAN_NAME}" \
        '{
            "apiVersion": "forklift.konveyor.io/v1beta1",
            "kind": "Migration",
            "metadata": {"name": $migName, "namespace": $ns},
            "spec": {"plan": {"name": $planName, "namespace": $ns}}
        }' \
    | {
        HubOc create -f - --dry-run=client -o yaml --save-config
      } \
    | HubOc apply -f -
}

# ParseOcWaitDurationSeconds — convert oc wait duration (e.g. 2h, 15m) to seconds.

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

# PrintMigrationPipeline — log migration VM pipeline phases.

function PrintMigrationPipeline () {
    HubOc get "migration/${MTV_MIGRATION_NAME}" -n "${MTV_PROVIDER_NAMESPACE}" \
        -o jsonpath='{range .status.vms[*]}{.name}{"\n"}{range .pipeline[*]}  {.name}: {.phase}{"\n"}{end}{"\n"}{end}' \
        || true
}

# WaitMigrationSucceeded — poll until Migration Succeeded or Failed.

function WaitMigrationSucceeded () {
    typeset -i deadline
    typeset succeededStatus failedStatus msg

    deadline=$((SECONDS + $(ParseOcWaitDurationSeconds "${MTV_MIGRATION_TIMEOUT}")))

    while (( SECONDS < deadline )); do
        succeededStatus="$(HubOc get "migration/${MTV_MIGRATION_NAME}" -n "${MTV_PROVIDER_NAMESPACE}" \
            -o jsonpath='{.status.conditions[?(@.type=="Succeeded")].status}' || true)"
        failedStatus="$(HubOc get "migration/${MTV_MIGRATION_NAME}" -n "${MTV_PROVIDER_NAMESPACE}" \
            -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' || true)"
        msg="$(HubOc get "migration/${MTV_MIGRATION_NAME}" -n "${MTV_PROVIDER_NAMESPACE}" \
            -o jsonpath='{.status.conditions[?(@.type=="Succeeded")].message}' || true)"

        [[ "${succeededStatus}" == "True" ]] && return 0

        if [[ "${failedStatus}" == "True" ]]; then
            HubOc get "migration/${MTV_MIGRATION_NAME}" -n "${MTV_PROVIDER_NAMESPACE}" \
                -o jsonpath='{range .status.conditions[*]}{.type}{": "}{.status}{" — "}{.message}{"\n"}{end}' \
                1>&2 || true
            PrintMigrationPipeline 1>&2
            false
        fi

        CheckSyncStuck

        PrintMigrationPipeline
        : "Migration in progress${msg:+: ${msg}} (${SECONDS}/${deadline}s)"
        sleep "${migrationPollInterval}"
    done

    false
}

# VerifyMigration — all destination VMIs must be Running after migration.

function ExecuteSshProbe () {
    [[ "${vmSshVerify}" == "true" ]] || return 0
    [[ "${MTV_PLAN_TYPE}" == "live" ]] || return 0
    # Self-probe with vmCount=1 would use the same pod as both anchor and target.
    (( vmCount > 1 )) || return 0

    typeset -i i
    typeset -a vmNamesArr=()
    typeset -a launcherPodsArr=()

    # Collect virt-launcher pods for all migrated VMs on destination.
    # VM IPs and pod names are resolved inside set +x to avoid tracing
    # internal cluster endpoint identifiers into CI logs.
    for (( i = 1; i <= vmCount; i++ )); do
        typeset vmn pod
        vmn="$(VmName "${i}")"
        vmNamesArr+=("${vmn}")
        pod="$(DestOc get pods -n "${targetNs}" -o json \
            | jq -r --arg d "${vmn}" \
                'first(.items[]
                 | select(.metadata.labels["kubevirt.io/domain"]==$d)
                 | select(.status.phase=="Running")
                 | .metadata.name) // ""' \
            || true)"
        launcherPodsArr+=("${pod}")
    done

    typeset -i failed=0
    for (( i = 0; i < vmCount; i++ )); do
        typeset vmName
        vmName="${vmNamesArr[${i}]}"

        typeset -i anchorIdx=$(( (i + 1) % vmCount ))

        if [[ -z "${launcherPodsArr[${anchorIdx}]}" ]]; then
            : "No probe anchor available for SSH check on ${vmName}; skipping"
            continue
        fi

        # Resolve VM IP and exec the probe inside a set +x subshell to prevent
        # internal endpoint identifiers from appearing in the xtrace log.
        typeset probeRc=0
        ( set +x
          vmIp="$(DestOc get "virtualmachineinstance/${vmName}" -n "${targetNs}" \
              -o jsonpath='{.status.interfaces[0].ipAddress}' || true)"
          anchorPod="${launcherPodsArr[${anchorIdx}]}"
          [[ -n "${vmIp}" ]] || exit 2
          DestOc exec -n "${targetNs}" "${anchorPod}" -c compute -- \
              timeout 15 bash -c "echo > /dev/tcp/${vmIp}/22"
        ) || probeRc=$?

        case "${probeRc}" in
            0) : "SSH port 22 reachable on ${vmName}" ;;
            2) : "No IP on VMI ${vmName}; skipping SSH probe" ;;
            *) : "SSH port 22 not reachable on ${vmName} (rc=${probeRc})"
               (( ++failed )) ;;
        esac
    done

    (( failed == 0 ))
}

# JStep — run a function, append PASS/FAIL record to junitFile, propagate exit code.

function VmName () {
  typeset -i idx="${1:?}"; (($#)) && shift
  if (( vmCount == 1 )); then
    printf '%s' "${MTV_TEST_VM_NAME}"
  else
    printf '%s-%d' "${P2P_HS_SPOKE_VM_PREFIX:-test-vm}" "${idx}"
  fi
  true
}

# OcWithRedactedStderr — run a command with stdout unchanged and stderr passed through
# RedactOutput. Always uses /tmp (never TMPDIR/ARTIFACT_DIR) so unredacted oc errors
# cannot be collected as CI artifacts. xtrace is disabled so kubeconfig paths and
# command lines are not logged. A temp file is used instead of 2> >(RedactOutput >&2)
# because process substitution races under command substitution ($(...)).

function OcWithRedactedStderr () {
  typeset _wasTracing=''
  [[ $- == *x* ]] && _wasTracing=true || _wasTracing=false
  set +x

  typeset _errFile
  _errFile="$(mktemp /tmp/oc-stderr.XXXXXX)"
  typeset -i _rc=0
  "$@" 2>"${_errFile}" || _rc=$?
  if [[ -s "${_errFile}" ]]; then
    RedactOutput < "${_errFile}" >&2 || true
  fi
  rm -f "${_errFile}"

  if [[ "${_wasTracing}" == "true" ]]; then
    set -x
  fi
  return "${_rc}"
}

# HubOc — run oc against the ACM hub.

function ResolveSpokeKubeconfigs () {
  [[ -n "${SHARED_DIR}" ]]

  if [[ -z "${sourceKubeconfig}" ]]; then
    if (( sourceSpokeIndex == 0 )); then
      sourceKubeconfig="${KUBECONFIG}"
    elif [[ -r "${SHARED_DIR}/managed-cluster-kubeconfig-${sourceSpokeIndex}" ]]; then
      sourceKubeconfig="${SHARED_DIR}/managed-cluster-kubeconfig-${sourceSpokeIndex}"
    elif (( sourceSpokeIndex == 1 )) && [[ -r "${SHARED_DIR}/managed-cluster-kubeconfig" ]]; then
      sourceKubeconfig="${SHARED_DIR}/managed-cluster-kubeconfig"
    else
      printf 'ERROR: Source spoke kubeconfig not found for index %d\n' "${sourceSpokeIndex}" >&2
      false
    fi
  fi
  [[ -r "${sourceKubeconfig}" ]]

  if [[ -z "${destKubeconfig}" ]]; then
    if (( destSpokeIndex == 0 )); then
      destKubeconfig="${KUBECONFIG}"
    elif [[ -r "${SHARED_DIR}/managed-cluster-kubeconfig-${destSpokeIndex}" ]]; then
      destKubeconfig="${SHARED_DIR}/managed-cluster-kubeconfig-${destSpokeIndex}"
    elif (( destSpokeIndex == 1 )) && [[ -r "${SHARED_DIR}/managed-cluster-kubeconfig" ]]; then
      destKubeconfig="${SHARED_DIR}/managed-cluster-kubeconfig"
    else
      printf 'ERROR: Dest spoke kubeconfig not found for index %d\n' "${destSpokeIndex}" >&2
      false
    fi
  fi
  [[ -r "${destKubeconfig}" ]]
  true
}

# DumpDiagnostics — collect VM and VMIM state to ARTIFACT_DIR for debugging failures.
# Artifacts are publicly readable: no -o wide (pod IPs, node names), VMIMs are projected
# to phase/conditions (migrationState carries node names and addresses), and every
# output is passed through RedactOutput.

function VmimPhase () {
  typeset kc="${1:?}"; (($#)) && shift
  typeset ns="${1:?}"; (($#)) && shift
  typeset vmName="${1:?}"; (($#)) && shift

  OcRole "${kc}" get vmim -n "${ns}" -o json \
    | OcWithRedactedStderr jq -r --arg vm "${vmName}" \
      'first(.items[] | select(.spec.vmiName == $vm) | .status.phase) // ""'
}

# VerifyMigration — all destination VMIs must be Running after migration.

function VerifyMigration () {
  typeset -i i
  typeset vmName destPhase

  for (( i = 1; i <= vmCount; i++ )); do
    vmName="$(VmName "${i}")"
    destPhase="$(DestOc get "virtualmachineinstance/${vmName}" -n "${targetNs}" \
      -o jsonpath='{.status.phase}' || true)"
    [[ "${destPhase}" == "Running" ]] || {
      printf 'ERROR: VMI %s not Running on destination (phase=%s)\n' "${vmName}" "${destPhase}" >&2
      return 1
    }
  done
  true
}

# VerifyDestVmsRunStrategy — destination VMs must have runStrategy=Always after migration.
# Guards against OCPBUGS-101771 where Forklift leaves runStrategy=Halted after migration,
# silently breaking VM auto-restart (the migrated VM will not recover from a pod crash
# without a manual start). This is a Forklift bug that interop must detect, not patch.

function VerifyDestVmsRunStrategy () {
  typeset -i i
  typeset vmName strategy

  for (( i = 1; i <= vmCount; i++ )); do
    vmName="$(VmName "${i}")"
    strategy="$(DestOc get "virtualmachine/${vmName}" -n "${targetNs}" \
      -o jsonpath='{.spec.runStrategy}' || true)"
    [[ "${strategy}" == "Always" ]] || {
      printf "ERROR: VM %s runStrategy='%s', expected 'Always' (OCPBUGS-101771)\n" "${vmName}" "${strategy}" >&2
      return 1
    }
  done
  true
}

# VerifySourceVmimNotFailed — source VMIMs must not be in Failed phase after migration.
# Guards against OCPBUGS-99403 where a mid-migration QEMU socket disruption causes the
# guest to crash on source while Forklift reports Succeeded based on target-side status only.
# An absent VMIM (phase="") means it was cleaned up after success — that is expected.

function VerifySourceVmimNotFailed () {
  typeset -i i
  typeset vmName srcVmimPhase

  for (( i = 1; i <= vmCount; i++ )); do
    vmName="$(VmName "${i}")"
    srcVmimPhase="$(VmimPhase source "${MTV_TEST_VM_NAMESPACE}" "${vmName}")" || {
      printf 'ERROR: failed to query source VMIM for %s\n' "${vmName}" >&2
      return 1
    }
    [[ "${srcVmimPhase}" != "Failed" ]] || {
      printf 'ERROR: Source VMIM for %s is Failed — false-positive migration (OCPBUGS-99403)\n' "${vmName}" >&2
      return 1
    }
  done
  true
}

# VerifyAllVmsSsh — probe SSH port 22 on each migrated VM via a peer virt-launcher.
# Uses cross-VM probing: VM[i] is probed from VM[(i+1)%N]'s virt-launcher, so
# the anchor pod differs from the target VM (avoids hairpin NAT in masquerade mode).
# Skipped (SKIP JUnit record, rc=77) for vmCount=1 (no peer), non-live plans, or
# when MTV_VM_SSH_VERIFY=false. Hard fail: missing IP or unreachable port fails the step.

function VerifyAllVmsSsh () {
  [[ "${vmSshVerify}" == "true" ]] || return 77
  [[ "${MTV_PLAN_TYPE}" == "live" ]] || return 77
  (( vmCount > 1 )) || return 77

  typeset -a vmNamesArr=()
  typeset -a launcherPodsArr=()
  CollectDestLaunchers vmNamesArr launcherPodsArr

  typeset -i i failed=0
  for (( i = 0; i < vmCount; i++ )); do
    typeset vmName
    vmName="${vmNamesArr[${i}]}"

    typeset -i anchorIdx=$(( (i + 1) % vmCount ))

    if [[ -z "${launcherPodsArr[${anchorIdx}]}" ]]; then
      printf 'ERROR: no probe anchor for SSH check on %s\n' "${vmName}" >&2
      (( ++failed ))
      continue
    fi

    typeset probeRc=0
    ( set +x
      vmIp="$(DestOc get "virtualmachineinstance/${vmName}" -n "${targetNs}" \
        -o jsonpath='{.status.interfaces[0].ipAddress}' || true)"
      anchorPod="${launcherPodsArr[${anchorIdx}]}"
      [[ -n "${vmIp}" ]] || exit 2
      DestOc exec -n "${targetNs}" "${anchorPod}" -c compute -- \
        timeout 15 bash -c "echo > /dev/tcp/${vmIp}/22"
    ) || probeRc=$?

    case "${probeRc}" in
      0) : "SSH port 22 reachable on ${vmName}" ;;
      2) printf 'ERROR: no IP on VMI %s for SSH probe\n' "${vmName}" >&2
         (( ++failed )) ;;
      *) printf 'ERROR: SSH port 22 not reachable on %s (rc=%d)\n' "${vmName}" "${probeRc}" >&2
         (( ++failed )) ;;
    esac
  done

  (( failed == 0 ))
}

# RedactOutput — mask URLs, IPv4 addresses, AWS node hostnames (ip-A-B-C-D.*), and
# remaining dotted hostnames (api.cluster.example) in oc/ssh error text and artifacts.
# Bare hostnames must be last: URL/IP substitutions run first so they are not
# double-matched. Example: "lookup api.ci.l2s4.p1.openshiftapps.com on 172.30.0.10:53"
# becomes "lookup <REDACTED-HOST> on <REDACTED-IP>:53".

function RedactOutput () {
  sed -E -e 's#https?://[^[:space:]]+#<REDACTED-URL>#g' \
    -e 's#ip-[0-9]+-[0-9]+-[0-9]+-[0-9]+[.a-z0-9-]*#<REDACTED-NODE>#g' \
    -e 's#[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+#<REDACTED-IP>#g' \
    -e 's#([a-z0-9]([a-z0-9-]*[a-z0-9])?\.){2,}[a-z]+#<REDACTED-HOST>#g'
}

# KubeQuantityToBytes — convert a Kubernetes resource.Quantity (storage) to integer bytes.
# CDI/the API often rewrite "32Gi" as "34359738368"; string equality then false-fails.
# Accepts a bare integer or an integer plus a binary (Ki/Mi/Gi/Ti/Pi/Ei) or decimal
# (k/M/G/T/P/E) suffix. Prints the byte count on stdout; returns 1 if unparseable.

function KubeQuantityToBytes () {
  typeset q="${1:-}"
  [[ -n "${q}" ]] || return 1
  typeset num suffix
  if [[ "${q}" =~ ^([0-9]+)([A-Za-z]*)$ ]]; then
    num="${BASH_REMATCH[1]}"
    suffix="${BASH_REMATCH[2]}"
  else
    return 1
  fi
  typeset -i bytes=0
  case "${suffix}" in
    '') bytes="${num}" ;;
    Ki) bytes=$(( num * 1024 )) ;;
    Mi) bytes=$(( num * 1024 ** 2 )) ;;
    Gi) bytes=$(( num * 1024 ** 3 )) ;;
    Ti) bytes=$(( num * 1024 ** 4 )) ;;
    Pi) bytes=$(( num * 1024 ** 5 )) ;;
    Ei) bytes=$(( num * 1024 ** 6 )) ;;
    k)  bytes=$(( num * 1000 )) ;;
    M)  bytes=$(( num * 1000 ** 2 )) ;;
    G)  bytes=$(( num * 1000 ** 3 )) ;;
    T)  bytes=$(( num * 1000 ** 4 )) ;;
    P)  bytes=$(( num * 1000 ** 5 )) ;;
    E)  bytes=$(( num * 1000 ** 6 )) ;;
    *) return 1 ;;
  esac
  printf '%s' "${bytes}"
}

# EnsurePasswdEntry — the OpenSSH client refuses to run when the pod's random UID
# has no passwd entry; the cli-with-ssh image makes /etc/passwd group-writable.

function EnsurePasswdEntry () {
  # stdout discarded (boolean probe). stderr stays open so a missing whoami
  # or unexpected failure is visible in CI logs.
  whoami 1>/dev/null && return 0
  [[ -w /etc/passwd ]] || {
    printf 'ERROR: no passwd entry for uid %s and /etc/passwd is not writable\n' "$(id -u)" >&2
    return 1
  }
  printf '%s:x:%s:0:%s user:%s:/sbin/nologin\n' \
    "${USER_NAME:-default}" "$(id -u)" "${USER_NAME:-default}" "${HOME}" >> /etc/passwd
}

# InstallVirtctl — download virtctl matching the destination CNV version from its
# hyperconverged-cluster-cli-download route. Runs under set +x (route host is a cluster URL).

function InstallVirtctl () {
  typeset binDir="${TMPDIR:-/tmp}/cclm-verify-bin"
  mkdir -p "${binDir}"
  ( set +x
    typeset host
    host="$(DestOc get route hyperconverged-cluster-cli-download -n "${MTV_CNV_NAMESPACE}" \
      -o jsonpath='{.spec.host}')" || exit 1
    [[ -n "${host}" ]] || exit 1
    curl -kfsSL "https://${host}/amd64/linux/virtctl.tar.gz" | tar -xz -C "${binDir}"
  ) || return 1
  virtctlBin="${binDir}/virtctl"
  "${virtctlBin}" version --client 1>/dev/null
}

# PrepareSshAccess — key from SHARED_DIR (written by p2p-create-cclm-test-vms) + virtctl.

function PrepareSshAccess () {
  typeset wasTracing=false
  if [[ $- == *x* ]]; then
    wasTracing=true
  fi
  set +x
  typeset srcKey="${SHARED_DIR}/${MTV_VM_SSH_KEY_NAME}"
  [[ -s "${srcKey}" ]] || {
    printf 'ERROR: VM SSH key %s not found in SHARED_DIR\n' "${MTV_VM_SSH_KEY_NAME}" >&2
    { if [[ "${wasTracing}" == true ]]; then set -x; fi; return 1; }
  }
  sshKeyFile="/tmp/cclm-verify-ssh-key-$$"
  install -m 0600 "${srcKey}" "${sshKeyFile}" || { if [[ "${wasTracing}" == true ]]; then set -x; fi; return 1; }
  [[ -w "${HOME:-/}" ]] || export HOME="${TMPDIR:-/tmp}"
  EnsurePasswdEntry || { if [[ "${wasTracing}" == true ]]; then set -x; fi; return 1; }
  command -v ssh 1>/dev/null || { printf 'ERROR: ssh client not found in step image\n' >&2; { if [[ "${wasTracing}" == true ]]; then set -x; fi; return 1; }; }
  InstallVirtctl || { printf 'ERROR: failed to install virtctl from the destination cluster\n' >&2; { if [[ "${wasTracing}" == true ]]; then set -x; fi; return 1; }; }
  if [[ "${wasTracing}" == true ]]; then
    set -x
  fi
}

# VmSsh — run a command inside a destination VM via virtctl ssh (API server port-forward,
# so it works with masquerade networking). stdin is closed so loops are not consumed.
# KUBECONFIG must be set in the environment: the ssh ProxyCommand virtctl generates
# (virtctl port-forward --stdio) does not inherit a --kubeconfig flag.

function VmSsh () {
  typeset wasTracing=false
  if [[ $- == *x* ]]; then
    wasTracing=true
  fi
  set +x
  typeset vmName="${1:?}"; (($#)) && shift
  typeset cmd="${1:?}"; (($#)) && shift
  typeset -i rc=0
  KUBECONFIG="${destKubeconfig}" "${virtctlBin}" ssh "${sshUser}@vmi/${vmName}" \
    --namespace="${targetNs}" --identity-file="${sshKeyFile}" --known-hosts=/dev/null \
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

# VmSshChecked — VmSsh, logging the (redacted) tail of stderr on failure.

function VmSshChecked () {
  typeset vmName="${1:?}"
  typeset errFile="/tmp/cclm-verify-ssh-err-$$"
  typeset -i rc=0
  VmSsh "$@" 2>"${errFile}" || rc=$?
  if (( rc != 0 )); then
    printf 'ERROR: ssh command on %s failed (rc=%d): %s\n' "${vmName}" "${rc}" \
      "$(RedactOutput < "${errFile}" | tail -n 3 | tr '\n' ' ')" >&2
  fi
  return "${rc}"
}

# WaitDestSshReady — gate in-guest checks until every destination VM accepts an SSH login.
# MTV_VM_SSH_WAIT_SECONDS is one budget shared by all VMs (cloud-init may still be finishing);
# it must stay below the step timeout so JUnit and diagnostics are still written on failure.
# Skipped (return 77) when both MTV_VM_DATA_INTEGRITY and MTV_VM_GUEST_EXEC are false.

function WaitDestSshReady () {
  if [[ "${MTV_VM_DATA_INTEGRITY}" != 'true' && "${vmGuestExec}" != 'true' ]]; then
    return 77
  fi
  PrepareSshAccess || return 1

  typeset errFile="/tmp/cclm-verify-ssh-err-$$"
  typeset -i i deadline=$(( SECONDS + sshWaitSeconds ))
  for (( i = 1; i <= vmCount; i++ )); do
    typeset vmName; vmName="$(VmName "${i}")"
    typeset -i ready=0
    while :; do
      # set +x: avoid logging the full virtctl ssh command line on every 10s retry.
      if ( set +x; VmSsh "${vmName}" true 1>/dev/null 2>"${errFile}" ); then
        ready=1
        break
      fi
      (( SECONDS < deadline )) || break
      sleep 10
    done
    if (( ready == 0 )); then
      printf 'ERROR: SSH login to %s still failing after the %ds wait budget; last error: %s\n' \
        "${vmName}" "${sshWaitSeconds}" \
        "$(RedactOutput < "${errFile}" | tail -n 3 | tr '\n' ' ')" >&2
      return 1
    fi
  done
  sshReady=true
}

# VerifyVmDataIntegrity — verify that cloud-init marker files survive migration intact.
# p2p-create-cclm-test-vms injects a cloud-init runcmd step that writes
# /home/cloud-user/migration-marker.txt with content equal to the VM name.
# This function reads back that file on the destination over SSH and compares it to
# the expected VM name. Any VM whose marker is missing or different fails the step.

function VerifyVmDataIntegrity () {
  [[ "${MTV_VM_DATA_INTEGRITY}" == "true" ]] || return 77
  [[ "${sshReady}" == "true" ]] || {
    printf 'ERROR: destination SSH not ready; data integrity not checked\n' >&2
    return 1
  }

  # Disable xtrace: marker content must not appear in CI logs.
  typeset _wasTracing=''
  [[ $- == *x* ]] && _wasTracing=true || _wasTracing=false
  set +x

  typeset -i _rc=0
  {
    typeset -i i failed=0
    for (( i = 1; i <= vmCount; i++ )); do
      typeset vmName actualMarker=""
      vmName="$(VmName "${i}")"

      if ! actualMarker="$(VmSshChecked "${vmName}" 'cat /home/cloud-user/migration-marker.txt')"; then
        printf 'ERROR: Integrity marker missing or unreadable on %s\n' "${vmName}" >&2
        (( ++failed ))
        continue
      fi

      if [[ "${actualMarker%$'\r'}" == "${vmName}" ]]; then
        # Use printf >&2 (not : "...") — the null-command is invisible inside set +x.
        # Log the VM name only; never log raw marker content.
        printf 'INFO: data integrity verified for %s\n' "${vmName}" >&2
      else
        # Log only a mismatch indicator — never log raw marker content.
        printf 'ERROR: Data integrity FAIL for %s (marker mismatch)\n' "${vmName}" >&2
        (( ++failed ))
      fi
    done
    (( failed == 0 ))
  } || _rc=$?

  if [[ "${_wasTracing}" == "true" ]]; then
    set -x
  fi
  return "${_rc}"
}

# CollectDestLaunchers — fill nameref arrays of VM names and Running virt-launcher pods.
# Runs under set +x: pod names are internal cluster identifiers that must not appear
# in CI logs via xtrace variable-assignment tracing.
#
# Pod lookup uses two strategies to handle label differences after CCLM migration:
# 1. kubevirt.io/domain= label (standard KubeVirt label; may be absent post-CCLM).
# 2. Pod name prefix virt-launcher-<vmname>- (fallback; matches proven GetSourceVirtLauncherPod
#    pattern used in p2p-mtv-execute-hub-spoke-migration-commands.sh).
# All pods are fetched once with kubevirt.io=virt-launcher to scope the snapshot.

function CollectDestLaunchers () {
  typeset -n _names="${1:?}"; (($#)) && shift
  typeset -n _pods="${1:?}"; (($#)) && shift
  typeset -i i
  _names=()
  _pods=()

  # Disable xtrace: pod name assignments are printed by xtrace and must be suppressed.
  typeset _wasTracing=''
  [[ $- == *x* ]] && _wasTracing=true || _wasTracing=false
  set +x

  typeset -i _rc=0
  {
    # Snapshot all virt-launcher pods once — avoids N oc calls in the loop.
    typeset podsJson
    podsJson="$(DestOc get pods -n "${targetNs}" -l kubevirt.io=virt-launcher -o json || true)"

    for (( i = 1; i <= vmCount; i++ )); do
      typeset vmn pod
      vmn="$(VmName "${i}")"
      _names+=("${vmn}")

      # Strategy 1: kubevirt.io/domain label equals VM name.
      pod="$(printf '%s' "${podsJson}" \
        | OcWithRedactedStderr jq -r --arg d "${vmn}" \
          'first(.items[]
           | select(.metadata.labels["kubevirt.io/domain"]==$d)
           | select(.status.phase=="Running")
           | .metadata.name) // ""' \
        || true)"

      # Strategy 2: pod name prefix fallback (post-CCLM pods may lack the domain label).
      if [[ -z "${pod}" ]]; then
        pod="$(printf '%s' "${podsJson}" \
          | OcWithRedactedStderr jq -r --arg n "${vmn}" \
            'first(.items[]
             | select(.metadata.name | startswith("virt-launcher-" + $n + "-"))
             | select(.status.phase=="Running")
             | .metadata.name) // ""' \
          || true)"
      fi

      _pods+=("${pod}")
    done
  } || _rc=$?

  if [[ "${_wasTracing}" == "true" ]]; then
    set -x
  fi
  return "${_rc}"
}

# VerifyGuestDiskIo — write, fsync, checksum, and remove a scratch file inside each guest.
# Proves the migrated root disk is writable and readable after CCLM (not just VMI Running).
# Skipped (SKIP JUnit record, rc=77) when MTV_VM_GUEST_EXEC=false (e.g. cirros VMs).

function VerifyGuestDiskIo () {
  [[ "${vmGuestExec}" == "true" ]] || return 77
  [[ "${sshReady}" == "true" ]] || {
    printf 'ERROR: destination SSH not ready; guest disk I/O not checked\n' >&2
    return 1
  }

  typeset ioCmd='dd if=/dev/zero of=/tmp/cclm-io.bin bs=1M count=4 conv=fsync status=none && sha256sum /tmp/cclm-io.bin && rm -f /tmp/cclm-io.bin'
  typeset -i i failed=0
  for (( i = 1; i <= vmCount; i++ )); do
    typeset vmName; vmName="$(VmName "${i}")"
    if VmSshChecked "${vmName}" "${ioCmd}" 1>/dev/null; then
      : "Guest disk I/O succeeded on ${vmName}"
    else
      printf 'ERROR: guest disk I/O command failed on %s\n' "${vmName}" >&2
      (( ++failed ))
    fi
  done
  (( failed == 0 ))
}

# VerifyGuestNetwork — ping a peer VM IP from inside each guest (guest-level reachability).
# Distinct from the SSH TCP probe which runs in the virt-launcher pod, not the guest.
# Skipped (SKIP JUnit record, rc=77) for vmCount=1 (no peer) or when MTV_VM_GUEST_EXEC=false.

function VerifyGuestNetwork () {
  [[ "${vmGuestExec}" == "true" ]] || return 77
  (( vmCount > 1 )) || return 77
  [[ "${sshReady}" == "true" ]] || {
    printf 'ERROR: destination SSH not ready; guest network not checked\n' >&2
    return 1
  }

  typeset -i i failed=0
  for (( i = 1; i <= vmCount; i++ )); do
    typeset vmName peerName
    vmName="$(VmName "${i}")"
    peerName="$(VmName $(( i % vmCount + 1 )))"

    typeset probeRc=0
    # set +x: peer IP is an internal cluster address.
    ( set +x
      typeset peerIp
      peerIp="$(DestOc get "virtualmachineinstance/${peerName}" -n "${targetNs}" \
        -o jsonpath='{.status.interfaces[0].ipAddress}' || true)"
      [[ -n "${peerIp}" ]] || exit 2
      VmSshChecked "${vmName}" "ping -c 2 -W 5 ${peerIp}" 1>/dev/null
    ) || probeRc=$?

    case "${probeRc}" in
      0) : "Guest ping to peer succeeded on ${vmName}" ;;
      2) printf 'ERROR: no IP on peer VMI for guest network check on %s\n' "${vmName}" >&2
         (( ++failed )) ;;
      *) printf 'ERROR: guest ping to peer failed on %s (rc=%d)\n' "${vmName}" "${probeRc}" >&2
         (( ++failed )) ;;
    esac
  done
  (( failed == 0 ))
}

# VerifyPvcAttachment — verify the destination VM spec references the expected rootdisk PVC as a
# volume. Guards against Forklift silently detaching the PVC from the VM spec during migration
# while the VMI still appears Running (the VM would fail to restart after a pod crash).
# Skipped (rc=77) when MTV_PVC_CHECK=false.

function VerifyPvcAttachment () {
  [[ "${pvcCheck}" == "true" ]] || return 77

  # Disable xtrace: VM JSON may contain internal node hostnames and IP addresses
  # that must not appear in CI logs via xtrace variable-expansion tracing.
  typeset _wasTracing=''
  [[ $- == *x* ]] && _wasTracing=true || _wasTracing=false
  set +x

  typeset -i _rc=0
  {
    typeset -i i failed=0
    for (( i = 1; i <= vmCount; i++ )); do
      typeset vmName; vmName="$(VmName "${i}")"
      typeset expectedPvc="${vmName}-rootdisk"
      typeset -i attached=0

      # Fetch VM separately so an API/missing-VM error is reported with its real cause,
      # not misreported as "PVC not attached".
      typeset vmJson
      vmJson="$(DestOc get "virtualmachine/${vmName}" -n "${targetNs}" -o json)" || {
        printf 'ERROR: Cannot read VM %s on destination\n' "${vmName}" >&2
        (( ++failed ))
        continue
      }

      # jq -e exits 1 when any() returns false. stdout discarded (boolean only).
      # jq stderr is redacted so a parse error cannot dump VM JSON (IPs/hostnames)
      # into CI logs. []? tolerates a VM spec with no volumes field.
      if printf '%s' "${vmJson}" | OcWithRedactedStderr jq -e --arg pvc "${expectedPvc}" \
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
  } || _rc=$?

  if [[ "${_wasTracing}" == "true" ]]; then
    set -x
  fi
  return "${_rc}"
}

# VerifyPvcIntegrity — verify destination rootdisk PVC is Bound and that spec
# metadata survived migration. When the source PVC still exists, compare
# requested size, accessModes, and volumeMode to the destination. Always also
# assert dest against the create-time env (P2P_HS_VM_DISK_SIZE / RWX Block);
# source PVCs are deleted after some hub-spoke legs. Observed capacity is
# logged for human review (provisioners may round up).
# Skipped (rc=77) when MTV_PVC_CHECK=false.

function VerifyPvcIntegrity () {
  [[ "${pvcCheck}" == "true" ]] || return 77

  # Disable xtrace: PVC JSON may contain storage-provider annotations and internal
  # metadata fields that must not appear in CI logs via xtrace variable-expansion tracing.
  typeset _wasTracing=''
  [[ $- == *x* ]] && _wasTracing=true || _wasTracing=false
  set +x

  typeset -i _rc=0
  {
    typeset -i i failed=0
    for (( i = 1; i <= vmCount; i++ )); do
      typeset vmName; vmName="$(VmName "${i}")"
      typeset pvcName="${vmName}-rootdisk"

      typeset pvcJson
      # DestOc redacts oc stderr (URLs/IPs). Do not use 2>/dev/null — NotFound and
      # auth/network errors must still appear in CI logs after redaction.
      pvcJson="$(DestOc get "pvc/${pvcName}" -n "${targetNs}" -o json)" || {
        printf 'ERROR: PVC %s not found or unreadable on destination for VM %s\n' "${pvcName}" "${vmName}" >&2
        (( ++failed ))
        continue
      }

      # Phase check — PVC must be Bound.
      typeset phase
      phase="$(printf '%s' "${pvcJson}" | OcWithRedactedStderr jq -r '.status.phase // ""')"
      if [[ "${phase}" != "Bound" ]]; then
        printf 'ERROR: PVC %s on destination has phase=%s, expected Bound\n' "${pvcName}" "${phase}" >&2
        (( ++failed ))
      fi

      # Log observed capacity for human review; not a failure if it differs (provisioners may round up).
      # Use printf >&2 (not : "...") — the null-command is invisible inside set +x and produces no output.
      typeset capacityStr
      capacityStr="$(printf '%s' "${pvcJson}" | OcWithRedactedStderr jq -r '.status.capacity.storage // ""')"
      printf 'INFO: PVC %s status.capacity.storage=%s\n' "${pvcName}" "${capacityStr:-<empty>}" >&2

      # Source↔dest metadata comparison when the source PVC is still present.
      # StorageClass is not compared: MTV storage maps may remap it.
      # --ignore-not-found: empty stdout + rc=0 is a confirmed missing PVC
      # (hub-spoke cleanup). Any other oc failure (auth, connectivity, API)
      # is a hard fail — do not treat it as absent and skip the comparison.
      typeset srcPvcJson=""
      typeset -i srcLookupRc=0
      srcPvcJson="$(SourceOc get "pvc/${pvcName}" -n "${MTV_TEST_VM_NAMESPACE}" \
        -o json --ignore-not-found)" || srcLookupRc=$?
      if (( srcLookupRc != 0 )); then
        printf 'ERROR: source PVC %s lookup failed (rc=%d); not treating as absent\n' \
          "${pvcName}" "${srcLookupRc}" >&2
        (( ++failed ))
      elif [[ -n "${srcPvcJson}" ]]; then
        typeset srcSize dstSize srcModes dstModes srcVolMode dstVolMode
        srcSize="$(printf '%s' "${srcPvcJson}" | OcWithRedactedStderr jq -r '.spec.resources.requests.storage // ""')"
        dstSize="$(printf '%s' "${pvcJson}" | OcWithRedactedStderr jq -r '.spec.resources.requests.storage // ""')"
        srcModes="$(printf '%s' "${srcPvcJson}" | OcWithRedactedStderr jq -r '(.spec.accessModes // []) | sort | join(",")')"
        dstModes="$(printf '%s' "${pvcJson}" | OcWithRedactedStderr jq -r '(.spec.accessModes // []) | sort | join(",")')"
        srcVolMode="$(printf '%s' "${srcPvcJson}" | OcWithRedactedStderr jq -r '.spec.volumeMode // ""')"
        dstVolMode="$(printf '%s' "${pvcJson}" | OcWithRedactedStderr jq -r '.spec.volumeMode // ""')"
        typeset srcBytes dstBytes
        srcBytes="$(KubeQuantityToBytes "${srcSize}")" || srcBytes=""
        dstBytes="$(KubeQuantityToBytes "${dstSize}")" || dstBytes=""
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

      # Size check — compare requested storage as Kubernetes quantities (bytes),
      # not strings: dest may be "34359738368" while MTV_VM_ROOTDISK_SIZE is "32Gi".
      if [[ -n "${rootdiskSize}" ]]; then
        typeset requestedSize requestedBytes expectedBytes
        requestedSize="$(printf '%s' "${pvcJson}" | OcWithRedactedStderr jq -r '.spec.resources.requests.storage // ""')"
        requestedBytes="$(KubeQuantityToBytes "${requestedSize}")" || requestedBytes=""
        expectedBytes="$(KubeQuantityToBytes "${rootdiskSize}")" || expectedBytes=""
        if [[ -z "${requestedBytes}" || -z "${expectedBytes}" || "${requestedBytes}" != "${expectedBytes}" ]]; then
          printf 'ERROR: PVC %s requested storage=%s, expected %s (MTV_VM_ROOTDISK_SIZE)\n' \
            "${pvcName}" "${requestedSize}" "${rootdiskSize}" >&2
          (( ++failed ))
        fi
      fi

      # Access mode — live migration requires ReadWriteMany on the rootdisk PVC.
      if [[ -n "${rootdiskAccessMode}" ]]; then
        typeset hasMode
        hasMode="$(printf '%s' "${pvcJson}" | OcWithRedactedStderr jq -r --arg m "${rootdiskAccessMode}" \
          'any(.spec.accessModes[]?; . == $m)')"
        if [[ "${hasMode}" != "true" ]]; then
          printf 'ERROR: PVC %s accessModes missing %s (MTV_VM_ROOTDISK_ACCESS_MODE)\n' \
            "${pvcName}" "${rootdiskAccessMode}" >&2
          (( ++failed ))
        fi
      fi

      # Volume mode — must match the DataVolume created by p2p-create-cclm-test-vms.
      if [[ -n "${rootdiskVolumeMode}" ]]; then
        typeset volMode
        volMode="$(printf '%s' "${pvcJson}" | OcWithRedactedStderr jq -r '.spec.volumeMode // ""')"
        if [[ "${volMode}" != "${rootdiskVolumeMode}" ]]; then
          printf 'ERROR: PVC %s volumeMode=%s, expected %s (MTV_VM_ROOTDISK_VOLUME_MODE)\n' \
            "${pvcName}" "${volMode}" "${rootdiskVolumeMode}" >&2
          (( ++failed ))
        fi
      fi
    done
    (( failed == 0 ))
  } || _rc=$?

  if [[ "${_wasTracing}" == "true" ]]; then
    set -x
  fi
  return "${_rc}"
}

# JStep — run a function, append PASS/FAIL/SKIP record to junitFile, propagate exit code.
# rc=0: PASS — check executed and succeeded.
# rc=77: SKIP — preconditions not met; check intentionally not executed.
# Returns 0 so the ERR trap is not triggered and subsequent steps run.
# other: FAIL — check executed and failed; original rc propagated (triggers ERR trap).


function OcRole () {
  typeset role="${1:?}"; (($#)) && shift
  case "${role}" in
    source) SourceOc "$@" ;;
    dest) DestOc "$@" ;;
    hub) HubOc "$@" ;;
    *) printf 'ERROR: unknown cluster role\n' >&2; return 1 ;;
  esac
}

function HubOc () {
  typeset wasTracing=false
  if [[ $- == *x* ]]; then
    wasTracing=true
  fi
  set +x
  OcWithRedactedStderr oc --kubeconfig="${KUBECONFIG}" "$@"
  typeset -i rc=$?
  if [[ "${wasTracing}" == true ]]; then
    set -x
  fi
  return "${rc}"
}

function SourceOc () {
  typeset wasTracing=false
  if [[ $- == *x* ]]; then
    wasTracing=true
  fi
  set +x
  OcWithRedactedStderr oc --kubeconfig="${sourceKubeconfig}" "$@"
  typeset -i rc=$?
  if [[ "${wasTracing}" == true ]]; then
    set -x
  fi
  return "${rc}"
}

function DestOc () {
  typeset wasTracing=false
  if [[ $- == *x* ]]; then
    wasTracing=true
  fi
  set +x
  OcWithRedactedStderr oc --kubeconfig="${destKubeconfig}" "$@"
  typeset -i rc=$?
  if [[ "${wasTracing}" == true ]]; then
    set -x
  fi
  return "${rc}"
}

function ResolveSpokesQuiet () {
  typeset wasTracing=false
  if [[ $- == *x* ]]; then
    wasTracing=true
  fi
  set +x
  ResolveSpokeKubeconfigs
  typeset -i rc=$?
  if [[ "${wasTracing}" == true ]]; then
    set -x
  fi
  return "${rc}"
}

function ConfigureLeg () {
  typeset leg="${1:?}"
  sourceKubeconfig=''
  destKubeconfig=''
  sourceProvider=''
  destinationProvider=''
  syncPhaseStartedAt=0
  sshReady=false
  if [[ "${leg}" == forward ]]; then
    sourceSpokeIndex=1
    destSpokeIndex=2
    MTV_PLAN_NAME=cclm-plan
    MTV_MIGRATION_NAME=cclm-run-1
    MTV_NETWORK_MAP_NAME=spoke-network-map
    MTV_STORAGE_MAP_NAME=spoke-storage-map
    cleanupDestBeforeMigration=false
    execPrefix='[cclm-live-migration]'
    verifyPrefix='[cclm-migration-verify]'
  else
    sourceSpokeIndex=2
    destSpokeIndex=1
    MTV_PLAN_NAME=cclm-plan-return
    MTV_MIGRATION_NAME=cclm-run-return
    MTV_NETWORK_MAP_NAME=spoke-network-map-return
    MTV_STORAGE_MAP_NAME=spoke-storage-map-return
    cleanupDestBeforeMigration=true
    execPrefix='[cclm-live-migration-return]'
    verifyPrefix='[cclm-migration-verify-return]'
  fi
  targetNs="${MTV_TEST_VM_TARGET_NAMESPACE:-${MTV_TEST_VM_NAMESPACE}}"
  ResolveSpokesQuiet
  ResolveProviderNames
  true
}

function RunExecuteChecks () {
  RunCheck "${execPrefix} Preflight: Providers and Maps Ready" PreflightHub
  RunCheck "${execPrefix} Preflight: DecentralizedLiveMigration Gates" MaybeEnsureDecentralizedLiveMigration
  RunCheck "${execPrefix} Preflight: Sync Controllers Available" MaybeWaitForSyncControllers
  RunCheck "${execPrefix} Preflight: MTV CCLM Feature Gate Active" PreflightCclm
  RunCheck "${execPrefix} Preflight: Submariner No Globalnet" MaybePreflightSubmarinerNoGlobalnet
  RunCheck "${execPrefix} Preflight: Provider Inventory Refresh" RefreshProvidersForLivePlan
  RunCheck "${execPrefix} Preflight: Source VMs Running" PreflightSourceVm
  RunCheck "${execPrefix} Preflight: VM Storage Classes Mapped" PreflightVmStorageMapped
  if [[ "${cleanupDestBeforeMigration}" == true ]]; then
    RunCheck "${execPrefix} Pre-migration: Cleanup stale destination resources" CleanupDestinationStaleResources
  fi
  RunCheck "${execPrefix} Migration: Apply Plan" ApplyPlan
  RunCheck "${execPrefix} Migration: Plan Ready" WaitPlanReady
  RunCheck "${execPrefix} Migration: Apply Migration" ApplyMigration
  RunCheck "${execPrefix} Migration: Succeeded" WaitMigrationSucceeded
  RunCheck "${execPrefix} Verification: Destination VMIs Running" VerifyMigration
  RunCheck "${execPrefix} Verification: Destination VM runStrategy" VerifyDestVmsRunStrategy
  RunCheck "${execPrefix} Verification: Source VMIM Not Failed" VerifySourceVmimNotFailed
  RunCheckContinue "${execPrefix} Verification: VM SSH Port Probe" ExecuteSshProbe
  true
}

function RunVerifyChecks () {
  typeset -i verifyRc=0
  RunOptionalCheck "${verifyPrefix} Verification: Destination VMIs Running" VerifyMigration || verifyRc=$?
  RunOptionalCheck "${verifyPrefix} Verification: Destination VM runStrategy" VerifyDestVmsRunStrategy || verifyRc=$?
  RunOptionalCheck "${verifyPrefix} Verification: Source VMIM Not Failed" VerifySourceVmimNotFailed || verifyRc=$?
  RunOptionalCheck "${verifyPrefix} Verification: VM SSH Port Probe" VerifyAllVmsSsh || verifyRc=$?
  RunOptionalCheck "${verifyPrefix} Verification: Destination SSH Login" WaitDestSshReady || verifyRc=$?
  RunOptionalCheck "${verifyPrefix} Verification: VM Data Integrity" VerifyVmDataIntegrity || verifyRc=$?
  RunOptionalCheck "${verifyPrefix} Verification: Guest Disk I/O" VerifyGuestDiskIo || verifyRc=$?
  RunOptionalCheck "${verifyPrefix} Verification: Guest Network Reachability" VerifyGuestNetwork || verifyRc=$?
  RunOptionalCheck "${verifyPrefix} Verification: PVC Attachment" VerifyPvcAttachment || verifyRc=$?
  RunOptionalCheck "${verifyPrefix} Verification: PVC Integrity" VerifyPvcIntegrity || verifyRc=$?
  return "${verifyRc}"
}

function RunLeg () {
  typeset leg="${1:?}"
  ConfigureLeg "${leg}"
  typeset -i execRc=0
  RunExecuteChecks || execRc=$?
  if (( execRc != 0 )); then
    if [[ "${cclmDebugMode}" == true ]]; then
      printf 'WARNING: %s execute checks failed (rc=%d); debug mode continues\n' "${leg}" "${execRc}" >&2
    else
      return "${execRc}"
    fi
  fi
  RunVerifyChecks
}

if [[ -z "${KUBECONFIG:-}" || ! -r "${KUBECONFIG}" ]]; then
  printf 'KUBECONFIG not set, skipping\n' >&2
  exit 2
fi

if [[ -n "${SHARED_DIR:-}" && -s "${SHARED_DIR}/proxy-conf.sh" ]]; then
  # shellcheck disable=SC1091
  set +x
  source "${SHARED_DIR}/proxy-conf.sh"
fi

export MTV_TEST_VM_COUNT="${MTV_TEST_VM_COUNT:-1}"
export MTV_TEST_VM_NAME="${MTV_TEST_VM_NAME:-test-vm-1}"
export MTV_TEST_VM_NAMESPACE="${MTV_TEST_VM_NAMESPACE:-vm-migration-test}"
export MTV_PROVIDER_NAMESPACE="${MTV_PROVIDER_NAMESPACE:-mtv-integrations}"
export MTV_NAMESPACE="${MTV_NAMESPACE:-openshift-mtv}"
export MTV_PLAN_TYPE="${MTV_PLAN_TYPE:-live}"
export MTV_PLAN_READY_TIMEOUT="${MTV_PLAN_READY_TIMEOUT:-15m}"
export MTV_MIGRATION_TIMEOUT="${MTV_MIGRATION_TIMEOUT:-15m}"
export MTV_CNV_NAMESPACE="${MTV_CNV_NAMESPACE:-openshift-cnv}"
export MTV_KUBEVIRT_NAME="${MTV_KUBEVIRT_NAME:-kubevirt-kubevirt-hyperconverged}"
export MTV_HCO_NAME="${MTV_HCO_NAME:-kubevirt-hyperconverged}"
export MTV_ENSURE_DECENTRALIZED_LIVE_MIGRATION="${MTV_ENSURE_DECENTRALIZED_LIVE_MIGRATION:-true}"
export MTV_FORKLIFT_CONTROLLER_NAME="${MTV_FORKLIFT_CONTROLLER_NAME:-forklift-controller}"
export MTV_PROVIDER_INVENTORY_REFRESH_WAIT="${MTV_PROVIDER_INVENTORY_REFRESH_WAIT:-5m}"
export MTV_SYNC_CONTROLLER_WAIT="${MTV_SYNC_CONTROLLER_WAIT:-10m}"
export MTV_VM_SSH_VERIFY="${MTV_VM_SSH_VERIFY:-true}"
export MTV_VM_GUEST_EXEC="${MTV_VM_GUEST_EXEC:-true}"
export MTV_VM_DATA_INTEGRITY="${MTV_VM_DATA_INTEGRITY:-true}"
export MTV_PVC_CHECK="${MTV_PVC_CHECK:-true}"
export MTV_VM_SSH_USER="${MTV_VM_SSH_USER:-cloud-user}"
export MTV_VM_SSH_KEY_NAME="${MTV_VM_SSH_KEY_NAME:-cclm-vm-ssh-key}"
export P2P_HS_SPOKE_VM_PREFIX="${P2P_HS_SPOKE_VM_PREFIX:-test-vm}"

typeset -i vmCount="${MTV_TEST_VM_COUNT}"
typeset -i migrationPollInterval="${MTV_MIGRATION_POLL_INTERVAL_SECONDS:-30}"
typeset -i syncStuckMinutes="${MTV_SYNC_STUCK_MINUTES:-20}"
typeset -i syncPhaseStartedAt=0
typeset -i sourceSpokeIndex=1
typeset -i destSpokeIndex=2
typeset -i sshWaitSeconds="${MTV_VM_SSH_WAIT_SECONDS:-600}"
typeset cclmDebugMode="${P2P_CCLM_DEBUG_MODE:-false}"
typeset vmSshVerify="${MTV_VM_SSH_VERIFY}"
typeset vmGuestExec="${MTV_VM_GUEST_EXEC}"
typeset pvcCheck="${MTV_PVC_CHECK}"
typeset sshUser="${MTV_VM_SSH_USER}"
typeset cleanupDestBeforeMigration=false
typeset sourceKubeconfig='' destKubeconfig='' targetNs=''
typeset sourceProvider='' destinationProvider=''
typeset virtctlBin='' sshKeyFile='' sshReady=false
typeset execPrefix='' verifyPrefix=''
typeset rootdiskSize="${MTV_VM_ROOTDISK_SIZE-32Gi}"
typeset rootdiskAccessMode="${MTV_VM_ROOTDISK_ACCESS_MODE-ReadWriteMany}"
typeset rootdiskVolumeMode="${MTV_VM_ROOTDISK_VOLUME_MODE-Block}"
typeset cclmCaseOwner=false
typeset cclmResultsDir="${CCLM_RESULTS_DIR:-/tmp/cclm-2spoke-ote-results}"

(( vmCount >= 1 )) || {
  printf 'ERROR: MTV_TEST_VM_COUNT must be a positive integer\n' >&2
  exit 1
}

trap OnExit EXIT
ClaimOrExitCase

command -v oc 1>/dev/null || { printf 'ERROR: oc not found\n' >&2; exit 1; }
command -v jq 1>/dev/null || { printf 'ERROR: jq not found\n' >&2; exit 1; }

set -x

if [[ "${cclmDebugMode}" == true ]]; then
  RunLeg forward || printf 'WARNING: forward leg failed; debug mode continues\n' >&2
  RunLeg return || printf 'WARNING: return leg failed; debug mode continues\n' >&2
else
  RunLeg forward
  RunLeg return
fi
true

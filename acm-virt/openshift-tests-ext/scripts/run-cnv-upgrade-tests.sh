#!/bin/bash
# OpenShift Virtualization upgrade session for the ACM+Virt OTE scenario.
#
# Same pytest invocation as
# interop-tests-openshift-virtualization-upgrade-tests-commands.sh.
# Prep (cluster, OLM, CNV install) is assumed to have already run.
# This script does not install a cluster and does not write
# junit--cnv__interop-tests__openshift-virtualization-upgrade-tests.xml.
# openshift-tests records this process exit code: 0 pass, 1 fail, 2 skip.
#
# The published JUnit is one ordered pytest session (pytest-order and
# pytest-dependency). The cases below are that session; they are not
# separate processes.
#   tests.virt.upgrade.test_upgrade_virt.TestUpgradeVirt::test_is_vm_running_before_upgrade (CNV-2974)
#   tests.virt.upgrade.test_upgrade_virt.TestUpgradeVirt::test_vm_post_copy_migration_before_upgrade (CNV-12018)
#   tests.virt.upgrade.test_upgrade_virt.TestUpgradeVirt::test_windows_vm_before_upgrade (CNV-7243)
#   tests.virt.upgrade.test_upgrade_virt.TestUpgradeVirt::test_vm_ssh_before_upgrade (CNV-4208)
#   tests.virt.upgrade.test_upgrade_virt.TestUpgradeVirt::test_vm_console_before_upgrade (CNV-2987)
#   tests.virt.upgrade.test_upgrade_virt.TestUpgradeVirt::test_migration_before_upgrade (CNV-2975)
#   tests.virt.upgrade.test_upgrade_virt.TestUpgradeVirt::test_vm_run_strategy_before_upgrade (CNV-6999)
#   tests.storage.upgrade.test_upgrade_storage.TestUpgradeStorage::test_vm_with_hotplug_before_upgrade (CNV-7258)
#   tests.storage.upgrade.test_upgrade_storage.TestUpgradeStorage::test_vm_snapshot_created_before_upgrade (CNV-5995)
#   tests.storage.upgrade.test_upgrade_storage.TestUpgradeStorage::test_vm_snapshot_restore_before_upgrade (CNV-5993, quarantined CNV-95012)
#   tests.observability.upgrade.test_upgrade_observability.TestUpgradeObservability::test_metric_kubevirt_vmi_number_of_outdated_before_upgrade (CNV-11749, quarantined CNV-84508)
#   tests.install_upgrade_operators.product_upgrade.test_upgrade.TestUpgrade::test_production_source_cnv_upgrade_process (CNV-9933)
#   tests.install_upgrade_operators.product_upgrade.test_upgrade_iuo.TestUpgradeIUO::test_alerts_fired_during_upgrade (CNV-9081)
#   tests.install_upgrade_operators.product_upgrade.test_upgrade_iuo.TestUpgradeIUO::test_nodes_taints_after_upgrade (CNV-6866)
#   tests.install_upgrade_operators.product_upgrade.test_upgrade_iuo.TestUpgradeIUO::test_nodes_labels_after_upgrade (CNV-6924)
#   tests.observability.upgrade.test_upgrade_observability.TestUpgradeObservability::test_outdated_vmis_count_matches_kubevirt_status_after_upgrade (CNV-11757, quarantined CNV-84508)
#   tests.observability.upgrade.test_upgrade_observability.TestUpgradeObservability::test_metric_kubevirt_vmi_number_of_outdated_after_upgrade (CNV-11758, quarantined CNV-84508)
#   tests.virt.upgrade.test_upgrade_virt.TestUpgradeVirt::test_vmi_pod_image_updates_after_upgrade_optin (CNV-5932)
#   tests.virt.upgrade.test_upgrade_virt.TestUpgradeVirt::test_is_vm_running_after_upgrade (CNV-2978)
#   tests.virt.upgrade.test_upgrade_virt.TestUpgradeVirt::test_vm_console_after_upgrade (CNV-2980)
#   tests.virt.upgrade.test_upgrade_virt.TestUpgradeVirt::test_vm_ssh_after_upgrade (CNV-4209)
#   tests.virt.upgrade.test_upgrade_virt.TestUpgradeVirt::test_vm_run_strategy_after_upgrade (CNV-7000)
#   tests.virt.upgrade.test_upgrade_virt.TestUpgradeVirt::test_windows_vm_after_upgrade (CNV-7244)
#   tests.virt.upgrade.test_upgrade_virt.TestUpgradeVirt::test_migration_after_upgrade (CNV-2979)
#   tests.virt.upgrade.test_upgrade_virt.TestUpgradeVirt::test_vms_boot_time_after_upgrade (CNV-12571)
#   tests.virt.upgrade.test_upgrade_virt.TestUpgradeVirt::test_pci_topology_after_upgrade (CNV-16329)
#   tests.virt.upgrade.test_upgrade_virt.TestUpgradeVirt::test_machine_type_after_upgrade (CNV-3682)
#   tests.virt.upgrade.test_upgrade_virt.TestUpgradeVirt::test_golden_image_pvc_names_after_upgrade (CNV-5749)
#   tests.virt.upgrade.test_upgrade_virt.TestUpgradeVirt::test_vm_post_copy_migration_after_upgrade (CNV-12019)
#   tests.storage.upgrade.test_upgrade_storage.TestUpgradeStorage::test_vm_snapshot_restore_check_after_upgrade (CNV-5994)
#   tests.storage.upgrade.test_upgrade_storage.TestUpgradeStorage::test_vm_snapshot_restore_create_after_upgrade (CNV-5996)
#   tests.storage.upgrade.test_upgrade_storage.TestUpgradeStorage::test_vm_with_hotplug_after_upgrade (CNV-5310)
#   tests.post_test_alerts.test_post_test_alerts::test_no_deprecated_api_alert_after_tests (CNV-16276)
set -euo pipefail
shopt -s inherit_errexit

# UseSpokeKubeconfig — point KUBECONFIG at the spoke admin kubeconfig when it exists.
# Returns 2 when no kubeconfig is available.
function UseSpokeKubeconfig () {
  typeset wasTracing=false
  [[ $- == *x* ]] && wasTracing=true
  set +x
  typeset -i rc=0
  if [[ -n "${SHARED_DIR:-}" && -r "${SHARED_DIR}/managed-cluster-kubeconfig" ]]; then
    export KUBECONFIG="${SHARED_DIR}/managed-cluster-kubeconfig"
  elif [[ -z "${KUBECONFIG:-}" || ! -r "${KUBECONFIG}" ]]; then
    rc=2
  fi
  if [[ "${wasTracing}" == true ]]; then
    set -x
  fi
  return "${rc}"
}

# LoadSecrets — read Artifactory and Bitwarden credentials with xtrace off.
# ARTIFACTORY_USER falls back when its file is absent. The other four files are required.
function LoadSecrets () {
  typeset wasTracing=false
  [[ $- == *x* ]] && wasTracing=true
  set +x
  typeset bw="${BW_PATH:-/bw}"
  typeset -i rc=0
  if [[ -r "${bw}/artifactory-user" ]]; then
    ARTIFACTORY_USER="$(head -1 "${bw}/artifactory-user")" || rc=$?
  else
    ARTIFACTORY_USER='ci-read-only-user'
  fi
  if (( rc == 0 )); then
    ARTIFACTORY_TOKEN="$(head -1 "${bw}/artifactory-token")" || rc=$?
  fi
  if (( rc == 0 )); then
    ARTIFACTORY_SERVER="$(head -1 "${bw}/artifactory-server")" || rc=$?
  fi
  if (( rc == 0 )); then
    ACCESS_TOKEN="$(head -1 "${bw}/bitwarden-client-secret")" || rc=$?
  fi
  if (( rc == 0 )); then
    ORGANIZATION_ID="$(head -1 "${bw}/bitwarden-org-id")" || rc=$?
  fi
  if (( rc == 0 )); then
    export ORGANIZATION_ID ACCESS_TOKEN ARTIFACTORY_USER ARTIFACTORY_TOKEN ARTIFACTORY_SERVER
  else
    unset ORGANIZATION_ID ACCESS_TOKEN ARTIFACTORY_USER ARTIFACTORY_TOKEN ARTIFACTORY_SERVER
    printf 'ERROR: required credential file under BW_PATH is missing or unreadable\n' >&2
  fi
  if [[ "${wasTracing}" == true ]]; then
    set -x
  fi
  return "${rc}"
}

# ResolveTestsDir — directory that contains the openshift-virtualization-tests checkout.
function ResolveTestsDir () {
  if [[ -n "${CNV_TESTS_DIR:-}" && -d "${CNV_TESTS_DIR}/tests" ]]; then
    printf '%s' "${CNV_TESTS_DIR}"
    return 0
  fi
  typeset candidate=''
  for candidate in /openshift-virtualization-tests "${PWD}"; do
    if [[ -f "${candidate}/pyproject.toml" && -d "${candidate}/tests" ]]; then
      printf '%s' "${candidate}"
      return 0
    fi
  done
  printf 'ERROR: openshift-virtualization-tests checkout not found; set CNV_TESTS_DIR\n' >&2
  return 1
}

# InstallAndVerifyVirtctl — download virtctl from the cluster CLI route and put it on PATH.
function InstallAndVerifyVirtctl () {
  typeset binDir="${1:?}"; (($#)) && shift
  typeset wasTracing=false
  [[ $- == *x* ]] && wasTracing=true
  set +x
  typeset domain=''
  typeset -i rc=0
  domain="$(oc get ingress.config.openshift.io/cluster -o jsonpath='{.spec.domain}' | tr -d '\n\r')" || rc=$?
  if (( rc == 0 )) && [[ -z "${domain}" ]]; then
    rc=1
  fi
  if (( rc == 0 )); then
    curl -kfsSL "https://hyperconverged-cluster-cli-download-openshift-cnv.${domain}/amd64/linux/virtctl.tar.gz" \
      | tar -xzf - -C "${binDir}" || rc=$?
  fi
  if [[ "${wasTracing}" == true ]]; then
    set -x
  fi
  (( rc == 0 )) || return 1

  if [[ ! -x "${binDir}/virtctl" ]]; then
    typeset virtctlPath=''
    virtctlPath="$(find "${binDir}" -name virtctl -type f -executable | head -1)"
    if [[ -n "${virtctlPath}" ]]; then
      mv "${virtctlPath}" "${binDir}/virtctl"
    fi
  fi
  if [[ ! -x "${binDir}/virtctl" ]]; then
    printf 'ERROR: virtctl was not extracted\n' >&2
    return 1
  fi
  "${binDir}/virtctl" version --client 1>/dev/null
}

# BuildCnvUpgradePytestArgs — pytest arguments for --upgrade cnv.
# $1 is the installed CNV version. VirtualMachineTemplate tests are ignored when
# that version is below 4.22, matching the release step.
function BuildCnvUpgradePytestArgs () {
  typeset cnvVer="${1:?}"; (($#)) && shift
  typeset -a args=(
    --upgrade=cnv
    --cnv-version "${cnvTargetVersion}"
    --cnv-source "${cnvSource}"
    --cnv-channel "${cnvChannel}"
    --storage-class-matrix="${cnvStorageClass}"
    --data-collector
    --data-collector-output-dir="${artifactDir}/"
    --ignore=tests/network/
    --tb=native
  )
  typeset cnvMajor="${cnvVer%%.*}"
  typeset cnvRest="${cnvVer#*.}"
  typeset cnvMajorMinor="${cnvMajor}.${cnvRest%%.*}"
  if [[ "${cnvMajorMinor}" != '4.22' ]] \
    && [[ "$(printf '%s\n%s\n' "${cnvMajorMinor}" '4.22' | sort -V | head -n1)" == "${cnvMajorMinor}" ]]; then
    : "Installed CNV ${cnvVer} is below 4.22; ignoring tests/infrastructure/vm_template/"
    args+=(--ignore=tests/infrastructure/vm_template/)
  fi
  if [[ -n "${cnvTargetImage}" ]]; then
    args+=(--cnv-image "${cnvTargetImage}")
  fi
  printf '%s\n' "${args[@]}"
  true
}

# RunCnvUpgradePytest — one pytest process for the whole upgrade session.
function RunCnvUpgradePytest () {
  typeset testsDir="${1:?}"; (($#)) && shift
  typeset hcoSubscription="${1:?}"; (($#)) && shift
  typeset -a cnvUpgradeArgs=("$@")
  typeset -i exitCode=0
  (
    cd "${testsDir}"
    uv --verbose --cache-dir /tmp/uv-cache \
      run pytest -o cache_dir=/tmp/pytest-cache \
      -s \
      -o log_cli=true \
      "${cnvUpgradeArgs[@]}" \
      --pytest-log-file="${artifactDir}/tests.log" \
      --tc "hco_subscription:${hcoSubscription}"
  ) || exitCode=$?
  return "${exitCode}"
}

spokeRc=0
UseSpokeKubeconfig || spokeRc=$?
if (( spokeRc == 2 )); then
  printf 'KUBECONFIG not set, skipping\n' >&2
  exit 2
fi
if (( spokeRc != 0 )); then
  exit "${spokeRc}"
fi

if [[ -n "${SHARED_DIR:-}" && -s "${SHARED_DIR}/proxy-conf.sh" ]]; then
  # shellcheck disable=SC1091
  source "${SHARED_DIR}/proxy-conf.sh"
fi

LoadSecrets

set -x

command -v oc 1>/dev/null || { printf 'ERROR: oc not found\n' >&2; exit 1; }
command -v uv 1>/dev/null || { printf 'ERROR: uv not found\n' >&2; exit 1; }
command -v curl 1>/dev/null || { printf 'ERROR: curl not found\n' >&2; exit 1; }

typeset cnvTargetVersion="${CNV_TARGET_VERSION:-4.21.0}"
typeset cnvSource="${CNV_SOURCE:-production}"
typeset cnvChannel="${CNV_CHANNEL:-stable}"
typeset cnvStorageClass="${CNV_TARGET_STORAGE_CLASS:-ocs-storagecluster-ceph-rbd-virtualization}"
typeset cnvTargetImage="${CNV_TARGET_IMAGE:-}"
typeset cnvNamespace="${TARGET_NAMESPACE:-openshift-cnv}"
typeset hcoSubscriptionName='hco-operatorhub'
typeset artifactDir="${ARTIFACT_DIR:-${TMPDIR:-/tmp}/cnv-upgrade-artifacts}"
mkdir -p "${artifactDir}"

if [[ -n "${SHARED_DIR:-}" && -f "${SHARED_DIR}/cnv-target-version" ]]; then
  cnvTargetVersion="$(< "${SHARED_DIR}/cnv-target-version")"
fi
[[ -n "${cnvTargetVersion}" ]]
printf '%s\n' "${cnvTargetVersion}" > "${artifactDir}/cnv-target-version"

unset KUBERNETES_SERVICE_PORT_HTTPS \
  KUBERNETES_SERVICE_PORT \
  KUBERNETES_PORT_443_TCP \
  KUBERNETES_PORT_443_TCP_PROTO \
  KUBERNETES_PORT_443_TCP_ADDR \
  KUBERNETES_SERVICE_HOST \
  KUBERNETES_PORT \
  KUBERNETES_PORT_443_TCP_PORT

oc whoami 1>/dev/null
oc get "subscription.operators.coreos.com/${hcoSubscriptionName}" -n "${cnvNamespace}" 1>/dev/null

typeset binFolder=''
binFolder="$(mktemp -d /tmp/bin.XXXX)"
export PATH="${binFolder}:${PATH}"
InstallAndVerifyVirtctl "${binFolder}"

typeset installedCsv='' cnvSourceVer=''
installedCsv="$(oc get "subscription.operators.coreos.com/${hcoSubscriptionName}" -n "${cnvNamespace}" -o jsonpath='{.status.installedCSV}')"
[[ "${installedCsv}" == kubevirt-hyperconverged-operator.v* ]]
cnvSourceVer="${installedCsv#kubevirt-hyperconverged-operator.v}"
printf '%s\n' "${cnvSourceVer}" > "${artifactDir}/cnv-source-version"

typeset testsDir=''
testsDir="$(ResolveTestsDir)"
typeset -a cnvUpgradeArgs=()
BuildCnvUpgradePytestArgs "${cnvSourceVer}" > "${artifactDir}/cnv-upgrade-pytest-args"
mapfile -t cnvUpgradeArgs < "${artifactDir}/cnv-upgrade-pytest-args"
(( ${#cnvUpgradeArgs[@]} > 0 ))
[[ "${cnvUpgradeArgs[0]}" == '--upgrade=cnv' ]]

typeset -i pytestRc=0
RunCnvUpgradePytest "${testsDir}" "${hcoSubscriptionName}" "${cnvUpgradeArgs[@]}" || pytestRc=$?
if (( pytestRc != 0 )); then
  printf 'ERROR: pytest --upgrade cnv failed (rc=%d)\n' "${pytestRc}" >&2
  exit 1
fi
true

#!/usr/bin/env bash

# Source-node prepare dispatcher.
#
# The controller runs this file with `ssh SOURCE bash -s -- ARGUMENT...`, so the
# script body itself arrives on standard input. Every remote command issued from
# here therefore either delivers its own script on standard input through a
# heredoc, or explicitly detaches standard input, so a remote session can never
# consume the remainder of this script.
#
# Actions are idempotent for one immutable run contract: an action may be rerun
# with the same RUN_ID after a failure, reuses only fully verified artifacts and
# stages, resumes partial transfers, and rejects conflicting or corrupt
# completed artifacts without deleting them.

set -Eeuo pipefail

readonly SGLANG_SOURCE_URL=https://github.com/sgl-project/sglang.git
readonly REMOTE_SCALAR_FIELD_COUNT=36
readonly REMOTE_NODE_COUNT=4
readonly REMOTE_NODE_FIELD_COUNT=6
readonly REMOTE_TOOL_MISSING_STATUS=78

_FAILURE_STAGE=startup
_FAILURE_RECORDED=0

die() {
  printf 'prepare-remote: error: %s\n' "$1" >&2
  exit "${2:-1}"
}

# Failure evidence is deliberately limited to run-scoped identifiers and the
# preserved exit status. No command text, remote output, or path is recorded.
write_failure_record() {
  local status=$1
  local line=$2
  local run_root
  [ -n "${RUN_ID:-}" ] && [ -n "${PACKAGE_ROOT:-}" ] || return 0
  case "${RUN_ID}" in
    *[!A-Za-z0-9._-]*|""|"."|"..") return 0 ;;
  esac
  run_root="${PACKAGE_ROOT}/.runtime/prepare/${RUN_ID}"
  mkdir -p "${run_root}" 2>/dev/null || return 0
  (
    umask 077
    printf 'run_id=%s action=%s stage=%s status=%s line=%s\n' \
      "${RUN_ID}" \
      "${ACTION:-unknown}" \
      "${_FAILURE_STAGE}" \
      "${status}" \
      "${line}" >>"${run_root}/failures.log"
  ) 2>/dev/null || return 0
  return 0
}

on_error() {
  local status=$1
  local line=$2
  [ "${status}" -ne 0 ] || return 0
  [ "${_FAILURE_RECORDED}" -eq 0 ] || return 0
  _FAILURE_RECORDED=1
  write_failure_record "${status}" "${line}" || true
  return 0
}

# Guarantees that `die`, explicit exits, and unexpected exits all leave failure
# evidence while preserving the original exit status.
on_exit() {
  local status=$1
  trap - ERR EXIT
  if [ "${status}" -ne 0 ] && [ "${_FAILURE_RECORDED}" -eq 0 ]; then
    _FAILURE_RECORDED=1
    write_failure_record "${status}" 0 || true
  fi
  exit "${status}"
}

trap 'on_error "$?" "${LINENO}"' ERR
trap 'on_exit "$?"' EXIT

stage() {
  _FAILURE_STAGE=$1
}

sha256_file() {
  sha256sum "$1" | awk '{print $1}'
}

tab_character() {
  printf '\t'
}

require_plain_file() {
  [ -f "$1" ] && [ ! -L "$1" ] || die "$2 is missing or not a plain file"
}

require_digest() {
  local path=$1
  local expected=$2
  require_plain_file "${path}" "tracked artifact"
  [ "$(sha256_file "${path}")" = "${expected}" ] ||
    die "tracked artifact digest mismatch"
}

require_plain_directory() {
  [ -d "$1" ] && [ ! -L "$1" ] || die "$2 must be a plain directory"
}

repo_cache_name() {
  printf 'models--%s\n' "${1//\//--}"
}

run_root() {
  printf '%s/.runtime/prepare/%s\n' "${PACKAGE_ROOT}" "${RUN_ID}"
}

worker_run_root() {
  printf '%s/.runtime/prepare/%s\n' "$1" "${RUN_ID}"
}

# Records a value exactly once per run. A conflicting existing record fails
# closed and is never rewritten or deleted.
write_once() {
  local path=$1
  local content=$2
  if [ -e "${path}" ] || [ -L "${path}" ]; then
    require_plain_file "${path}" "run record"
    [ "$(cat "${path}")" = "${content}" ] ||
      die "existing run record conflicts with the current run"
    return 0
  fi
  (
    set -C
    umask 077
    printf '%s\n' "${content}" >"${path}"
  )
}

append_unique() {
  local path=$1
  local line=$2
  if [ -f "${path}" ] && grep -Fxq "${line}" "${path}"; then
    return 0
  fi
  (
    umask 077
    printf '%s\n' "${line}" >>"${path}"
  )
}

verify_machine() {
  local actual
  require_plain_file "${MACHINE_ID_PATH}" "machine identity file"
  actual="$(
    tr -d '\n' <"${MACHINE_ID_PATH}" |
      sha256sum |
      awk '{print $1}'
  )"
  [ "${actual}" = "${SOURCE_MACHINE_DIGEST}" ] ||
    die "source machine identity mismatch"
}

verify_package_artifacts() {
  require_digest "${PACKAGE_ROOT}/${TARGET_MANIFEST}" "${TARGET_MANIFEST_DIGEST}"
  require_digest "${PACKAGE_ROOT}/${DRAFT_MANIFEST}" "${DRAFT_MANIFEST_DIGEST}"
  require_digest "${PACKAGE_ROOT}/${CONTAINERFILE}" "${CONTAINERFILE_DIGEST}"
  require_digest "${PACKAGE_ROOT}/${PATCH_SERIES}" "${PATCH_SERIES_DIGEST}"
  require_digest "${PACKAGE_ROOT}/${PATCH_FILE}" "${PATCH_DIGEST}"
  require_digest "${PACKAGE_ROOT}/tools/verify_hf_cache.py" "${VERIFIER_DIGEST}"
  require_digest \
    "${PACKAGE_ROOT}/tools/artifact_manifest.py" \
    "${MANIFEST_TOOL_DIGEST}"
  require_digest "${PACKAGE_ROOT}/tools/patch_series.py" "${SERIES_TOOL_DIGEST}"
}

# Prints the ordered `<relative path>\t<sha256>` series records after the tool
# has validated the schema, path containment, and every declared patch digest.
patch_series_records() {
  local records
  records="$(
    python3 "${PACKAGE_ROOT}/tools/patch_series.py" \
      verify \
      --series "${PACKAGE_ROOT}/${PATCH_SERIES}"
  )" || die "patch series verification failed"
  [ -n "${records}" ] || die "patch series is empty"
  printf '%s\n' "${records}"
}

# The lock pins one patch by path and digest. That patch must be a member of the
# ordered series so the series can never silently replace it.
verify_patch_series_contract() {
  local records
  local series_directory
  local relative
  local digest
  local locked_seen=0
  records="$(patch_series_records)"
  series_directory="$(dirname "${PATCH_SERIES}")"
  while IFS="$(tab_character)" read -r relative digest; do
    [ -n "${relative}" ] || continue
    if [ "${series_directory}/${relative}" = "${PATCH_FILE}" ]; then
      [ "${digest}" = "${PATCH_DIGEST}" ] ||
        die "patch series digest disagrees with the locked patch digest"
      locked_seen=1
    fi
  done <<EOF
${records}
EOF
  [ "${locked_seen}" -eq 1 ] ||
    die "patch series does not contain the locked runtime patch"
}

preflight() {
  local tool
  stage preflight
  verify_machine
  verify_package_artifacts
  require_plain_directory "${PACKAGE_ROOT}" "package root"
  require_plain_directory "$(dirname "${SOURCE_CACHE_ROOT}")" "cache parent"
  require_plain_file "${FABRIC_KNOWN_HOSTS}" "fabric known-hosts file"
  for tool in awk bash docker git hf mv python3 rsync sha256sum ssh ssh-keygen \
    stat tr; do
    command -v "${tool}" >/dev/null 2>&1 ||
      die "required source tool is unavailable" "${REMOTE_TOOL_MISSING_STATUS}"
  done
  verify_patch_series_contract
  record_contract
}

record_contract() {
  local contract_file
  local expected
  local index=0
  contract_file="$(run_root)/contract"
  expected="$(
    printf 'config_digest=%s\nlock_digest=%s\ntarget_hub_bytes=%s\n' \
      "${CONFIG_DIGEST}" \
      "${LOCK_DIGEST}" \
      "${TARGET_HUB_BYTES}"
    while [ "${index}" -lt "${REMOTE_NODE_COUNT}" ]; do
      printf 'node=%s role=%s machine=%s\n' \
        "${NODE_IDS[index]}" \
        "${NODE_ROLES[index]}" \
        "${NODE_MACHINE_DIGESTS[index]}"
      index=$((index + 1))
    done
  )"
  mkdir -p "$(run_root)"
  if [ -e "${contract_file}" ] || [ -L "${contract_file}" ]; then
    require_plain_file "${contract_file}" "run contract"
    [ "$(cat "${contract_file}")" = "${expected}" ] ||
      die "run contract changed for this run ID"
  else
    (
      set -C
      umask 077
      printf '%s\n' "${expected}" >"${contract_file}"
    )
  fi
}

strict_ssh_options() {
  printf '%s\n' \
    -o \
    BatchMode=yes \
    -o \
    StrictHostKeyChecking=yes \
    -o \
    GlobalKnownHostsFile=/dev/null \
    -o \
    "UserKnownHostsFile=${FABRIC_KNOWN_HOSTS}"
}

# Runs a remote bash script whose bytes must arrive on this function's standard
# input, normally through a heredoc at the call site.
strict_ssh_script() {
  local address=$1
  shift
  local option
  local -a options
  options=()
  while IFS= read -r option; do
    options[${#options[@]}]="${option}"
  done < <(strict_ssh_options)
  ssh "${options[@]}" "${address}" bash -s -- "$@"
}

# Runs a remote command that carries no script payload, with standard input
# explicitly detached.
strict_ssh_command() {
  local address=$1
  shift
  local option
  local -a options
  options=()
  while IFS= read -r option; do
    options[${#options[@]}]="${option}"
  done < <(strict_ssh_options)
  # Remote-side expansion is intended: the arguments are controller-validated
  # metacharacter-free absolute paths from the configuration loader.
  # shellcheck disable=SC2029
  ssh "${options[@]}" "${address}" "$@" </dev/null
}

rsync_ssh_command() {
  printf '%s' \
    "ssh -o BatchMode=yes -o StrictHostKeyChecking=yes" \
    " -o GlobalKnownHostsFile=/dev/null" \
    " -o UserKnownHostsFile=${FABRIC_KNOWN_HOSTS}"
}

require_pinned_host_key() {
  ssh-keygen -F "$1" -f "${FABRIC_KNOWN_HOSTS}" >/dev/null ||
    die "target fabric address lacks a pinned host key"
}

verify_target_machine() {
  local index=$1
  strict_ssh_script "${NODE_FABRIC_IPS[index]}" \
    "${MACHINE_ID_PATH}" \
    "${NODE_MACHINE_DIGESTS[index]}" <<'TARGET_IDENTITY'
set -eu
# glm53-remote-script:worker-identity
machine_id_path=$1
expected=$2
[ -f "${machine_id_path}" ] && [ ! -L "${machine_id_path}" ]
actual="$(
  tr -d '\n' <"${machine_id_path}" |
    sha256sum |
    awk '{print $1}'
)"
[ "${actual}" = "${expected}" ]
TARGET_IDENTITY
}

prepare_worker_run_root() {
  local index=$1
  strict_ssh_script "${NODE_FABRIC_IPS[index]}" \
    "${NODE_ROOTS[index]}" \
    "${RUN_ID}" <<'WORKER_RUN_ROOT'
set -eu
# glm53-remote-script:worker-run-root
target_root=$1
run_id=$2
[ -d "${target_root}" ] && [ ! -L "${target_root}" ]
run_root="${target_root}/.runtime/prepare/${run_id}"
mkdir -p "${run_root}"
[ -d "${run_root}" ] && [ ! -L "${run_root}" ]
WORKER_RUN_ROOT
}

# Builds the minimal verification bundle the workers need. Workers are not
# assumed to hold a repository checkout, so they receive exactly the two tools
# they execute and the two authoritative model manifests they verify against.
build_worker_bundle() {
  local bundle_root
  local bundle_manifest
  local generated
  bundle_root="$(run_root)/bundle"
  bundle_manifest="$(run_root)/bundle.manifest.json"
  stage bundle-build
  verify_package_artifacts
  mkdir -p \
    "${bundle_root}/tools" \
    "${bundle_root}/$(dirname "${TARGET_MANIFEST}")" \
    "${bundle_root}/$(dirname "${DRAFT_MANIFEST}")"
  require_plain_directory "${bundle_root}" "worker bundle root"
  cp "${PACKAGE_ROOT}/tools/artifact_manifest.py" \
    "${bundle_root}/tools/artifact_manifest.py"
  cp "${PACKAGE_ROOT}/tools/verify_hf_cache.py" \
    "${bundle_root}/tools/verify_hf_cache.py"
  cp "${PACKAGE_ROOT}/${TARGET_MANIFEST}" "${bundle_root}/${TARGET_MANIFEST}"
  cp "${PACKAGE_ROOT}/${DRAFT_MANIFEST}" "${bundle_root}/${DRAFT_MANIFEST}"
  generated="$(
    python3 "${PACKAGE_ROOT}/tools/artifact_manifest.py" build "${bundle_root}"
  )" || die "worker bundle manifest could not be built"
  write_once "${bundle_manifest}" "${generated}"
  python3 "${PACKAGE_ROOT}/tools/artifact_manifest.py" \
    verify "${bundle_root}" "${bundle_manifest}" >/dev/null ||
    die "worker bundle does not match its own manifest"
}

bootstrap_worker() {
  local index=$1
  local address=${NODE_FABRIC_IPS[index]}
  local target_root=${NODE_ROOTS[index]}
  local bundle_root
  local bundle_manifest
  local worker_root
  local worker_bundle
  local worker_manifest
  bundle_root="$(run_root)/bundle"
  bundle_manifest="$(run_root)/bundle.manifest.json"
  worker_root="$(worker_run_root "${target_root}")"
  worker_bundle="${worker_root}/bundle"
  worker_manifest="${worker_root}/bundle.manifest.json"

  stage "bundle-transfer-${NODE_IDS[index]}"
  require_pinned_host_key "${address}"
  strict_ssh_command "${address}" test -d "${target_root}" ||
    die "worker package root is missing"
  verify_target_machine "${index}"
  prepare_worker_run_root "${index}"
  rsync \
    -a \
    --partial \
    --append-verify \
    -e "$(rsync_ssh_command)" \
    "${bundle_root}/" \
    "${address}:${worker_bundle}/"
  rsync \
    -a \
    --partial \
    --append-verify \
    -e "$(rsync_ssh_command)" \
    "${bundle_manifest}" \
    "${address}:${worker_manifest}"
  strict_ssh_script "${address}" \
    "${worker_bundle}" \
    "${worker_manifest}" \
    "$(sha256_file "${bundle_manifest}")" \
    "${MANIFEST_TOOL_DIGEST}" \
    "${VERIFIER_DIGEST}" \
    "${TARGET_MANIFEST}" \
    "${TARGET_MANIFEST_DIGEST}" \
    "${DRAFT_MANIFEST}" \
    "${DRAFT_MANIFEST_DIGEST}" <<'WORKER_BUNDLE_VERIFY'
set -eu
# glm53-remote-script:worker-bundle-verify
bundle_root=$1
bundle_manifest=$2
bundle_manifest_digest=$3
manifest_tool_digest=$4
verifier_digest=$5
target_manifest=$6
target_manifest_digest=$7
draft_manifest=$8
draft_manifest_digest=$9
for tool in awk mv python3 rsync sha256sum stat; do
  command -v "${tool}" >/dev/null 2>&1 || exit 78
done
[ -d "${bundle_root}" ] && [ ! -L "${bundle_root}" ]
verify_bytes() {
  [ -f "$1" ] && [ ! -L "$1" ]
  [ "$(sha256sum "$1" | awk '{print $1}')" = "$2" ]
}
verify_bytes "${bundle_manifest}" "${bundle_manifest_digest}"
verify_bytes "${bundle_root}/tools/artifact_manifest.py" "${manifest_tool_digest}"
verify_bytes "${bundle_root}/tools/verify_hf_cache.py" "${verifier_digest}"
verify_bytes "${bundle_root}/${target_manifest}" "${target_manifest_digest}"
verify_bytes "${bundle_root}/${draft_manifest}" "${draft_manifest_digest}"
python3 "${bundle_root}/tools/artifact_manifest.py" \
  verify "${bundle_root}" "${bundle_manifest}" >/dev/null
WORKER_BUNDLE_VERIFY
}

bootstrap_workers() {
  local index=0
  preflight
  build_worker_bundle
  while [ "${index}" -lt "${REMOTE_NODE_COUNT}" ]; do
    if [ "${NODE_ROLES[index]}" != source ]; then
      bootstrap_worker "${index}"
    fi
    index=$((index + 1))
  done
}

verify_image() {
  local image=$1
  local architecture
  local owner
  local commit
  local patch
  architecture="$(docker image inspect "${image}" --format '{{.Architecture}}')"
  owner="$(
    docker image inspect "${image}" \
      --format '{{ index .Config.Labels "io.glm53.owner" }}'
  )"
  commit="$(
    docker image inspect "${image}" \
      --format '{{ index .Config.Labels "io.glm53.sglang.commit" }}'
  )"
  patch="$(
    docker image inspect "${image}" \
      --format '{{ index .Config.Labels "io.glm53.patch.sha256" }}'
  )"
  [ "${architecture}" = arm64 ] || die "runtime image architecture mismatch"
  [ "${owner}" = "${IMAGE_OWNER}" ] || die "runtime image owner label mismatch"
  [ "${commit}" = "${SGLANG_COMMIT}" ] ||
    die "runtime image source label mismatch"
  [ "${patch}" = "${PATCH_DIGEST}" ] ||
    die "runtime image patch label mismatch"
}

runtime_probe() {
  local image=$1
  docker run \
    --rm \
    --device nvidia.com/gpu=all \
    --entrypoint python3 \
    -i \
    "${image}" - <<'PYTHON'
import platform

import torch

from sglang.kernels.ops.attention.dsa.tilelang_kernel import (
    _V1_DEFAULT_SMEM_BYTES,
    _cuda_max_dynamic_smem_bytes,
    _v1_tile_overrides,
)
from sglang.srt.models.dflash import DFlash2DraftModel


if platform.machine() != "aarch64":
    raise RuntimeError("runtime is not arm64")
if not torch.cuda.is_available():
    raise RuntimeError("CUDA is unavailable")
if DFlash2DraftModel is None:
    raise RuntimeError("DFlash2 import failed")
limit = _cuda_max_dynamic_smem_bytes(0)
overrides = _v1_tile_overrides(torch.device("cuda", 0))
if limit <= 0:
    raise RuntimeError("dynamic shared-memory limit is unavailable")
if limit < _V1_DEFAULT_SMEM_BYTES:
    expected = {"block_I": 32, "num_stages": 1, "threads": 128}
    if overrides != expected:
        raise RuntimeError("GB10 tile override is not active")
elif overrides:
    raise RuntimeError("large-shared-memory device was unexpectedly retiled")
PYTHON
}

verify_base_image() {
  local base_arm64
  docker pull "${BASE_IMAGE}"
  [ "$(docker image inspect "${BASE_IMAGE}" --format '{{.Architecture}}')" = arm64 ] ||
    die "base image is not arm64"
  case "$(docker image inspect "${BASE_IMAGE}" --format '{{json .RepoDigests}}')" in
    *"${BASE_IMAGE#*@}"*) ;;
    *) die "base image manifest identity mismatch" ;;
  esac
  base_arm64="$(
    docker buildx imagetools inspect "${BASE_IMAGE}" \
      --format '{{range .Manifest.Manifests}}{{if eq .Platform.Architecture "arm64"}}{{.Digest}}{{end}}{{end}}'
  )"
  [ "${base_arm64}" = "${BASE_ARM64_DIGEST}" ] ||
    die "base arm64 manifest identity mismatch"
}

# Applies exactly the validated ordered series. A member that is already applied
# from an interrupted run is detected and skipped instead of failing the rerun.
apply_patch_series() {
  local tree=$1
  local records
  local series_directory
  local relative
  local digest
  local patch_path
  records="$(patch_series_records)"
  series_directory="${PACKAGE_ROOT}/$(dirname "${PATCH_SERIES}")"
  while IFS="$(tab_character)" read -r relative digest; do
    [ -n "${relative}" ] || continue
    patch_path="${series_directory}/${relative}"
    if git -C "${tree}" apply --check "${patch_path}" 2>/dev/null; then
      git -C "${tree}" apply "${patch_path}"
    elif git -C "${tree}" apply --reverse --check "${patch_path}" 2>/dev/null; then
      continue
    else
      die "ordered patch does not apply to the pinned source tree"
    fi
  done <<EOF
${records}
EOF
}

prepare_source_tree() {
  local stage_root=$1
  local source_tree="${stage_root}/source"
  local context="${stage_root}/context"
  mkdir -p "${stage_root}"
  require_plain_directory "${stage_root}" "run-scoped image build stage"
  if [ ! -d "${source_tree}/.git" ]; then
    [ ! -e "${source_tree}" ] && [ ! -L "${source_tree}" ] ||
      die "staged source tree exists but is not a git checkout"
    git clone \
      --filter=blob:none \
      --no-checkout \
      "${SGLANG_SOURCE_URL}" \
      "${source_tree}"
  fi
  git -C "${source_tree}" fetch origin "${SGLANG_COMMIT}" --depth 1
  git -C "${source_tree}" checkout --detach "${SGLANG_COMMIT}"
  [ "$(git -C "${source_tree}" rev-parse HEAD)" = "${SGLANG_COMMIT}" ] ||
    die "SGLang checkout identity mismatch"
  apply_patch_series "${source_tree}"
  mkdir -p "${context}/python"
  cp -a "${source_tree}/python/sglang" "${context}/python/sglang"
}

image_export_is_complete() {
  local run_directory=$1
  local image_tar="${run_directory}/image.tar"
  local hash_file="${image_tar}.sha256"
  if [ ! -e "${image_tar}" ] && [ ! -L "${image_tar}" ]; then
    return 1
  fi
  require_plain_file "${image_tar}" "existing image export"
  require_plain_file "${hash_file}" "existing image export digest record"
  [ "$(sha256_file "${image_tar}")" = "$(awk '{print $1}' "${hash_file}")" ] ||
    die "existing image export digest mismatch"
  require_plain_file "${run_directory}/image.layers" "recorded image layers"
  require_plain_file "${run_directory}/image.ids" "recorded image identifiers"
  return 0
}

# A complete export is the immutable source of truth for a resumable run. The
# source tag may have been pruned after publication, so restore it only when it
# is absent and reject an existing tag whose recorded identity conflicts.
verify_exported_image() {
  local run_directory=$1
  local image=$2
  local expected_id
  local expected_layers
  local actual_id
  local actual_layers
  expected_id="$(awk 'NR == 1 { print; exit }' "${run_directory}/image.ids")"
  expected_layers="$(cat "${run_directory}/image.layers")"
  [ -n "${expected_id}" ] || die "recorded source image identifier is empty"
  verify_image "${image}"
  actual_id="$(docker image inspect "${image}" --format '{{.Id}}')"
  actual_layers="$(docker image inspect "${image}" --format '{{json .RootFS.Layers}}')"
  [ "${actual_id}" = "${expected_id}" ] ||
    die "runtime image identifier mismatch"
  [ "${actual_layers}" = "${expected_layers}" ] ||
    die "runtime image RootFS layers mismatch"
}

restore_exported_image() {
  local run_directory=$1
  local image=$2
  local image_tar="${run_directory}/image.tar"
  if docker image inspect "${image}" --format '{{.Id}}' >/dev/null 2>&1; then
    verify_exported_image "${run_directory}" "${image}"
    return 0
  fi
  docker load --input "${image_tar}" >/dev/null
  verify_exported_image "${run_directory}" "${image}"
}

export_image() {
  local run_directory=$1
  local image=$2
  local image_tar="${run_directory}/image.tar"
  local hash_file="${image_tar}.sha256"
  local partial="${image_tar}.partial"
  local digest
  # The export attempt is run-scoped and unverified until it is published, so a
  # new attempt may replace it. Published artifacts are immutable.
  docker save --output "${partial}" "${image}"
  digest="$(sha256_file "${partial}")"
  (
    umask 077
    printf '%s  %s\n' "${digest}" "${image_tar}" >"${hash_file}.partial"
  )
  mv "${hash_file}.partial" "${hash_file}"
  [ ! -e "${image_tar}" ] && [ ! -L "${image_tar}" ] ||
    die "image export appeared before publication"
  mv "${partial}" "${image_tar}"
  write_once \
    "${run_directory}/image.layers" \
    "$(docker image inspect "${image}" --format '{{json .RootFS.Layers}}')"
  append_unique \
    "${run_directory}/image.ids" \
    "$(docker image inspect "${image}" --format '{{.Id}}')"
}

build_image() {
  local run_directory
  local stage_root
  local image
  local build_stamp
  run_directory="$(run_root)"
  stage_root="${run_directory}/stage"
  image="${IMAGE_REPOSITORY}:${RUN_ID}"
  build_stamp="${run_directory}/image.build.ok"

  preflight
  stage image-build
  mkdir -p "${run_directory}"
  if image_export_is_complete "${run_directory}"; then
    stage image-restore
    restore_exported_image "${run_directory}" "${image}"
    return 0
  fi
  if [ -f "${build_stamp}" ] &&
    docker image inspect "${image}" --format '{{.Id}}' >/dev/null 2>&1; then
    verify_image "${image}"
  else
    verify_base_image
    prepare_source_tree "${stage_root}"
    docker build \
      --file "${PACKAGE_ROOT}/${CONTAINERFILE}" \
      --tag "${image}" \
      "${stage_root}/context"
    verify_image "${image}"
    runtime_probe "${image}"
    write_once "${build_stamp}" "${image}"
  fi
  stage image-export
  export_image "${run_directory}" "${image}"
}

model_fields() {
  case "$1" in
    target-model)
      MODEL_REPOSITORY=${TARGET_REPOSITORY}
      MODEL_REVISION=${TARGET_REVISION}
      MODEL_SHARDS=${TARGET_SHARDS}
      MODEL_TENSOR_BYTES=${TARGET_TENSOR_BYTES}
      MODEL_MANIFEST=${TARGET_MANIFEST}
      MODEL_MANIFEST_DIGEST=${TARGET_MANIFEST_DIGEST}
      ;;
    draft-model)
      MODEL_REPOSITORY=${DRAFT_REPOSITORY}
      MODEL_REVISION=${DRAFT_REVISION}
      MODEL_SHARDS=${DRAFT_SHARDS}
      MODEL_TENSOR_BYTES=${DRAFT_TENSOR_BYTES}
      MODEL_MANIFEST=${DRAFT_MANIFEST}
      MODEL_MANIFEST_DIGEST=${DRAFT_MANIFEST_DIGEST}
      ;;
    *) die "unsupported model kind" ;;
  esac
}

verify_snapshot() {
  local cache_root=$1
  local repo_root
  repo_root="${cache_root}/$(repo_cache_name "${MODEL_REPOSITORY}")"
  require_digest "${PACKAGE_ROOT}/${MODEL_MANIFEST}" "${MODEL_MANIFEST_DIGEST}"
  python3 "${PACKAGE_ROOT}/tools/verify_hf_cache.py" \
    "${repo_root}/snapshots/${MODEL_REVISION}" \
    "${MODEL_REVISION}" \
    "${MODEL_SHARDS}" \
    "${MODEL_TENSOR_BYTES}" \
    --manifest "${PACKAGE_ROOT}/${MODEL_MANIFEST}" \
    --verify-blobs >/dev/null
}

prepare_model() {
  local kind=$1
  local final_repo
  local staging_root
  local staging_repo

  preflight
  model_fields "${kind}"
  stage "model-${kind}"

  mkdir -p "${SOURCE_CACHE_ROOT}"
  require_plain_directory "${SOURCE_CACHE_ROOT}" "source cache root"
  final_repo="${SOURCE_CACHE_ROOT}/$(repo_cache_name "${MODEL_REPOSITORY}")"
  if [ -e "${final_repo}" ] || [ -L "${final_repo}" ]; then
    require_plain_directory "${final_repo}" "existing final model cache"
    verify_snapshot "${SOURCE_CACHE_ROOT}" ||
      die "existing final model cache is invalid and will not be overwritten"
    return 0
  fi

  staging_root="${SOURCE_CACHE_ROOT}/.glm53-stage-${RUN_ID}-${kind}"
  if [ -e "${staging_root}" ] || [ -L "${staging_root}" ]; then
    require_plain_directory "${staging_root}" "run-scoped model staging root"
  else
    mkdir "${staging_root}"
  fi
  hf download "${MODEL_REPOSITORY}" \
    --revision "${MODEL_REVISION}" \
    --cache-dir "${staging_root}" \
    --format quiet
  verify_snapshot "${staging_root}"
  staging_repo="${staging_root}/$(repo_cache_name "${MODEL_REPOSITORY}")"
  [ "$(stat -c %d "${SOURCE_CACHE_ROOT}")" = "$(stat -c %d "${staging_repo}")" ] ||
    die "model cache promotion would cross filesystems"
  [ ! -e "${final_repo}" ] && [ ! -L "${final_repo}" ] ||
    die "final model cache appeared before promotion"
  mv "${staging_repo}" "${final_repo}"
}

distribute_image() {
  local index=$1
  local address=${NODE_FABRIC_IPS[index]}
  local target_root=${NODE_ROOTS[index]}
  local run_directory
  local image="${IMAGE_REPOSITORY}:${RUN_ID}"
  local image_tar
  local expected_hash
  local source_layers
  local worker_root
  local target_partial
  local target_final
  local target_identity
  local separator
  run_directory="$(run_root)"
  image_tar="${run_directory}/image.tar"
  worker_root="$(worker_run_root "${target_root}")"
  target_partial="${worker_root}/image.tar.partial"
  target_final="${worker_root}/image.tar"
  separator="$(tab_character)"

  stage "image-transfer-${NODE_IDS[index]}"
  require_plain_file "${image_tar}" "source image export"
  require_plain_file "${image_tar}.sha256" "source image digest record"
  require_plain_file "${run_directory}/image.layers" "recorded image layers"
  expected_hash="$(awk '{print $1}' "${image_tar}.sha256")"
  [ "$(sha256_file "${image_tar}")" = "${expected_hash}" ] ||
    die "source image tar digest mismatch"
  source_layers="$(cat "${run_directory}/image.layers")"
  require_pinned_host_key "${address}"
  verify_target_machine "${index}"
  prepare_worker_run_root "${index}"
  rsync \
    -a \
    --partial \
    --append-verify \
    -e "$(rsync_ssh_command)" \
    "${image_tar}" \
    "${address}:${target_partial}"
  target_identity="$(
    strict_ssh_script "${address}" \
      "${target_partial}" \
      "${target_final}" \
      "${expected_hash}" \
      "${image}" \
      "${IMAGE_OWNER}" \
      "${SGLANG_COMMIT}" \
      "${PATCH_DIGEST}" <<'WORKER_IMAGE_LOAD'
set -eu
# glm53-remote-script:worker-image-load
partial=$1
final=$2
expected_hash=$3
image=$4
expected_owner=$5
expected_commit=$6
expected_patch=$7
[ -f "${partial}" ] && [ ! -L "${partial}" ]
[ "$(sha256sum "${partial}" | awk '{print $1}')" = "${expected_hash}" ]
if [ -e "${final}" ] || [ -L "${final}" ]; then
  [ -f "${final}" ] && [ ! -L "${final}" ]
  [ "$(sha256sum "${final}" | awk '{print $1}')" = "${expected_hash}" ]
else
  mv "${partial}" "${final}"
fi
docker load --input "${final}" >/dev/null
[ "$(docker image inspect "${image}" --format '{{.Architecture}}')" = arm64 ]
[ "$(docker image inspect "${image}" --format '{{ index .Config.Labels "io.glm53.owner" }}')" = "${expected_owner}" ]
[ "$(docker image inspect "${image}" --format '{{ index .Config.Labels "io.glm53.sglang.commit" }}')" = "${expected_commit}" ]
[ "$(docker image inspect "${image}" --format '{{ index .Config.Labels "io.glm53.patch.sha256" }}')" = "${expected_patch}" ]
printf '%s\t%s\n' \
  "$(docker image inspect "${image}" --format '{{.Id}}')" \
  "$(docker image inspect "${image}" --format '{{json .RootFS.Layers}}')"
WORKER_IMAGE_LOAD
  )"
  [ "${target_identity#*"${separator}"}" = "${source_layers}" ] ||
    die "target image RootFS layers differ from the source"
  append_unique \
    "${run_directory}/image.ids" \
    "${target_identity%%"${separator}"*}"
}

distribute_model() {
  local index=$1
  local kind=$2
  local address=${NODE_FABRIC_IPS[index]}
  local target_root=${NODE_ROOTS[index]}
  local target_cache=${NODE_CACHE_ROOTS[index]}
  local repo_name
  local source_repo
  local staging_root
  local worker_bundle
  local decision

  model_fields "${kind}"
  stage "model-transfer-${kind}-${NODE_IDS[index]}"
  repo_name="$(repo_cache_name "${MODEL_REPOSITORY}")"
  source_repo="${SOURCE_CACHE_ROOT}/${repo_name}"
  staging_root="${target_cache}/.glm53-stage-${RUN_ID}-${kind}"
  worker_bundle="$(worker_run_root "${target_root}")/bundle"

  require_pinned_host_key "${address}"
  verify_target_machine "${index}"
  verify_snapshot "${SOURCE_CACHE_ROOT}"
  decision="$(
    strict_ssh_script "${address}" \
      "${target_cache}" \
      "${staging_root}" \
      "${repo_name}" \
      "${worker_bundle}" \
      "${MODEL_REVISION}" \
      "${MODEL_SHARDS}" \
      "${MODEL_TENSOR_BYTES}" \
      "${MODEL_MANIFEST}" \
      "${VERIFIER_DIGEST}" <<'TARGET_MODEL_PREFLIGHT'
set -eu
# glm53-remote-script:target-model-preflight
# The verifier and manifest come from the run-scoped artifact bundle, so no
# repository checkout is assumed on this node.
cache_root=$1
staging_root=$2
repo_name=$3
bundle_root=$4
revision=$5
shards=$6
tensor_bytes=$7
manifest=$8
verifier_digest=$9
verifier="${bundle_root}/tools/verify_hf_cache.py"
[ -f "${verifier}" ] && [ ! -L "${verifier}" ]
[ "$(sha256sum "${verifier}" | awk '{print $1}')" = "${verifier_digest}" ]
final_repo="${cache_root}/${repo_name}"
if [ -e "${final_repo}" ] || [ -L "${final_repo}" ]; then
  [ -d "${final_repo}" ] && [ ! -L "${final_repo}" ]
  python3 "${verifier}" \
    "${final_repo}/snapshots/${revision}" \
    "${revision}" \
    "${shards}" \
    "${tensor_bytes}" \
    --manifest "${bundle_root}/${manifest}" \
    --verify-blobs >/dev/null
  printf 'reuse\n'
  exit 0
fi
[ -d "${cache_root}" ] && [ ! -L "${cache_root}" ]
if [ -e "${staging_root}" ] || [ -L "${staging_root}" ]; then
  [ -d "${staging_root}" ] && [ ! -L "${staging_root}" ]
else
  mkdir "${staging_root}"
fi
printf 'stage\n'
TARGET_MODEL_PREFLIGHT
  )"
  case "${decision}" in
    reuse) return 0 ;;
    stage) ;;
    *) die "worker model preflight returned an unsupported decision" ;;
  esac
  rsync \
    -aH \
    --partial \
    --append-verify \
    -e "$(rsync_ssh_command)" \
    "${source_repo}/" \
    "${address}:${staging_root}/${repo_name}/"
  strict_ssh_script "${address}" \
    "${target_cache}" \
    "${staging_root}" \
    "${repo_name}" \
    "${worker_bundle}" \
    "${MODEL_REVISION}" \
    "${MODEL_SHARDS}" \
    "${MODEL_TENSOR_BYTES}" \
    "${MODEL_MANIFEST}" \
    "${VERIFIER_DIGEST}" <<'TARGET_MODEL_PROMOTE'
set -eu
# glm53-remote-script:target-model-promote
# The verifier and manifest come from the run-scoped artifact bundle, so no
# repository checkout is assumed on this node.
cache_root=$1
staging_root=$2
repo_name=$3
bundle_root=$4
revision=$5
shards=$6
tensor_bytes=$7
manifest=$8
verifier_digest=$9
verifier="${bundle_root}/tools/verify_hf_cache.py"
[ -f "${verifier}" ] && [ ! -L "${verifier}" ]
[ "$(sha256sum "${verifier}" | awk '{print $1}')" = "${verifier_digest}" ]
stage_repo="${staging_root}/${repo_name}"
final_repo="${cache_root}/${repo_name}"
python3 "${verifier}" \
  "${stage_repo}/snapshots/${revision}" \
  "${revision}" \
  "${shards}" \
  "${tensor_bytes}" \
  --manifest "${bundle_root}/${manifest}" \
  --verify-blobs >/dev/null
[ "$(stat -c %d "${cache_root}")" = "$(stat -c %d "${stage_repo}")" ]
[ ! -e "${final_repo}" ] && [ ! -L "${final_repo}" ]
mv "${stage_repo}" "${final_repo}"
TARGET_MODEL_PROMOTE
}

distribute_all() {
  local index=0
  local run_directory
  preflight
  run_directory="$(run_root)"
  while [ "${index}" -lt "${REMOTE_NODE_COUNT}" ]; do
    if [ "${NODE_ROLES[index]}" != source ]; then
      distribute_image "${index}"
      distribute_model "${index}" target-model
      distribute_model "${index}" draft-model
    fi
    index=$((index + 1))
  done
  stage image-identity
  [ "$(sort -u "${run_directory}/image.ids" | wc -l)" -le 2 ] ||
    die "more than two legitimate image IDs were observed"
}

expected_argument_count() {
  printf '%s\n' \
    "$((REMOTE_SCALAR_FIELD_COUNT + REMOTE_NODE_COUNT * REMOTE_NODE_FIELD_COUNT))"
}

[ "$#" -eq "$(expected_argument_count)" ] ||
  die "remote prepare contract has the wrong field count"
ACTION=$1
RUN_ID=$2
PACKAGE_ROOT=$3
SOURCE_CACHE_ROOT=$4
MACHINE_ID_PATH=$5
SOURCE_MACHINE_DIGEST=$6
CONFIG_DIGEST=$7
LOCK_DIGEST=$8
FABRIC_KNOWN_HOSTS=$9
shift 9
BASE_IMAGE=$1
BASE_ARM64_DIGEST=$2
SGLANG_COMMIT=$3
IMAGE_REPOSITORY=$4
IMAGE_OWNER=$5
CONTAINERFILE=$6
CONTAINERFILE_DIGEST=$7
PATCH_SERIES=$8
PATCH_SERIES_DIGEST=$9
shift 9
PATCH_FILE=$1
PATCH_DIGEST=$2
VERIFIER_DIGEST=$3
MANIFEST_TOOL_DIGEST=$4
SERIES_TOOL_DIGEST=$5
TARGET_REPOSITORY=$6
TARGET_REVISION=$7
TARGET_SHARDS=$8
TARGET_TENSOR_BYTES=$9
shift 9
TARGET_HUB_BYTES=$1
TARGET_MANIFEST=$2
TARGET_MANIFEST_DIGEST=$3
DRAFT_REPOSITORY=$4
DRAFT_REVISION=$5
DRAFT_SHARDS=$6
DRAFT_TENSOR_BYTES=$7
DRAFT_MANIFEST=$8
DRAFT_MANIFEST_DIGEST=$9
shift 9

MODEL_REPOSITORY=
MODEL_REVISION=
MODEL_SHARDS=
MODEL_TENSOR_BYTES=
MODEL_MANIFEST=
MODEL_MANIFEST_DIGEST=

NODE_IDS=()
NODE_ROLES=()
NODE_ROOTS=()
NODE_FABRIC_IPS=()
NODE_CACHE_ROOTS=()
NODE_MACHINE_DIGESTS=()
node_index=0
while [ "${node_index}" -lt "${REMOTE_NODE_COUNT}" ]; do
  NODE_IDS[node_index]=$1
  NODE_ROLES[node_index]=$2
  NODE_ROOTS[node_index]=$3
  NODE_FABRIC_IPS[node_index]=$4
  NODE_CACHE_ROOTS[node_index]=$5
  NODE_MACHINE_DIGESTS[node_index]=$6
  shift 6
  node_index=$((node_index + 1))
done
[ "$#" -eq 0 ] || die "remote prepare contract has the wrong field count"

case "${ACTION}" in
  preflight) preflight ;;
  bootstrap) bootstrap_workers ;;
  build) build_image ;;
  target-model) prepare_model target-model ;;
  draft-model) prepare_model draft-model ;;
  distribute) distribute_all ;;
  *) die "unsupported prepare action" ;;
esac

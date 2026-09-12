#!/usr/bin/env bash

_GLM53_PREPARE_LIB_DIR="$(
  cd "$(dirname "${BASH_SOURCE[0]}")" && pwd
)"
readonly _GLM53_PREPARE_LIB_DIR
readonly _GLM53_PREPARE_ROOT="${_GLM53_PREPARE_LIB_DIR}/.."
readonly _GLM53_PREPARE_REMOTE="${_GLM53_PREPARE_LIB_DIR}/prepare_remote.sh"
readonly _GLM53_PREPARE_PATCH="runtime/patches/sglang-glm53-gb10-tilelang.patch"
readonly _GLM53_PREPARE_VERIFIER="tools/verify_hf_cache.py"
readonly _GLM53_PREPARE_MANIFEST_TOOL="tools/artifact_manifest.py"
readonly _GLM53_PREPARE_SERIES_TOOL="tools/patch_series.py"
readonly _GLM53_PREPARE_MACHINE_ID="/etc/machine-id"

# Local files whose bytes change what apply does. They are not carried in the
# reproduction lock, so the printed plan pins them explicitly and the plan digest
# covers them. Changing any of them invalidates a previously printed plan.
_prepare_plan_pinned_files() {
  printf '%s\n' \
    glm53-spark \
    lib/common.sh \
    lib/config.sh \
    lib/doctor.sh \
    lib/prepare.sh \
    lib/prepare_remote.sh \
    "${_GLM53_PREPARE_MANIFEST_TOOL}" \
    tools/config_state.py \
    tools/fabric_probe.py \
    tools/node_probe.py \
    "${_GLM53_PREPARE_SERIES_TOOL}" \
    "${_GLM53_PREPARE_VERIFIER}"
}

_prepare_sha256_file() {
  local prepare_path=$1
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "${prepare_path}" | awk '{print $1}'
  else
    sha256sum "${prepare_path}" | awk '{print $1}'
  fi
}

_prepare_sha256_text() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    sha256sum | awk '{print $1}'
  fi
}

_prepare_require_digest() {
  local prepare_path=$1
  local prepare_expected=$2
  local prepare_actual
  [ -f "${prepare_path}" ] && [ ! -L "${prepare_path}" ] || {
    common_die "prepare artifact is missing or not a plain file"
    return 1
  }
  prepare_actual="$(_prepare_sha256_file "${prepare_path}")"
  [ "${prepare_actual}" = "${prepare_expected}" ] || {
    common_die "prepare artifact digest does not match the reproduction lock"
    return 1
  }
}

_prepare_load_contract() {
  local prepare_config=$1
  local prepare_lock=$2
  local prepare_value
  local prepare_index
  local prepare_base
  local -a prepare_values

  prepare_values=()
  while IFS= read -r -d '' prepare_value; do
    prepare_values[${#prepare_values[@]}]="${prepare_value}"
  done < <(config_export_prepare "${prepare_config}" "${prepare_lock}")
  [ "${#prepare_values[@]}" -eq 60 ] || {
    common_die "prepare contract export is incomplete" 2
    return 2
  }

  _PREPARE_CONFIG_DIGEST=${prepare_values[0]}
  _PREPARE_LOCK_DIGEST=${prepare_values[1]}
  _PREPARE_SOURCE_ID=${prepare_values[2]}
  _PREPARE_SOURCE_ALIAS=${prepare_values[3]}
  _PREPARE_SOURCE_ROOT=${prepare_values[4]}
  _PREPARE_SOURCE_CACHE=${prepare_values[5]}
  _PREPARE_FABRIC_KNOWN_HOSTS=${prepare_values[6]}
  _PREPARE_CONNECT_TIMEOUT=${prepare_values[7]}
  _PREPARE_COMMAND_TIMEOUT=${prepare_values[8]}
  _PREPARE_TARGET_REPO=${prepare_values[9]}
  _PREPARE_TARGET_REVISION=${prepare_values[10]}
  _PREPARE_TARGET_SHARDS=${prepare_values[11]}
  _PREPARE_TARGET_TENSOR_BYTES=${prepare_values[12]}
  _PREPARE_TARGET_HUB_BYTES=${prepare_values[13]}
  _PREPARE_TARGET_MANIFEST=${prepare_values[14]}
  _PREPARE_TARGET_MANIFEST_DIGEST=${prepare_values[15]}
  _PREPARE_DRAFT_REPO=${prepare_values[16]}
  _PREPARE_DRAFT_REVISION=${prepare_values[17]}
  _PREPARE_DRAFT_SHARDS=${prepare_values[18]}
  _PREPARE_DRAFT_TENSOR_BYTES=${prepare_values[19]}
  _PREPARE_DRAFT_MANIFEST=${prepare_values[20]}
  _PREPARE_DRAFT_MANIFEST_DIGEST=${prepare_values[21]}
  _PREPARE_BASE_IMAGE=${prepare_values[22]}
  _PREPARE_BASE_ARM64=${prepare_values[23]}
  _PREPARE_SGLANG_COMMIT=${prepare_values[24]}
  _PREPARE_IMAGE_REPOSITORY=${prepare_values[25]}
  _PREPARE_IMAGE_OWNER=${prepare_values[26]}
  _PREPARE_CONTAINERFILE=${prepare_values[27]}
  _PREPARE_CONTAINERFILE_DIGEST=${prepare_values[28]}
  _PREPARE_PATCH_SERIES=${prepare_values[29]}
  _PREPARE_PATCH_SERIES_DIGEST=${prepare_values[30]}
  _PREPARE_PATCH_DIGEST=${prepare_values[31]}
  _PREPARE_SOURCE_MACHINE_DIGEST=

  _PREPARE_NODE_IDS=()
  _PREPARE_NODE_ALIASES=()
  _PREPARE_NODE_ROLES=()
  _PREPARE_NODE_ROOTS=()
  _PREPARE_NODE_FABRIC_IPS=()
  _PREPARE_NODE_CACHE_ROOTS=()
  _PREPARE_NODE_MACHINE_DIGESTS=()
  prepare_index=0
  while [ "${prepare_index}" -lt 4 ]; do
    prepare_base=$((32 + prepare_index * 7))
    _PREPARE_NODE_IDS[prepare_index]=${prepare_values[prepare_base]}
    _PREPARE_NODE_ALIASES[prepare_index]=${prepare_values[prepare_base + 1]}
    _PREPARE_NODE_ROLES[prepare_index]=${prepare_values[prepare_base + 2]}
    _PREPARE_NODE_ROOTS[prepare_index]=${prepare_values[prepare_base + 3]}
    _PREPARE_NODE_FABRIC_IPS[prepare_index]=${prepare_values[prepare_base + 4]}
    _PREPARE_NODE_CACHE_ROOTS[prepare_index]=${prepare_values[prepare_base + 5]}
    _PREPARE_NODE_MACHINE_DIGESTS[prepare_index]=${prepare_values[prepare_base + 6]}
    if [ "${_PREPARE_NODE_ROLES[prepare_index]}" = "source" ]; then
      _PREPARE_SOURCE_MACHINE_DIGEST=${_PREPARE_NODE_MACHINE_DIGESTS[prepare_index]}
    fi
    prepare_index=$((prepare_index + 1))
  done
  [ -n "${_PREPARE_SOURCE_MACHINE_DIGEST}" ] || {
    common_die "prepare source identity is missing" 2
    return 2
  }
}

_prepare_require_plain_file() {
  local prepare_path=$1
  [ -f "${prepare_path}" ] && [ ! -L "${prepare_path}" ] || {
    common_die "plan-pinned local file is missing or not a plain file"
    return 1
  }
}

# Prints the validated ordered `<relative path><tab><sha256>` series records.
# The tool enforces the series schema, path containment, and every declared
# digest, so a decorative or tampered series fails closed here.
_prepare_series_records() {
  python3 \
    "${_GLM53_PREPARE_ROOT}/${_GLM53_PREPARE_SERIES_TOOL}" \
    verify \
    --series "${_GLM53_PREPARE_ROOT}/${_PREPARE_PATCH_SERIES}" || {
    common_die "ordered patch series validation failed"
    return 1
  }
}

_prepare_validate_local_artifacts() {
  local prepare_file
  local prepare_records
  local prepare_relative
  local prepare_digest
  local prepare_series_directory
  local prepare_locked_seen=0

  _prepare_require_digest \
    "${_GLM53_PREPARE_ROOT}/${_PREPARE_TARGET_MANIFEST}" \
    "${_PREPARE_TARGET_MANIFEST_DIGEST}" &&
    _prepare_require_digest \
      "${_GLM53_PREPARE_ROOT}/${_PREPARE_DRAFT_MANIFEST}" \
      "${_PREPARE_DRAFT_MANIFEST_DIGEST}" &&
    _prepare_require_digest \
      "${_GLM53_PREPARE_ROOT}/${_PREPARE_CONTAINERFILE}" \
      "${_PREPARE_CONTAINERFILE_DIGEST}" &&
    _prepare_require_digest \
      "${_GLM53_PREPARE_ROOT}/${_PREPARE_PATCH_SERIES}" \
      "${_PREPARE_PATCH_SERIES_DIGEST}" &&
    _prepare_require_digest \
      "${_GLM53_PREPARE_ROOT}/${_GLM53_PREPARE_PATCH}" \
      "${_PREPARE_PATCH_DIGEST}" || return

  while IFS= read -r prepare_file; do
    _prepare_require_plain_file \
      "${_GLM53_PREPARE_ROOT}/${prepare_file}" || return
  done < <(_prepare_plan_pinned_files)

  prepare_records="$(_prepare_series_records)" || return
  prepare_series_directory="$(dirname "${_PREPARE_PATCH_SERIES}")"
  while IFS="$(printf '\t')" read -r prepare_relative prepare_digest; do
    [ -n "${prepare_relative}" ] || continue
    if [ "${prepare_series_directory}/${prepare_relative}" = \
      "${_GLM53_PREPARE_PATCH}" ]; then
      [ "${prepare_digest}" = "${_PREPARE_PATCH_DIGEST}" ] || {
        common_die "patch series digest disagrees with the locked patch"
        return 1
      }
      prepare_locked_seen=1
    fi
  done <<EOF
${prepare_records}
EOF
  [ "${prepare_locked_seen}" -eq 1 ] || {
    common_die "patch series does not contain the locked runtime patch"
    return 1
  }
}

_prepare_cache_name() {
  printf 'models--%s\n' "${1//\//--}"
}

_prepare_render_inputs() {
  local prepare_file
  local prepare_relative
  local prepare_digest
  local prepare_index=0
  local prepare_records

  common_print_action \
    plan-input \
    config-digest "${_PREPARE_CONFIG_DIGEST}" \
    lock-digest "${_PREPARE_LOCK_DIGEST}"
  while IFS= read -r prepare_file; do
    common_print_action \
      plan-input \
      plan-pinned-sha256 \
      "${prepare_file}" \
      "$(_prepare_sha256_file "${_GLM53_PREPARE_ROOT}/${prepare_file}")"
  done < <(_prepare_plan_pinned_files)
  for prepare_file in \
    "${_PREPARE_CONTAINERFILE}:${_PREPARE_CONTAINERFILE_DIGEST}" \
    "${_PREPARE_PATCH_SERIES}:${_PREPARE_PATCH_SERIES_DIGEST}" \
    "${_GLM53_PREPARE_PATCH}:${_PREPARE_PATCH_DIGEST}" \
    "${_PREPARE_TARGET_MANIFEST}:${_PREPARE_TARGET_MANIFEST_DIGEST}" \
    "${_PREPARE_DRAFT_MANIFEST}:${_PREPARE_DRAFT_MANIFEST_DIGEST}"; do
    common_print_action \
      lock-input \
      lock-pinned-sha256 \
      "${prepare_file%%:*}" \
      "${prepare_file#*:}"
  done
  prepare_records="$(_prepare_series_records)" || return
  while IFS="$(printf '\t')" read -r prepare_relative prepare_digest; do
    [ -n "${prepare_relative}" ] || continue
    common_print_action \
      patch-series-member \
      "${prepare_index}" \
      "$(dirname "${_PREPARE_PATCH_SERIES}")/${prepare_relative}" \
      "${prepare_digest}"
    prepare_index=$((prepare_index + 1))
  done <<EOF
${prepare_records}
EOF
}

_prepare_render_model_actions() {
  local prepare_run_id=$1
  local prepare_kind=$2
  local prepare_repository=$3
  local prepare_revision=$4
  local prepare_manifest=$5
  local prepare_cache_name
  local prepare_staging
  prepare_cache_name="$(_prepare_cache_name "${prepare_repository}")"
  prepare_staging="${_PREPARE_SOURCE_CACHE}/.glm53-stage-${prepare_run_id}-${prepare_kind}"

  common_print_action \
    "source-${prepare_kind}" \
    ssh "${_PREPARE_SOURCE_ALIAS}" bash -s -- "${prepare_kind}" \
    reuse-verified "${_PREPARE_SOURCE_CACHE}/${prepare_cache_name}" \
    hf download "${prepare_repository}" \
    --revision "${prepare_revision}" \
    --cache-dir "${prepare_staging}" \
    --format quiet \
    verify-full "${prepare_manifest}" --verify-blobs \
    same-filesystem-atomic-promote \
    "${prepare_staging}/${prepare_cache_name}" \
    "${_PREPARE_SOURCE_CACHE}/${prepare_cache_name}" \
    no-overwrite
}

_prepare_render_body() {
  local prepare_run_id=$1
  local prepare_index
  local prepare_target
  local prepare_run_root="${_PREPARE_SOURCE_ROOT}/.runtime/prepare/${prepare_run_id}"
  local prepare_image_tar="${prepare_run_root}/image.tar"
  local prepare_image_name="${_PREPARE_IMAGE_REPOSITORY}:${prepare_run_id}"
  local prepare_worker_root
  local prepare_target_cache
  local prepare_target_name
  local prepare_draft_name

  _prepare_render_inputs || return
  prepare_target_name="$(_prepare_cache_name "${_PREPARE_TARGET_REPO}")"
  prepare_draft_name="$(_prepare_cache_name "${_PREPARE_DRAFT_REPO}")"

  common_print_action \
    source-preflight \
    ssh \
    BatchMode=yes \
    StrictHostKeyChecking=yes \
    "${_PREPARE_SOURCE_ALIAS}" \
    bash -s -- preflight \
    dispatcher-stdin-sha256 \
    "$(_prepare_sha256_file "${_GLM53_PREPARE_REMOTE}")" \
    verify-machine-id "${_GLM53_PREPARE_MACHINE_ID}" \
    "${_PREPARE_SOURCE_MACHINE_DIGEST}" \
    verify-config-lock-artifacts \
    "${_PREPARE_CONFIG_DIGEST}" \
    "${_PREPARE_LOCK_DIGEST}" \
    verify-ordered-patch-series "${_PREPARE_PATCH_SERIES}" \
    record-run-contract "${prepare_run_root}/contract" \
    failure-evidence "${prepare_run_root}/failures.log"

  common_print_action \
    source-bootstrap \
    ssh "${_PREPARE_SOURCE_ALIAS}" bash -s -- bootstrap \
    build-worker-bundle "${prepare_run_root}/bundle" \
    "${_GLM53_PREPARE_MANIFEST_TOOL}" \
    "${_GLM53_PREPARE_VERIFIER}" \
    "${_PREPARE_TARGET_MANIFEST}" \
    "${_PREPARE_DRAFT_MANIFEST}" \
    artifact-manifest "${prepare_run_root}/bundle.manifest.json"
  prepare_index=0
  while [ "${prepare_index}" -lt 4 ]; do
    if [ "${_PREPARE_NODE_ROLES[prepare_index]}" != "source" ]; then
      prepare_target=${_PREPARE_NODE_FABRIC_IPS[prepare_index]}
      prepare_worker_root="${_PREPARE_NODE_ROOTS[prepare_index]}/.runtime/prepare/${prepare_run_id}"
      common_print_action \
        source-bootstrap-worker \
        "${_PREPARE_NODE_IDS[prepare_index]}" \
        require-pinned-host-key "${_PREPARE_FABRIC_KNOWN_HOSTS}" \
        worker-identity "${_GLM53_PREPARE_MACHINE_ID}" \
        "${_PREPARE_NODE_MACHINE_DIGESTS[prepare_index]}" \
        rsync -a --partial --append-verify \
        -e ssh \
        BatchMode=yes \
        StrictHostKeyChecking=yes \
        GlobalKnownHostsFile=/dev/null \
        "UserKnownHostsFile=${_PREPARE_FABRIC_KNOWN_HOSTS}" \
        "${prepare_run_root}/bundle/" \
        "${prepare_target}:${prepare_worker_root}/bundle/" \
        "${prepare_run_root}/bundle.manifest.json" \
        "${prepare_target}:${prepare_worker_root}/bundle.manifest.json" \
        worker-bundle-verify \
        "${prepare_worker_root}/bundle/${_GLM53_PREPARE_MANIFEST_TOOL}" \
        "${prepare_worker_root}/bundle/${_GLM53_PREPARE_VERIFIER}"
    fi
    prepare_index=$((prepare_index + 1))
  done

  common_print_action \
    source-build \
    ssh "${_PREPARE_SOURCE_ALIAS}" bash -s -- build \
    reuse-verified "${prepare_image_tar}" "${prepare_image_tar}.sha256" \
    docker pull "${_PREPARE_BASE_IMAGE}" \
    verify-arm64 "${_PREPARE_BASE_ARM64}" \
    git fetch origin "${_PREPARE_SGLANG_COMMIT}" --depth 1 \
    apply-ordered-series "${_PREPARE_PATCH_SERIES}" \
    docker build --file "${_PREPARE_CONTAINERFILE}" \
    --tag "${prepare_image_name}" "${prepare_run_root}/stage/context" \
    verify-labels "${_PREPARE_IMAGE_OWNER}" \
    "${_PREPARE_SGLANG_COMMIT}" \
    "${_PREPARE_PATCH_DIGEST}" \
    runtime-probe DFlash2DraftModel GB10-tile \
    docker save --output "${prepare_image_tar}.partial" \
    "${prepare_image_name}" \
    sha256 "${prepare_image_tar}.sha256" \
    atomic-publish "${prepare_image_tar}"

  _prepare_render_model_actions \
    "${prepare_run_id}" \
    target-model \
    "${_PREPARE_TARGET_REPO}" \
    "${_PREPARE_TARGET_REVISION}" \
    "${_PREPARE_TARGET_MANIFEST}"
  _prepare_render_model_actions \
    "${prepare_run_id}" \
    draft-model \
    "${_PREPARE_DRAFT_REPO}" \
    "${_PREPARE_DRAFT_REVISION}" \
    "${_PREPARE_DRAFT_MANIFEST}"

  common_print_action \
    source-distribute \
    ssh "${_PREPARE_SOURCE_ALIAS}" bash -s -- distribute
  prepare_index=0
  while [ "${prepare_index}" -lt 4 ]; do
    if [ "${_PREPARE_NODE_ROLES[prepare_index]}" != "source" ]; then
      prepare_target=${_PREPARE_NODE_FABRIC_IPS[prepare_index]}
      prepare_worker_root="${_PREPARE_NODE_ROOTS[prepare_index]}/.runtime/prepare/${prepare_run_id}"
      prepare_target_cache=${_PREPARE_NODE_CACHE_ROOTS[prepare_index]}
      common_print_action \
        source-transfer-image \
        "${_PREPARE_NODE_IDS[prepare_index]}" \
        worker-identity "${_PREPARE_NODE_MACHINE_DIGESTS[prepare_index]}" \
        rsync -a --partial --append-verify \
        -e ssh \
        BatchMode=yes \
        StrictHostKeyChecking=yes \
        GlobalKnownHostsFile=/dev/null \
        "UserKnownHostsFile=${_PREPARE_FABRIC_KNOWN_HOSTS}" \
        "${prepare_image_tar}" \
        "${prepare_target}:${prepare_worker_root}/image.tar.partial" \
        verify-sha256 \
        atomic-publish "${prepare_worker_root}/image.tar" \
        docker load --input "${prepare_worker_root}/image.tar" \
        verify-labels "${_PREPARE_IMAGE_OWNER}" \
        verify-RootFS-equality \
        record-image-ID "${prepare_run_root}/image.ids"
      common_print_action \
        source-transfer-models \
        "${_PREPARE_NODE_IDS[prepare_index]}" \
        target-model-preflight \
        "${prepare_worker_root}/bundle/${_GLM53_PREPARE_VERIFIER}" \
        rsync -aH --partial --append-verify \
        -e ssh \
        BatchMode=yes \
        StrictHostKeyChecking=yes \
        GlobalKnownHostsFile=/dev/null \
        "UserKnownHostsFile=${_PREPARE_FABRIC_KNOWN_HOSTS}" \
        "${_PREPARE_SOURCE_CACHE}/${prepare_target_name}/" \
        "${prepare_target}:${prepare_target_cache}/.glm53-stage-${prepare_run_id}-target-model/${prepare_target_name}/" \
        "${_PREPARE_SOURCE_CACHE}/${prepare_draft_name}/" \
        "${prepare_target}:${prepare_target_cache}/.glm53-stage-${prepare_run_id}-draft-model/${prepare_draft_name}/" \
        target-model-promote \
        "${prepare_target_cache}/${prepare_target_name}" \
        "${prepare_target_cache}/${prepare_draft_name}" \
        same-filesystem-atomic-promote \
        no-overwrite
    fi
    prepare_index=$((prepare_index + 1))
  done
}

_prepare_body_and_digest() {
  local prepare_run_id=$1
  local prepare_body
  local prepare_digest
  prepare_body="$(_prepare_render_body "${prepare_run_id}")"
  prepare_digest="$(printf '%s\n' "${prepare_body}" | _prepare_sha256_text)"
  printf '%s\nPLAN_SHA256: %s\n' "${prepare_body}" "${prepare_digest}"
}

_prepare_validate_run_id() {
  common_validate_run_id "$1" || {
    common_die "prepare run ID does not use the required run identity format" 2
    return 2
  }
}

prepare_plan() {
  local prepare_config=$1
  local prepare_lock=$2
  local prepare_run_id=$3
  _prepare_validate_run_id "${prepare_run_id}" &&
    _prepare_load_contract "${prepare_config}" "${prepare_lock}" &&
    _prepare_validate_local_artifacts &&
    _prepare_body_and_digest "${prepare_run_id}"
}

_prepare_plan_digest() {
  local prepare_run_id=$1
  local prepare_body
  prepare_body="$(_prepare_render_body "${prepare_run_id}")"
  printf '%s\n' "${prepare_body}" | _prepare_sha256_text
}

_prepare_run_source_action() {
  local prepare_action=$1
  local prepare_run_id=$2
  local prepare_management_known_hosts
  local prepare_option
  local prepare_index
  local -a prepare_ssh_options
  local -a prepare_arguments

  prepare_management_known_hosts="$(
    python3 "${_GLM53_FABRIC_TOOL}" \
      expand-known-hosts \
      --path "$(config_export ssh_known_hosts_file "${_PREPARE_CONFIG_PATH}")"
  )"
  prepare_ssh_options=()
  while IFS= read -r prepare_option; do
    prepare_ssh_options[${#prepare_ssh_options[@]}]="${prepare_option}"
  done < <(doctor_ssh_options "${prepare_management_known_hosts}")

  prepare_arguments=(
    "${prepare_action}"
    "${prepare_run_id}"
    "${_PREPARE_SOURCE_ROOT}"
    "${_PREPARE_SOURCE_CACHE}"
    "${_GLM53_PREPARE_MACHINE_ID}"
    "${_PREPARE_SOURCE_MACHINE_DIGEST}"
    "${_PREPARE_CONFIG_DIGEST}"
    "${_PREPARE_LOCK_DIGEST}"
    "${_PREPARE_FABRIC_KNOWN_HOSTS}"
    "${_PREPARE_BASE_IMAGE}"
    "${_PREPARE_BASE_ARM64}"
    "${_PREPARE_SGLANG_COMMIT}"
    "${_PREPARE_IMAGE_REPOSITORY}"
    "${_PREPARE_IMAGE_OWNER}"
    "${_PREPARE_CONTAINERFILE}"
    "${_PREPARE_CONTAINERFILE_DIGEST}"
    "${_PREPARE_PATCH_SERIES}"
    "${_PREPARE_PATCH_SERIES_DIGEST}"
    "${_GLM53_PREPARE_PATCH}"
    "${_PREPARE_PATCH_DIGEST}"
    "$(_prepare_sha256_file "${_GLM53_PREPARE_ROOT}/${_GLM53_PREPARE_VERIFIER}")"
    "$(
      _prepare_sha256_file \
        "${_GLM53_PREPARE_ROOT}/${_GLM53_PREPARE_MANIFEST_TOOL}"
    )"
    "$(
      _prepare_sha256_file \
        "${_GLM53_PREPARE_ROOT}/${_GLM53_PREPARE_SERIES_TOOL}"
    )"
    "${_PREPARE_TARGET_REPO}"
    "${_PREPARE_TARGET_REVISION}"
    "${_PREPARE_TARGET_SHARDS}"
    "${_PREPARE_TARGET_TENSOR_BYTES}"
    "${_PREPARE_TARGET_HUB_BYTES}"
    "${_PREPARE_TARGET_MANIFEST}"
    "${_PREPARE_TARGET_MANIFEST_DIGEST}"
    "${_PREPARE_DRAFT_REPO}"
    "${_PREPARE_DRAFT_REVISION}"
    "${_PREPARE_DRAFT_SHARDS}"
    "${_PREPARE_DRAFT_TENSOR_BYTES}"
    "${_PREPARE_DRAFT_MANIFEST}"
    "${_PREPARE_DRAFT_MANIFEST_DIGEST}"
  )
  prepare_index=0
  while [ "${prepare_index}" -lt 4 ]; do
    prepare_arguments[${#prepare_arguments[@]}]=${_PREPARE_NODE_IDS[prepare_index]}
    prepare_arguments[${#prepare_arguments[@]}]=${_PREPARE_NODE_ROLES[prepare_index]}
    prepare_arguments[${#prepare_arguments[@]}]=${_PREPARE_NODE_ROOTS[prepare_index]}
    prepare_arguments[${#prepare_arguments[@]}]=${_PREPARE_NODE_FABRIC_IPS[prepare_index]}
    prepare_arguments[${#prepare_arguments[@]}]=${_PREPARE_NODE_CACHE_ROOTS[prepare_index]}
    prepare_arguments[${#prepare_arguments[@]}]=${_PREPARE_NODE_MACHINE_DIGESTS[prepare_index]}
    prepare_index=$((prepare_index + 1))
  done

  ssh \
    "${prepare_ssh_options[@]}" \
    "${_PREPARE_SOURCE_ALIAS}" \
    bash -s -- \
    "${prepare_arguments[@]}" \
    <"${_GLM53_PREPARE_REMOTE}"
}

prepare_apply() {
  local prepare_config=$1
  local prepare_lock=$2
  local prepare_run_id=$3
  local prepare_expected_digest=$4
  local prepare_license=$5
  local prepare_actual_digest
  local prepare_action

  _prepare_validate_run_id "${prepare_run_id}" || return
  [ "${prepare_license}" = "CC-BY-NC-ND-4.0" ] || {
    common_die "prepare apply requires --acknowledge-draft-license CC-BY-NC-ND-4.0"
    return 1
  }
  _PREPARE_CONFIG_PATH=${prepare_config}
  _prepare_load_contract "${prepare_config}" "${prepare_lock}" || return
  _prepare_validate_local_artifacts || return
  prepare_actual_digest="$(_prepare_plan_digest "${prepare_run_id}")"
  [ "${prepare_actual_digest}" = "${prepare_expected_digest}" ] || {
    common_die "printed plan digest is stale or does not match"
    return 1
  }

  DOCTOR_CONFIG_VALIDATED=1 DOCTOR_OUTPUT_FORMAT=json \
    doctor_run "${prepare_config}" "${prepare_lock}" >/dev/null || {
    common_die "fresh prepare doctor preflight failed"
    return 1
  }

  config_validate "${prepare_config}" "${prepare_lock}" || return
  _prepare_load_contract "${prepare_config}" "${prepare_lock}" || return
  _prepare_validate_local_artifacts || return
  [ "$(_prepare_plan_digest "${prepare_run_id}")" = "${prepare_expected_digest}" ] || {
    common_die "prepare identities changed after doctor"
    return 1
  }

  # Exactly the fixed action sequence that the printed plan represents.
  for prepare_action in \
    preflight \
    bootstrap \
    build \
    target-model \
    draft-model \
    distribute; do
    _prepare_run_source_action "${prepare_action}" "${prepare_run_id}" || return
  done
}

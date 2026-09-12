#!/usr/bin/env bash

# Parallel two-phase TP4 lifecycle: plan-only by default, fail-closed on apply.
#
# Module dependencies, which callers must source first:
#   lib/common.sh   deterministic action printing and the error contract
#   lib/config.sh   validated cluster configuration revalidation
#   lib/doctor.sh   strict key-only SSH options and the read-only preflight

_GLM53_LIFECYCLE_LIB_DIR="$(
  cd "$(dirname "${BASH_SOURCE[0]}")" && pwd
)"
readonly _GLM53_LIFECYCLE_LIB_DIR
readonly _GLM53_LIFECYCLE_ROOT="${_GLM53_LIFECYCLE_LIB_DIR}/.."
readonly _GLM53_LIFECYCLE_STATE_TOOL="${_GLM53_LIFECYCLE_ROOT}/tools/config_state.py"
readonly _GLM53_LIFECYCLE_PATCH="runtime/patches/sglang-glm53-gb10-tilelang.patch"
readonly _GLM53_LIFECYCLE_MACHINE_ID="/etc/machine-id"
readonly _GLM53_LIFECYCLE_OWNER="glm53-spark"
readonly _GLM53_LIFECYCLE_CONTAINER_LOG_DIR="/var/log/glm53-spark"
readonly _GLM53_LIFECYCLE_STOP_TIMEOUT_SECONDS=30
readonly _GLM53_LIFECYCLE_LOG_TAIL_LINES=200
readonly _GLM53_LIFECYCLE_HEALTH_TIMEOUT_SECONDS=10
readonly _GLM53_LIFECYCLE_READY_INTERVAL_DEFAULT=10
readonly _GLM53_LIFECYCLE_SHM_SIZE=16g
readonly _GLM53_LIFECYCLE_GPU_DEVICE=nvidia.com/gpu=all
readonly _GLM53_LIFECYCLE_TAB='	'
readonly _GLM53_LIFECYCLE_NEWLINE='
'

readonly _GLM53_LIFECYCLE_OWNER_LABEL=com.glm53-spark.owner
readonly _GLM53_LIFECYCLE_RUN_LABEL=com.glm53-spark.run-id
readonly _GLM53_LIFECYCLE_RANK_LABEL=com.glm53-spark.rank
readonly _GLM53_LIFECYCLE_NODE_LABEL=com.glm53-spark.node-id
readonly _GLM53_LIFECYCLE_CONFIG_LABEL=com.glm53-spark.config-digest
readonly _GLM53_LIFECYCLE_LOCK_LABEL=com.glm53-spark.lock-digest
readonly _GLM53_LIFECYCLE_PROFILE_LABEL=com.glm53-spark.profile

# Fixed Go template literals and filters. They are code, never derived text.
readonly _GLM53_LIFECYCLE_PS_FORMAT='{{.ID}}|{{.Names}}|{{.Image}}|{{.State}}'
readonly _GLM53_LIFECYCLE_NAMES_FORMAT='{{.Names}}'
readonly _GLM53_LIFECYCLE_IDS_FORMAT='{{.ID}}'
readonly _GLM53_LIFECYCLE_IMAGE_FORMAT='{{index .Config.Labels "io.glm53.owner"}}'
readonly _GLM53_LIFECYCLE_RUN_FORMAT='{{.Id}}|{{.State.Running}}|{{index .Config.Labels "com.glm53-spark.run-id"}}|{{index .Config.Labels "com.glm53-spark.rank"}}|{{index .Config.Labels "com.glm53-spark.owner"}}'
readonly _GLM53_LIFECYCLE_SERVICE_FORMAT='{{.Id}}|{{index .Config.Labels "com.glm53-spark.owner"}}|{{.Config.Image}}|{{.State.Running}}'
readonly _GLM53_LIFECYCLE_OWNER_FILTER='label=com.glm53-spark.owner=glm53-spark'

# Direct SGLang endpoints used to prove serving identity, not mere liveness.
readonly _GLM53_LIFECYCLE_MODEL_INFO_PATH=get_model_info
readonly _GLM53_LIFECYCLE_SERVED_MODELS_PATH=v1/models
readonly _GLM53_LIFECYCLE_GENERATE_HEALTH_PATH=health_generate

# Local files whose bytes change what apply does. They are not carried in the
# reproduction lock, so the printed plan pins them explicitly and the plan
# digest covers them. Changing any of them invalidates a printed plan.
_lifecycle_plan_pinned_files() {
  printf '%s\n' \
    glm53-spark \
    lib/common.sh \
    lib/config.sh \
    lib/doctor.sh \
    lib/lifecycle.sh \
    tools/config_state.py \
    tools/fabric_probe.py \
    tools/node_probe.py
}

_lifecycle_sha256_file() {
  local lifecycle_path=$1
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "${lifecycle_path}" | awk '{print $1}'
  else
    sha256sum "${lifecycle_path}" | awk '{print $1}'
  fi
}

_lifecycle_sha256_text() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    sha256sum | awk '{print $1}'
  fi
}

_lifecycle_join_tab() {
  local lifecycle_field
  local lifecycle_line=
  for lifecycle_field in "$@"; do
    if [ -n "${lifecycle_line}" ]; then
      lifecycle_line="${lifecycle_line}${_GLM53_LIFECYCLE_TAB}${lifecycle_field}"
    else
      lifecycle_line="${lifecycle_field}"
    fi
  done
  printf '%s\n' "${lifecycle_line}"
}

_lifecycle_require_plain_file() {
  local lifecycle_path=$1
  [ -f "${lifecycle_path}" ] && [ ! -L "${lifecycle_path}" ] || {
    common_die "plan-pinned local file is missing or not a plain file"
    return 1
  }
}

_lifecycle_require_digest() {
  local lifecycle_path=$1
  local lifecycle_expected=$2
  local lifecycle_actual
  _lifecycle_require_plain_file "${lifecycle_path}" || return 1
  lifecycle_actual="$(_lifecycle_sha256_file "${lifecycle_path}")"
  [ "${lifecycle_actual}" = "${lifecycle_expected}" ] || {
    common_die "lifecycle artifact digest does not match the reproduction lock"
    return 1
  }
}

_lifecycle_validate_run_id() {
  common_validate_run_id "$1" || {
    common_die "lifecycle run ID does not use the required run identity format" 2
    return 2
  }
}

_lifecycle_validate_rank() {
  case "$1" in
    0|1|2|3) ;;
    *)
      common_die "rank must be 0, 1, 2, or 3" 2
      return 2
      ;;
  esac
}

_lifecycle_load_contract() {
  local lifecycle_config=$1
  local lifecycle_lock=$2
  local lifecycle_value
  local lifecycle_index
  local lifecycle_base
  local -a lifecycle_values

  lifecycle_values=()
  while IFS= read -r -d '' lifecycle_value; do
    lifecycle_values[${#lifecycle_values[@]}]="${lifecycle_value}"
  done < <(
    python3 "${_GLM53_LIFECYCLE_STATE_TOOL}" lifecycle-export \
      --config "${lifecycle_config}" \
      --lock "${lifecycle_lock}"
  )
  [ "${#lifecycle_values[@]}" -eq 78 ] || {
    common_die "lifecycle contract export is incomplete" 2
    return 2
  }

  _LIFECYCLE_CONFIG_DIGEST=${lifecycle_values[0]}
  _LIFECYCLE_LOCK_DIGEST=${lifecycle_values[1]}
  _LIFECYCLE_KNOWN_HOSTS_RAW=${lifecycle_values[2]}
  _LIFECYCLE_CONNECT_TIMEOUT=${lifecycle_values[3]}
  _LIFECYCLE_COMMAND_TIMEOUT=${lifecycle_values[4]}
  _LIFECYCLE_API_PORT=${lifecycle_values[5]}
  _LIFECYCLE_DIST_PORT=${lifecycle_values[6]}
  _LIFECYCLE_IMAGE_REPOSITORY=${lifecycle_values[7]}
  _LIFECYCLE_IMAGE_OWNER=${lifecycle_values[8]}
  _LIFECYCLE_TARGET_REPO=${lifecycle_values[9]}
  _LIFECYCLE_TARGET_REVISION=${lifecycle_values[10]}
  _LIFECYCLE_TARGET_MANIFEST=${lifecycle_values[11]}
  _LIFECYCLE_TARGET_MANIFEST_DIGEST=${lifecycle_values[12]}
  _LIFECYCLE_DRAFT_REPO=${lifecycle_values[13]}
  _LIFECYCLE_DRAFT_REVISION=${lifecycle_values[14]}
  _LIFECYCLE_DRAFT_MANIFEST=${lifecycle_values[15]}
  _LIFECYCLE_DRAFT_MANIFEST_DIGEST=${lifecycle_values[16]}
  _LIFECYCLE_CONTAINERFILE=${lifecycle_values[17]}
  _LIFECYCLE_CONTAINERFILE_DIGEST=${lifecycle_values[18]}
  _LIFECYCLE_PATCH_SERIES=${lifecycle_values[19]}
  _LIFECYCLE_PATCH_SERIES_DIGEST=${lifecycle_values[20]}
  _LIFECYCLE_PATCH_DIGEST=${lifecycle_values[21]}
  _LIFECYCLE_PROFILE_NAME=${lifecycle_values[22]}
  _LIFECYCLE_SERVED_NAME=${lifecycle_values[23]}
  _LIFECYCLE_TP_SIZE=${lifecycle_values[24]}
  _LIFECYCLE_NNODES=${lifecycle_values[25]}
  _LIFECYCLE_PP_SIZE=${lifecycle_values[26]}
  _LIFECYCLE_CONTEXT_LENGTH=${lifecycle_values[27]}
  _LIFECYCLE_MAX_RUNNING_REQUESTS=${lifecycle_values[28]}
  _LIFECYCLE_MEM_FRACTION_STATIC=${lifecycle_values[29]}
  _LIFECYCLE_CHUNKED_PREFILL_SIZE=${lifecycle_values[30]}
  _LIFECYCLE_MAX_MAMBA_CACHE_SIZE=${lifecycle_values[31]}
  _LIFECYCLE_SPEC_ALGORITHM=${lifecycle_values[32]}
  _LIFECYCLE_SPEC_NUM_DRAFT_TOKENS=${lifecycle_values[33]}
  _LIFECYCLE_DFLASH_BLOCK_SIZE=${lifecycle_values[34]}
  _LIFECYCLE_DRAFT_ATTENTION_BACKEND=${lifecycle_values[35]}
  _LIFECYCLE_PREFILL_ATTENTION_BACKEND=${lifecycle_values[36]}
  _LIFECYCLE_DECODE_ATTENTION_BACKEND=${lifecycle_values[37]}
  _LIFECYCLE_KV_CACHE_DTYPE=${lifecycle_values[38]}
  _LIFECYCLE_MOE_RUNNER_BACKEND=${lifecycle_values[39]}
  _LIFECYCLE_SHARED_EXPERTS_FUSION=${lifecycle_values[40]}
  _LIFECYCLE_REASONING_PARSER=${lifecycle_values[41]}
  _LIFECYCLE_TOOL_CALL_PARSER=${lifecycle_values[42]}
  _LIFECYCLE_SAMPLING_DEFAULTS=${lifecycle_values[43]}
  _LIFECYCLE_RADIX_CACHE=${lifecycle_values[44]}
  _LIFECYCLE_DIST_TIMEOUT_SECONDS=${lifecycle_values[45]}

  _LIFECYCLE_NODE_IDS=()
  _LIFECYCLE_NODE_ALIASES=()
  _LIFECYCLE_NODE_ROLES=()
  _LIFECYCLE_NODE_ROOTS=()
  _LIFECYCLE_NODE_FABRIC_IPS=()
  _LIFECYCLE_NODE_CACHE_ROOTS=()
  _LIFECYCLE_NODE_MACHINE_DIGESTS=()
  lifecycle_index=0
  while [ "${lifecycle_index}" -lt 4 ]; do
    lifecycle_base=$((46 + lifecycle_index * 8))
    [ "${lifecycle_values[lifecycle_base + 1]}" = "${lifecycle_index}" ] || {
      common_die "the validated node order does not map ranks 0 through 3" 2
      return 2
    }
    _LIFECYCLE_NODE_IDS[lifecycle_index]=${lifecycle_values[lifecycle_base]}
    _LIFECYCLE_NODE_ALIASES[lifecycle_index]=${lifecycle_values[lifecycle_base + 2]}
    _LIFECYCLE_NODE_ROLES[lifecycle_index]=${lifecycle_values[lifecycle_base + 3]}
    _LIFECYCLE_NODE_ROOTS[lifecycle_index]=${lifecycle_values[lifecycle_base + 4]}
    _LIFECYCLE_NODE_FABRIC_IPS[lifecycle_index]=${lifecycle_values[lifecycle_base + 5]}
    _LIFECYCLE_NODE_CACHE_ROOTS[lifecycle_index]=${lifecycle_values[lifecycle_base + 6]}
    _LIFECYCLE_NODE_MACHINE_DIGESTS[lifecycle_index]=${lifecycle_values[lifecycle_base + 7]}
    lifecycle_index=$((lifecycle_index + 1))
  done

  _LIFECYCLE_READY_INTERVAL=${_GLM53_LIFECYCLE_READY_INTERVAL_DEFAULT}
  _LIFECYCLE_READY_ATTEMPTS=$((
    _LIFECYCLE_DIST_TIMEOUT_SECONDS / _GLM53_LIFECYCLE_READY_INTERVAL_DEFAULT
  ))
  if [ "${GLM53_TESTING:-0}" = "1" ]; then
    _LIFECYCLE_READY_ATTEMPTS=${GLM53_LIFECYCLE_READY_ATTEMPTS:-${_LIFECYCLE_READY_ATTEMPTS}}
    _LIFECYCLE_READY_INTERVAL=${GLM53_LIFECYCLE_READY_INTERVAL_SECONDS:-${_LIFECYCLE_READY_INTERVAL}}
  fi
  [ "${_LIFECYCLE_READY_ATTEMPTS}" -ge 1 ] || {
    common_die "the bounded readiness wait must allow at least one attempt" 2
    return 2
  }
}

_lifecycle_validate_local_artifacts() {
  local lifecycle_file
  _lifecycle_require_digest \
    "${_GLM53_LIFECYCLE_ROOT}/${_LIFECYCLE_TARGET_MANIFEST}" \
    "${_LIFECYCLE_TARGET_MANIFEST_DIGEST}" &&
    _lifecycle_require_digest \
      "${_GLM53_LIFECYCLE_ROOT}/${_LIFECYCLE_DRAFT_MANIFEST}" \
      "${_LIFECYCLE_DRAFT_MANIFEST_DIGEST}" &&
    _lifecycle_require_digest \
      "${_GLM53_LIFECYCLE_ROOT}/${_LIFECYCLE_CONTAINERFILE}" \
      "${_LIFECYCLE_CONTAINERFILE_DIGEST}" &&
    _lifecycle_require_digest \
      "${_GLM53_LIFECYCLE_ROOT}/${_LIFECYCLE_PATCH_SERIES}" \
      "${_LIFECYCLE_PATCH_SERIES_DIGEST}" &&
    _lifecycle_require_digest \
      "${_GLM53_LIFECYCLE_ROOT}/${_GLM53_LIFECYCLE_PATCH}" \
      "${_LIFECYCLE_PATCH_DIGEST}" || return

  while IFS= read -r lifecycle_file; do
    _lifecycle_require_plain_file \
      "${_GLM53_LIFECYCLE_ROOT}/${lifecycle_file}" || return
  done < <(_lifecycle_plan_pinned_files)
}

_lifecycle_cache_name() {
  printf 'models--%s\n' "${1//\//--}"
}

_lifecycle_container_name() {
  printf '%s-%s-rank%s\n' "${_GLM53_LIFECYCLE_OWNER}" "$1" "$2"
}

_lifecycle_image_reference() {
  printf '%s:%s\n' "${_LIFECYCLE_IMAGE_REPOSITORY}" "$1"
}

_lifecycle_log_directory() {
  printf '%s/.runtime/launch/%s/logs\n' "${_LIFECYCLE_NODE_ROOTS[$1]}" "$2"
}

_lifecycle_snapshot_path() {
  local lifecycle_rank=$1
  local lifecycle_repository=$2
  local lifecycle_revision=$3
  printf '%s/%s/snapshots/%s\n' \
    "${_LIFECYCLE_NODE_CACHE_ROOTS[lifecycle_rank]}" \
    "$(_lifecycle_cache_name "${lifecycle_repository}")" \
    "${lifecycle_revision}"
}

# Serving probes always take an explicit host and port so read-only inspection
# and post-release waits can bind to the recorded run instead of whatever the
# current configuration happens to say.
_lifecycle_endpoint_url() {
  printf 'http://%s:%s/%s\n' "$1" "$2" "$3"
}

# Builds the immutable rank launch action array in _LIFECYCLE_RELEASE_ARGV.
_lifecycle_build_release_argv() {
  local lifecycle_rank=$1
  local lifecycle_run_id=$2
  local lifecycle_cache=${_LIFECYCLE_NODE_CACHE_ROOTS[$1]}
  local lifecycle_container
  local lifecycle_log_directory
  local lifecycle_target_path
  local lifecycle_draft_path

  lifecycle_container="$(
    _lifecycle_container_name "${lifecycle_run_id}" "${lifecycle_rank}"
  )"
  lifecycle_log_directory="$(
    _lifecycle_log_directory "${lifecycle_rank}" "${lifecycle_run_id}"
  )"
  lifecycle_target_path="$(
    _lifecycle_snapshot_path \
      "${lifecycle_rank}" \
      "${_LIFECYCLE_TARGET_REPO}" \
      "${_LIFECYCLE_TARGET_REVISION}"
  )"
  lifecycle_draft_path="$(
    _lifecycle_snapshot_path \
      "${lifecycle_rank}" \
      "${_LIFECYCLE_DRAFT_REPO}" \
      "${_LIFECYCLE_DRAFT_REVISION}"
  )"

  _LIFECYCLE_RELEASE_ARGV=(
    docker run --detach
    --name "${lifecycle_container}"
    --label "${_GLM53_LIFECYCLE_OWNER_LABEL}=${_GLM53_LIFECYCLE_OWNER}"
    --label "${_GLM53_LIFECYCLE_RUN_LABEL}=${lifecycle_run_id}"
    --label "${_GLM53_LIFECYCLE_RANK_LABEL}=${lifecycle_rank}"
    --label "${_GLM53_LIFECYCLE_NODE_LABEL}=${_LIFECYCLE_NODE_IDS[$1]}"
    --label "${_GLM53_LIFECYCLE_CONFIG_LABEL}=${_LIFECYCLE_CONFIG_DIGEST}"
    --label "${_GLM53_LIFECYCLE_LOCK_LABEL}=${_LIFECYCLE_LOCK_DIGEST}"
    --label "${_GLM53_LIFECYCLE_PROFILE_LABEL}=${_LIFECYCLE_PROFILE_NAME}"
    --restart no
    --network host
    --ipc host
    --shm-size "${_GLM53_LIFECYCLE_SHM_SIZE}"
    --device "${_GLM53_LIFECYCLE_GPU_DEVICE}"
    --mount "type=bind,source=${lifecycle_cache},target=${lifecycle_cache},readonly"
    --mount "type=bind,source=${lifecycle_log_directory},target=${_GLM53_LIFECYCLE_CONTAINER_LOG_DIR}"
    "$(_lifecycle_image_reference "${lifecycle_run_id}")"
    python3 -m sglang.launch_server
    --model-path "${lifecycle_target_path}"
    --served-model-name "${_LIFECYCLE_SERVED_NAME}"
    --tp-size "${_LIFECYCLE_TP_SIZE}"
    --nnodes "${_LIFECYCLE_NNODES}"
    --node-rank "${lifecycle_rank}"
    --pp-size "${_LIFECYCLE_PP_SIZE}"
    --dist-init-addr "${_LIFECYCLE_NODE_FABRIC_IPS[0]}:${_LIFECYCLE_DIST_PORT}"
    --dist-timeout "${_LIFECYCLE_DIST_TIMEOUT_SECONDS}"
    --host "${_LIFECYCLE_NODE_FABRIC_IPS[$1]}"
    --port "${_LIFECYCLE_API_PORT}"
    --context-length "${_LIFECYCLE_CONTEXT_LENGTH}"
    --max-running-requests "${_LIFECYCLE_MAX_RUNNING_REQUESTS}"
    --mem-fraction-static "${_LIFECYCLE_MEM_FRACTION_STATIC}"
    --chunked-prefill-size "${_LIFECYCLE_CHUNKED_PREFILL_SIZE}"
    --max-mamba-cache-size "${_LIFECYCLE_MAX_MAMBA_CACHE_SIZE}"
    --speculative-algorithm "${_LIFECYCLE_SPEC_ALGORITHM}"
    --speculative-draft-model-path "${lifecycle_draft_path}"
    --speculative-num-draft-tokens "${_LIFECYCLE_SPEC_NUM_DRAFT_TOKENS}"
    --speculative-dflash-block-size "${_LIFECYCLE_DFLASH_BLOCK_SIZE}"
    --speculative-draft-attention-backend "${_LIFECYCLE_DRAFT_ATTENTION_BACKEND}"
    --prefill-attention-backend "${_LIFECYCLE_PREFILL_ATTENTION_BACKEND}"
    --decode-attention-backend "${_LIFECYCLE_DECODE_ATTENTION_BACKEND}"
    --kv-cache-dtype "${_LIFECYCLE_KV_CACHE_DTYPE}"
    --moe-runner-backend "${_LIFECYCLE_MOE_RUNNER_BACKEND}"
    --reasoning-parser "${_LIFECYCLE_REASONING_PARSER}"
    --tool-call-parser "${_LIFECYCLE_TOOL_CALL_PARSER}"
    --sampling-defaults "${_LIFECYCLE_SAMPLING_DEFAULTS}"
  )
  if [ "${_LIFECYCLE_RADIX_CACHE}" != "true" ]; then
    _LIFECYCLE_RELEASE_ARGV[${#_LIFECYCLE_RELEASE_ARGV[@]}]=--disable-radix-cache
  fi
  if [ "${_LIFECYCLE_SHARED_EXPERTS_FUSION}" != "true" ]; then
    _LIFECYCLE_RELEASE_ARGV[${#_LIFECYCLE_RELEASE_ARGV[@]}]=--disable-shared-experts-fusion
  fi
}

# ---------------------------------------------------------------------------
# Plan rendering
# ---------------------------------------------------------------------------

_lifecycle_render_inputs() {
  local lifecycle_file
  local lifecycle_pinned

  common_print_action \
    plan-input \
    config-digest "${_LIFECYCLE_CONFIG_DIGEST}" \
    lock-digest "${_LIFECYCLE_LOCK_DIGEST}"
  while IFS= read -r lifecycle_file; do
    common_print_action \
      plan-input \
      plan-pinned-sha256 \
      "${lifecycle_file}" \
      "$(_lifecycle_sha256_file "${_GLM53_LIFECYCLE_ROOT}/${lifecycle_file}")"
  done < <(_lifecycle_plan_pinned_files)
  for lifecycle_pinned in \
    "${_LIFECYCLE_CONTAINERFILE}:${_LIFECYCLE_CONTAINERFILE_DIGEST}" \
    "${_LIFECYCLE_PATCH_SERIES}:${_LIFECYCLE_PATCH_SERIES_DIGEST}" \
    "${_GLM53_LIFECYCLE_PATCH}:${_LIFECYCLE_PATCH_DIGEST}" \
    "${_LIFECYCLE_TARGET_MANIFEST}:${_LIFECYCLE_TARGET_MANIFEST_DIGEST}" \
    "${_LIFECYCLE_DRAFT_MANIFEST}:${_LIFECYCLE_DRAFT_MANIFEST_DIGEST}"; do
    common_print_action \
      lock-input \
      lock-pinned-sha256 \
      "${lifecycle_pinned%%:*}" \
      "${lifecycle_pinned#*:}"
  done
}

# Phase one runs as three ordered sub-phases across all four ranks: a strictly
# read-only verification sweep, then the only mutating sweep, then a read-only
# confirmation sweep. Rendering follows the same order as apply.
_lifecycle_render_phase_one_verify() {
  local lifecycle_rank=$1
  local lifecycle_run_id=$2
  local lifecycle_node=${_LIFECYCLE_NODE_IDS[$1]}
  local lifecycle_alias=${_LIFECYCLE_NODE_ALIASES[$1]}
  local lifecycle_container

  lifecycle_container="$(
    _lifecycle_container_name "${lifecycle_run_id}" "${lifecycle_rank}"
  )"
  common_print_action \
    phase-one-record-prelaunch "${lifecycle_rank}" "${lifecycle_node}" \
    ssh "${lifecycle_alias}" \
    docker ps --no-trunc --format "${_GLM53_LIFECYCLE_PS_FORMAT}" \
    --filter "${_GLM53_LIFECYCLE_OWNER_FILTER}"
  common_print_action \
    phase-one-verify-identity "${lifecycle_rank}" "${lifecycle_node}" \
    ssh "${lifecycle_alias}" \
    cat "${_GLM53_LIFECYCLE_MACHINE_ID}" \
    expect-sha256 "${_LIFECYCLE_NODE_MACHINE_DIGESTS[$1]}"
  common_print_action \
    phase-one-verify-image "${lifecycle_rank}" "${lifecycle_node}" \
    ssh "${lifecycle_alias}" \
    docker image inspect --format "${_GLM53_LIFECYCLE_IMAGE_FORMAT}" \
    "$(_lifecycle_image_reference "${lifecycle_run_id}")" \
    expect-owner "${_LIFECYCLE_IMAGE_OWNER}"
  common_print_action \
    phase-one-verify-target-model "${lifecycle_rank}" "${lifecycle_node}" \
    ssh "${lifecycle_alias}" \
    test -d "$(
      _lifecycle_snapshot_path \
        "${lifecycle_rank}" \
        "${_LIFECYCLE_TARGET_REPO}" \
        "${_LIFECYCLE_TARGET_REVISION}"
    )"
  common_print_action \
    phase-one-verify-draft-model "${lifecycle_rank}" "${lifecycle_node}" \
    ssh "${lifecycle_alias}" \
    test -d "$(
      _lifecycle_snapshot_path \
        "${lifecycle_rank}" \
        "${_LIFECYCLE_DRAFT_REPO}" \
        "${_LIFECYCLE_DRAFT_REVISION}"
    )"
  common_print_action \
    phase-one-verify-name-free "${lifecycle_rank}" "${lifecycle_node}" \
    ssh "${lifecycle_alias}" \
    docker ps -a --format "${_GLM53_LIFECYCLE_NAMES_FORMAT}" \
    --filter "name=${lifecycle_container}"
  # A port held by anything other than a recorded owned pre-launch service on
  # this very rank rejects the launch here, before any node is mutated.
  common_print_action \
    phase-one-verify-ports "${lifecycle_rank}" "${lifecycle_node}" \
    ssh "${lifecycle_alias}" \
    ss -H -ltn \
    expect-free-unless-owned "${_LIFECYCLE_API_PORT}" "${_LIFECYCLE_DIST_PORT}"
}

_lifecycle_render_phase_one_prepare() {
  local lifecycle_rank=$1
  local lifecycle_run_id=$2
  local lifecycle_node=${_LIFECYCLE_NODE_IDS[$1]}
  local lifecycle_alias=${_LIFECYCLE_NODE_ALIASES[$1]}

  common_print_action \
    phase-one-prepare-logs "${lifecycle_rank}" "${lifecycle_node}" \
    ssh "${lifecycle_alias}" \
    mkdir -p "$(
      _lifecycle_log_directory "${lifecycle_rank}" "${lifecycle_run_id}"
    )"
  # The pre-launch owned service names come from the read-only probe above, so
  # the plan pins the fixed action shape and the exact owner filter instead.
  common_print_action \
    phase-one-quiesce-prelaunch "${lifecycle_rank}" "${lifecycle_node}" \
    ssh "${lifecycle_alias}" \
    docker stop --time "${_GLM53_LIFECYCLE_STOP_TIMEOUT_SECONDS}" \
    recorded-prelaunch-service \
    owner-filter "${_GLM53_LIFECYCLE_OWNER_FILTER}"
}

_lifecycle_render_phase_one_confirm() {
  local lifecycle_rank=$1
  common_print_action \
    phase-one-confirm-ports "${lifecycle_rank}" "${_LIFECYCLE_NODE_IDS[$1]}" \
    ssh "${_LIFECYCLE_NODE_ALIASES[$1]}" \
    ss -H -ltn \
    expect-free "${_LIFECYCLE_API_PORT}" "${_LIFECYCLE_DIST_PORT}"
}

# Renders the three bounded serving-identity probes for one endpoint.
_lifecycle_render_serving_probes() {
  local lifecycle_action=$1
  local lifecycle_node=$2
  local lifecycle_alias=$3
  local lifecycle_host=$4
  local lifecycle_port=$5
  local lifecycle_served=$6
  local lifecycle_model_path=$7

  common_print_action \
    "${lifecycle_action}" \
    "${lifecycle_node}" \
    ssh "${lifecycle_alias}" \
    curl --fail --silent --show-error \
    --max-time "${_GLM53_LIFECYCLE_HEALTH_TIMEOUT_SECONDS}" \
    "$(
      _lifecycle_endpoint_url \
        "${lifecycle_host}" \
        "${lifecycle_port}" \
        "${_GLM53_LIFECYCLE_MODEL_INFO_PATH}"
    )" \
    expect-model-path "${lifecycle_model_path}" \
    expect-generation true
  common_print_action \
    "${lifecycle_action}" \
    "${lifecycle_node}" \
    ssh "${lifecycle_alias}" \
    curl --fail --silent --show-error \
    --max-time "${_GLM53_LIFECYCLE_HEALTH_TIMEOUT_SECONDS}" \
    "$(
      _lifecycle_endpoint_url \
        "${lifecycle_host}" \
        "${lifecycle_port}" \
        "${_GLM53_LIFECYCLE_SERVED_MODELS_PATH}"
    )" \
    expect-served-model "${lifecycle_served}"
  common_print_action \
    "${lifecycle_action}" \
    "${lifecycle_node}" \
    ssh "${lifecycle_alias}" \
    curl --fail --silent --show-error \
    --max-time "${_GLM53_LIFECYCLE_HEALTH_TIMEOUT_SECONDS}" \
    "$(
      _lifecycle_endpoint_url \
        "${lifecycle_host}" \
        "${lifecycle_port}" \
        "${_GLM53_LIFECYCLE_GENERATE_HEALTH_PATH}"
    )"
}

_lifecycle_render_launch_body() {
  local lifecycle_run_id=$1
  local lifecycle_index
  local -a lifecycle_containers

  _lifecycle_render_inputs
  common_print_action \
    launch-parameters \
    owner "${_GLM53_LIFECYCLE_OWNER}" \
    run-id "${lifecycle_run_id}" \
    image "$(_lifecycle_image_reference "${lifecycle_run_id}")" \
    image-owner "${_LIFECYCLE_IMAGE_OWNER}" \
    profile "${_LIFECYCLE_PROFILE_NAME}" \
    api-port "${_LIFECYCLE_API_PORT}" \
    dist-port "${_LIFECYCLE_DIST_PORT}" \
    bounded-wait \
    attempts "${_LIFECYCLE_READY_ATTEMPTS}" \
    interval-seconds "${_LIFECYCLE_READY_INTERVAL}"

  lifecycle_containers=()
  lifecycle_index=0
  while [ "${lifecycle_index}" -lt 4 ]; do
    lifecycle_containers[lifecycle_index]="$(
      _lifecycle_container_name "${lifecycle_run_id}" "${lifecycle_index}"
    )"
    _lifecycle_render_phase_one_verify "${lifecycle_index}" "${lifecycle_run_id}"
    lifecycle_index=$((lifecycle_index + 1))
  done
  common_print_action \
    phase-one-verified \
    require-ranks 0 1 2 3 \
    before-any-mutation

  lifecycle_index=0
  while [ "${lifecycle_index}" -lt 4 ]; do
    _lifecycle_render_phase_one_prepare "${lifecycle_index}" "${lifecycle_run_id}"
    lifecycle_index=$((lifecycle_index + 1))
  done

  lifecycle_index=0
  while [ "${lifecycle_index}" -lt 4 ]; do
    _lifecycle_render_phase_one_confirm "${lifecycle_index}"
    lifecycle_index=$((lifecycle_index + 1))
  done

  common_print_action \
    phase-one-complete \
    require-ranks 0 1 2 3 \
    before-any-release

  lifecycle_index=0
  while [ "${lifecycle_index}" -lt 4 ]; do
    _lifecycle_build_release_argv "${lifecycle_index}" "${lifecycle_run_id}"
    common_print_action \
      phase-two-release \
      "${lifecycle_index}" \
      "${_LIFECYCLE_NODE_IDS[lifecycle_index]}" \
      ssh "${_LIFECYCLE_NODE_ALIASES[lifecycle_index]}" \
      stdin-detached \
      "${_LIFECYCLE_RELEASE_ARGV[@]}"
    lifecycle_index=$((lifecycle_index + 1))
  done
  common_print_action \
    phase-two-collect \
    wait-all-rank-processes \
    ranks 0 1 2 3

  lifecycle_index=0
  while [ "${lifecycle_index}" -lt 4 ]; do
    common_print_action \
      collective-readiness \
      "${lifecycle_index}" \
      "${_LIFECYCLE_NODE_IDS[lifecycle_index]}" \
      ssh "${_LIFECYCLE_NODE_ALIASES[lifecycle_index]}" \
      docker inspect --format "${_GLM53_LIFECYCLE_RUN_FORMAT}" \
      "${lifecycle_containers[lifecycle_index]}" \
      expect "true|${lifecycle_run_id}|${lifecycle_index}|${_GLM53_LIFECYCLE_OWNER}"
    lifecycle_index=$((lifecycle_index + 1))
  done

  _lifecycle_render_serving_probes \
    api-health \
    "${_LIFECYCLE_NODE_IDS[0]}" \
    "${_LIFECYCLE_NODE_ALIASES[0]}" \
    "${_LIFECYCLE_NODE_FABRIC_IPS[0]}" \
    "${_LIFECYCLE_API_PORT}" \
    "${_LIFECYCLE_SERVED_NAME}" \
    "$(
      _lifecycle_snapshot_path \
        0 \
        "${_LIFECYCLE_TARGET_REPO}" \
        "${_LIFECYCLE_TARGET_REVISION}"
    )"

  common_print_action \
    on-failure-stop-run-owned \
    "${lifecycle_containers[@]}"
  common_print_action \
    on-failure-restore-prelaunch \
    docker start recorded-prelaunch-service \
    preserve-containers preserve-images preserve-caches preserve-logs
}

_lifecycle_render_stop_body() {
  local lifecycle_run_id=$1
  local lifecycle_index

  _lifecycle_render_inputs
  common_print_action \
    stop-parameters \
    owner "${_LIFECYCLE_RUN_OWNER}" \
    run-id "${lifecycle_run_id}" \
    recorded-status "${_LIFECYCLE_RUN_STATUS}" \
    image "${_LIFECYCLE_RUN_IMAGE}" \
    recorded-config-digest "${_LIFECYCLE_RUN_CONFIG_DIGEST}" \
    recorded-lock-digest "${_LIFECYCLE_RUN_LOCK_DIGEST}"
  common_print_action \
    require-recorded-contract \
    expect-config-digest "${_LIFECYCLE_CONFIG_DIGEST}" \
    expect-lock-digest "${_LIFECYCLE_LOCK_DIGEST}" \
    before-any-mutation
  lifecycle_index=0
  while [ "${lifecycle_index}" -lt 4 ]; do
    common_print_action \
      verify-ownership \
      "${lifecycle_index}" \
      "${_LIFECYCLE_RUN_NODE_IDS[lifecycle_index]}" \
      ssh "${_LIFECYCLE_RUN_ALIASES[lifecycle_index]}" \
      docker inspect --format "${_GLM53_LIFECYCLE_RUN_FORMAT}" \
      "${_LIFECYCLE_RUN_CONTAINERS[lifecycle_index]}" \
      expect-id "${_LIFECYCLE_RUN_CONTAINER_IDS[lifecycle_index]}" \
      expect-owner "${_LIFECYCLE_RUN_OWNER}" \
      expect-run "${lifecycle_run_id}" \
      expect-rank "${lifecycle_index}"
    lifecycle_index=$((lifecycle_index + 1))
  done
  lifecycle_index=0
  while [ "${lifecycle_index}" -lt 4 ]; do
    common_print_action \
      stop-run-owned \
      "${lifecycle_index}" \
      "${_LIFECYCLE_RUN_NODE_IDS[lifecycle_index]}" \
      ssh "${_LIFECYCLE_RUN_ALIASES[lifecycle_index]}" \
      docker stop --time "${_GLM53_LIFECYCLE_STOP_TIMEOUT_SECONDS}" \
      "${_LIFECYCLE_RUN_CONTAINER_IDS[lifecycle_index]}"
    lifecycle_index=$((lifecycle_index + 1))
  done
}

_lifecycle_render_rollback_body() {
  local lifecycle_run_id=$1
  local lifecycle_rank
  local lifecycle_id
  local lifecycle_name
  local lifecycle_image
  local lifecycle_state

  _lifecycle_render_stop_body "${lifecycle_run_id}"
  while IFS="${_GLM53_LIFECYCLE_TAB}" read -r lifecycle_rank lifecycle_id \
    lifecycle_name lifecycle_image lifecycle_state; do
    [ -n "${lifecycle_name}" ] || continue
    common_print_action \
      restore-prelaunch-service \
      "${lifecycle_rank}" \
      "${_LIFECYCLE_RUN_NODE_IDS[lifecycle_rank]}" \
      ssh "${_LIFECYCLE_RUN_ALIASES[lifecycle_rank]}" \
      docker inspect --format "${_GLM53_LIFECYCLE_SERVICE_FORMAT}" \
      "${lifecycle_name}" \
      expect-id "${lifecycle_id}" \
      expect-owner "${_LIFECYCLE_RUN_OWNER}" \
      expect-image "${lifecycle_image}" \
      docker start "${lifecycle_id}" \
      recorded-state "${lifecycle_state}"
  done <<EOF
${_LIFECYCLE_RUN_SERVICES}
EOF
  common_print_action \
    rollback-boundary \
    preserve-containers preserve-images preserve-caches \
    preserve-models preserve-artifacts preserve-logs
}

_lifecycle_render_body() {
  local lifecycle_mode=$1
  local lifecycle_run_id=$2
  case "${lifecycle_mode}" in
    launch)
      _lifecycle_render_launch_body "${lifecycle_run_id}"
      ;;
    stop)
      _lifecycle_load_run_record "${lifecycle_run_id}" || return
      _lifecycle_render_stop_body "${lifecycle_run_id}"
      ;;
    rollback)
      _lifecycle_load_run_record "${lifecycle_run_id}" || return
      _lifecycle_render_rollback_body "${lifecycle_run_id}"
      ;;
    *)
      common_die "the lifecycle plan mode must be launch, stop, or rollback" 2
      return 2
      ;;
  esac
}

_lifecycle_plan_digest() {
  local lifecycle_mode=$1
  local lifecycle_run_id=$2
  local lifecycle_body
  lifecycle_body="$(
    _lifecycle_render_body "${lifecycle_mode}" "${lifecycle_run_id}"
  )" || return
  printf '%s\n' "${lifecycle_body}" | _lifecycle_sha256_text
}

lifecycle_plan() {
  local lifecycle_mode=$1
  local lifecycle_run_id=$2
  local lifecycle_body
  local lifecycle_digest

  _lifecycle_validate_run_id "${lifecycle_run_id}" &&
    _lifecycle_load_contract "${_GLM53_CONFIG_PATH}" "${_GLM53_LOCK_PATH}" &&
    _lifecycle_validate_local_artifacts || return

  lifecycle_body="$(
    _lifecycle_render_body "${lifecycle_mode}" "${lifecycle_run_id}"
  )" || return
  lifecycle_digest="$(
    printf '%s\n' "${lifecycle_body}" | _lifecycle_sha256_text
  )"
  printf '%s\nPLAN_SHA256: %s\n' "${lifecycle_body}" "${lifecycle_digest}"
}

# ---------------------------------------------------------------------------
# Strict SSH execution
# ---------------------------------------------------------------------------

_lifecycle_ssh_options() {
  local lifecycle_option
  local lifecycle_known_hosts
  lifecycle_known_hosts="$(
    python3 "${_GLM53_FABRIC_TOOL}" \
      expand-known-hosts \
      --path "${_LIFECYCLE_KNOWN_HOSTS_RAW}"
  )" || {
    common_die "the pinned known-hosts path cannot be expanded"
    return 1
  }
  _LIFECYCLE_SSH_OPTIONS=()
  while IFS= read -r lifecycle_option; do
    _LIFECYCLE_SSH_OPTIONS[${#_LIFECYCLE_SSH_OPTIONS[@]}]="${lifecycle_option}"
  done < <(
    doctor_ssh_options \
      "${lifecycle_known_hosts}" \
      "${_LIFECYCLE_CONNECT_TIMEOUT}"
  )
  [ "${#_LIFECYCLE_SSH_OPTIONS[@]}" -gt 0 ] || {
    common_die "the strict SSH option set is empty"
    return 1
  }
}

# Renders a fixed action array as one POSIX-quoted remote command. Every
# element is wrapped in single quotes, so the remote shell performs no
# expansion at all. Arguments that cannot be quoted exactly are rejected.
_lifecycle_remote_command() {
  local lifecycle_argument
  local lifecycle_command=
  [ "$#" -gt 0 ] || {
    common_die "a remote action array is required"
    return 1
  }
  for lifecycle_argument in "$@"; do
    case "${lifecycle_argument}" in
      "")
        common_die "remote action arrays reject empty arguments"
        return 1
        ;;
      *"'"*)
        common_die "remote action arrays reject quoted arguments"
        return 1
        ;;
      *[![:print:]]*)
        common_die "remote action arrays reject control characters"
        return 1
        ;;
    esac
    if [ -n "${lifecycle_command}" ]; then
      lifecycle_command="${lifecycle_command} '${lifecycle_argument}'"
    else
      lifecycle_command="'${lifecycle_argument}'"
    fi
  done
  printf '%s' "${lifecycle_command}"
}

# Runs one strict SSH invocation with stdin detached and bounds it by the
# configured command timeout. The controller is stock macOS Bash 3.2 with no
# timeout(1), so a watchdog subshell polls the connection and terminates it.
# The watchdog detaches its own descriptors, so it never holds a caller's
# command substitution open and never consumes the caller's input.
#
# An optional third argument overrides the timeout in seconds. Read-only
# validation suites legitimately run far longer than a lifecycle mutation, so
# they pass their own bound rather than redefining a shared global.
_lifecycle_bounded_ssh() {
  local lifecycle_alias=$1
  local lifecycle_command=$2
  local lifecycle_status=0
  local lifecycle_pid
  local lifecycle_timeout=${3:-${_LIFECYCLE_COMMAND_TIMEOUT}}

  # SC2029: local expansion is required. The remote command is already fully
  # single-quoted by _lifecycle_remote_command, so the remote shell expands
  # nothing.
  # shellcheck disable=SC2029
  ssh \
    "${_LIFECYCLE_SSH_OPTIONS[@]}" \
    "${lifecycle_alias}" \
    "${lifecycle_command}" \
    </dev/null &
  lifecycle_pid=$!
  (
    lifecycle_waited=0
    while [ "${lifecycle_waited}" -lt "${lifecycle_timeout}" ]; do
      kill -0 "${lifecycle_pid}" 2>/dev/null || exit 0
      sleep 1
      lifecycle_waited=$((lifecycle_waited + 1))
    done
    kill -TERM "${lifecycle_pid}" 2>/dev/null || true
  ) </dev/null >/dev/null 2>&1 &
  wait "${lifecycle_pid}" || lifecycle_status=$?
  return "${lifecycle_status}"
}

_lifecycle_run_remote() {
  local lifecycle_alias=$1
  shift
  local lifecycle_command
  lifecycle_command="$(_lifecycle_remote_command "$@")" || return 1
  _lifecycle_bounded_ssh "${lifecycle_alias}" "${lifecycle_command}"
}

# ---------------------------------------------------------------------------
# Recorded run state
# ---------------------------------------------------------------------------

_lifecycle_append_event() {
  local lifecycle_phase=$1
  local lifecycle_action=$2
  local lifecycle_status=$3
  shift 3
  local lifecycle_pair
  local -a lifecycle_details
  lifecycle_details=()
  for lifecycle_pair in "$@"; do
    lifecycle_details[${#lifecycle_details[@]}]=--detail
    lifecycle_details[${#lifecycle_details[@]}]="${lifecycle_pair}"
  done
  if [ "${#lifecycle_details[@]}" -gt 0 ]; then
    python3 "${_GLM53_LIFECYCLE_STATE_TOOL}" append-event \
      --state-root "${_GLM53_STATE_ROOT}" \
      --run-id "${_LIFECYCLE_RUN_ID}" \
      --phase "${lifecycle_phase}" \
      --action "${lifecycle_action}" \
      --status "${lifecycle_status}" \
      "${lifecycle_details[@]}"
  else
    python3 "${_GLM53_LIFECYCLE_STATE_TOOL}" append-event \
      --state-root "${_GLM53_STATE_ROOT}" \
      --run-id "${_LIFECYCLE_RUN_ID}" \
      --phase "${lifecycle_phase}" \
      --action "${lifecycle_action}" \
      --status "${lifecycle_status}"
  fi
}

# Records why a run event could not be appended. The append-only event log is
# unavailable at this point by definition, so the evidence goes to a plain
# sibling file that later inspection and the operator can still read.
_lifecycle_record_event_failure() {
  local lifecycle_directory="${_GLM53_STATE_ROOT}/runs/${_LIFECYCLE_RUN_ID}"
  [ -d "${lifecycle_directory}" ] || return 0
  printf '%s phase=%s action=%s status=%s\n' \
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    "$1" \
    "$2" \
    "$3" \
    >>"${lifecycle_directory}/event-failures.log" 2>/dev/null || true
}

# Appends a run event and, when the append fails, preserves the failure as
# evidence and reports it so the caller can route through safe recovery.
_lifecycle_event() {
  _lifecycle_append_event "$@" && return 0
  _lifecycle_record_event_failure "$1" "$2" "$3"
  return 1
}

# Best-effort variant for recovery paths, which must keep unwinding even when
# the event log itself is unavailable.
_lifecycle_event_best_effort() {
  _lifecycle_event "$@" || true
}

_lifecycle_set_run_status() {
  python3 "${_GLM53_LIFECYCLE_STATE_TOOL}" set-run-status \
    --state-root "${_GLM53_STATE_ROOT}" \
    --run-id "$1" \
    --status "$2"
}

_lifecycle_load_run_record() {
  local lifecycle_run_id=$1
  local lifecycle_value
  local lifecycle_index
  local lifecycle_cursor
  local lifecycle_service_count
  local lifecycle_service_index
  local -a lifecycle_values

  lifecycle_values=()
  while IFS= read -r -d '' lifecycle_value; do
    lifecycle_values[${#lifecycle_values[@]}]="${lifecycle_value}"
  done < <(
    python3 "${_GLM53_LIFECYCLE_STATE_TOOL}" run-export \
      --state-root "${_GLM53_STATE_ROOT}" \
      --run-id "${lifecycle_run_id}"
  )
  [ "${#lifecycle_values[@]}" -ge 11 ] || {
    common_die "the recorded run state is missing or unreadable"
    return 1
  }

  _LIFECYCLE_RUN_STATUS=${lifecycle_values[0]}
  _LIFECYCLE_RUN_CONFIG_DIGEST=${lifecycle_values[1]}
  _LIFECYCLE_RUN_LOCK_DIGEST=${lifecycle_values[2]}
  _LIFECYCLE_RUN_OWNER=${lifecycle_values[3]}
  _LIFECYCLE_RUN_IMAGE=${lifecycle_values[4]}
  _LIFECYCLE_RUN_PROFILE=${lifecycle_values[5]}
  _LIFECYCLE_RUN_SERVED_NAME=${lifecycle_values[6]}
  _LIFECYCLE_RUN_MODEL_PATH=${lifecycle_values[7]}
  _LIFECYCLE_RUN_API_PORT=${lifecycle_values[8]}
  _LIFECYCLE_RUN_DIST_PORT=${lifecycle_values[9]}
  [ "${lifecycle_values[10]}" = "4" ] || {
    common_die "the recorded run state does not describe exactly four ranks"
    return 1
  }

  _LIFECYCLE_RUN_NODE_IDS=()
  _LIFECYCLE_RUN_ALIASES=()
  _LIFECYCLE_RUN_FABRIC_IPS=()
  _LIFECYCLE_RUN_CONTAINERS=()
  _LIFECYCLE_RUN_CONTAINER_IDS=()
  _LIFECYCLE_RUN_SERVICES=
  lifecycle_cursor=11
  lifecycle_index=0
  while [ "${lifecycle_index}" -lt 4 ]; do
    [ "${lifecycle_values[lifecycle_cursor]}" = "${lifecycle_index}" ] || {
      common_die "the recorded run state ranks are out of order"
      return 1
    }
    _LIFECYCLE_RUN_NODE_IDS[lifecycle_index]=${lifecycle_values[lifecycle_cursor + 1]}
    _LIFECYCLE_RUN_ALIASES[lifecycle_index]=${lifecycle_values[lifecycle_cursor + 2]}
    _LIFECYCLE_RUN_FABRIC_IPS[lifecycle_index]=${lifecycle_values[lifecycle_cursor + 3]}
    # Offsets 4 and 5 hold the recorded node root and cache root. Nothing in a
    # lifecycle mutation derives a path from them, so they are skipped rather
    # than kept as globals no caller reads.
    _LIFECYCLE_RUN_CONTAINERS[lifecycle_index]=${lifecycle_values[lifecycle_cursor + 6]}
    _LIFECYCLE_RUN_CONTAINER_IDS[lifecycle_index]=${lifecycle_values[lifecycle_cursor + 7]}
    lifecycle_service_count=${lifecycle_values[lifecycle_cursor + 8]}
    lifecycle_cursor=$((lifecycle_cursor + 9))
    lifecycle_service_index=0
    while [ "${lifecycle_service_index}" -lt "${lifecycle_service_count}" ]; do
      _LIFECYCLE_RUN_SERVICES="${_LIFECYCLE_RUN_SERVICES}$(
        _lifecycle_join_tab \
          "${lifecycle_index}" \
          "${lifecycle_values[lifecycle_cursor]}" \
          "${lifecycle_values[lifecycle_cursor + 1]}" \
          "${lifecycle_values[lifecycle_cursor + 2]}" \
          "${lifecycle_values[lifecycle_cursor + 3]}"
      )${_GLM53_LIFECYCLE_NEWLINE}"
      lifecycle_cursor=$((lifecycle_cursor + 4))
      lifecycle_service_index=$((lifecycle_service_index + 1))
    done
    lifecycle_index=$((lifecycle_index + 1))
  done
  [ "${lifecycle_cursor}" -eq "${#lifecycle_values[@]}" ] || {
    common_die "the recorded run state export is inconsistent"
    return 1
  }
}

# Emits the tab-delimited launch record lines for one staged rank.
_lifecycle_render_run_records() {
  local lifecycle_rank=$1
  local lifecycle_run_id=$2
  local lifecycle_argument

  _lifecycle_join_tab \
    rank \
    "${lifecycle_rank}" \
    "${_LIFECYCLE_NODE_IDS[$1]}" \
    "${_LIFECYCLE_NODE_ALIASES[$1]}" \
    "${_LIFECYCLE_NODE_FABRIC_IPS[$1]}" \
    "${_LIFECYCLE_NODE_ROOTS[$1]}" \
    "${_LIFECYCLE_NODE_CACHE_ROOTS[$1]}" \
    "$(_lifecycle_container_name "${lifecycle_run_id}" "${lifecycle_rank}")"
  for lifecycle_argument in "${_LIFECYCLE_RELEASE_ARGV[@]}"; do
    _lifecycle_join_tab argv "${lifecycle_rank}" "${lifecycle_argument}"
  done
  _lifecycle_join_tab \
    mount \
    "${lifecycle_rank}" \
    "${_LIFECYCLE_NODE_CACHE_ROOTS[$1]}" \
    "${_LIFECYCLE_NODE_CACHE_ROOTS[$1]}" \
    ro
  _lifecycle_join_tab \
    mount \
    "${lifecycle_rank}" \
    "$(_lifecycle_log_directory "${lifecycle_rank}" "${lifecycle_run_id}")" \
    "${_GLM53_LIFECYCLE_CONTAINER_LOG_DIR}" \
    rw
}

# ---------------------------------------------------------------------------
# Apply gates
# ---------------------------------------------------------------------------

_lifecycle_apply_gate() {
  local lifecycle_mode=$1
  local lifecycle_run_id=$2
  local lifecycle_expected=${_GLM53_PLAN_DIGEST:-}

  [ "${_GLM53_APPLY:-0}" = "1" ] || {
    common_die "${lifecycle_mode} is plan-only without an explicit --apply"
    return 1
  }
  _lifecycle_validate_run_id "${lifecycle_run_id}" || return
  [ -n "${lifecycle_expected}" ] || {
    common_die "${lifecycle_mode} --apply requires the current --plan-digest"
    return 1
  }
  _lifecycle_load_contract "${_GLM53_CONFIG_PATH}" "${_GLM53_LOCK_PATH}" || return
  _lifecycle_validate_local_artifacts || return
  [ "$(_lifecycle_plan_digest "${lifecycle_mode}" "${lifecycle_run_id}")" = \
    "${lifecycle_expected}" ] || {
    common_die "the printed plan digest is stale or does not match"
    return 1
  }

  DOCTOR_CONFIG_VALIDATED=1 DOCTOR_OUTPUT_FORMAT=json \
    doctor_run "${_GLM53_CONFIG_PATH}" "${_GLM53_LOCK_PATH}" >/dev/null || {
    common_die "the fresh read-only doctor preflight failed"
    return 1
  }

  # Pre-mutation revalidation: nothing the plan pinned may have changed while
  # the read-only preflight was running.
  config_validate "${_GLM53_CONFIG_PATH}" "${_GLM53_LOCK_PATH}" || return
  _lifecycle_load_contract "${_GLM53_CONFIG_PATH}" "${_GLM53_LOCK_PATH}" || return
  _lifecycle_validate_local_artifacts || return
  [ "$(_lifecycle_plan_digest "${lifecycle_mode}" "${lifecycle_run_id}")" = \
    "${lifecycle_expected}" ] || {
    common_die "lifecycle identities changed after the doctor preflight"
    return 1
  }
  _lifecycle_ssh_options || return
  _LIFECYCLE_RUN_ID=${lifecycle_run_id}
}

# ---------------------------------------------------------------------------
# Phase one
# ---------------------------------------------------------------------------

# Reads `ss -H -ltn` output, whose fourth column is the local socket address.
# Only the exact port after the final colon counts, so IPv4, IPv6 and wildcard
# sockets all compare exactly and neighbouring ports never match.
_lifecycle_ports_free() {
  printf '%s\n' "$1" | awk \
    -v lifecycle_api="${_LIFECYCLE_API_PORT}" \
    -v lifecycle_dist="${_LIFECYCLE_DIST_PORT}" '
    NF >= 4 {
      fields = split($4, parts, ":")
      port = parts[fields]
      if (port == lifecycle_api || port == lifecycle_dist) {
        occupied = 1
      }
    }
    END { exit(occupied ? 1 : 0) }
  '
}

_lifecycle_probe_ports() {
  local lifecycle_rank=$1
  local lifecycle_observed
  lifecycle_observed="$(
    _lifecycle_run_remote "${_LIFECYCLE_NODE_ALIASES[lifecycle_rank]}" ss -H -ltn
  )" || {
    common_die "the listening socket probe failed during phase one"
    return 1
  }
  _lifecycle_ports_free "${lifecycle_observed}"
}

_lifecycle_rank_has_owned_running() {
  local lifecycle_rank=$1
  local lifecycle_kind
  local lifecycle_record_rank
  local lifecycle_id
  local lifecycle_name
  local lifecycle_image
  local lifecycle_state

  while IFS="${_GLM53_LIFECYCLE_TAB}" read -r lifecycle_kind \
    lifecycle_record_rank lifecycle_id lifecycle_name lifecycle_image \
    lifecycle_state; do
    [ "${lifecycle_kind}" = "service" ] || continue
    [ "${lifecycle_record_rank}" = "${lifecycle_rank}" ] || continue
    [ "${lifecycle_state}" = "running" ] || continue
    return 0
  done <<EOF
${_LIFECYCLE_PRELAUNCH_RECORDS}
EOF
  return 1
}

_lifecycle_record_prelaunch() {
  local lifecycle_rank=$1
  local lifecycle_alias=${_LIFECYCLE_NODE_ALIASES[$1]}
  local lifecycle_observed
  local lifecycle_id
  local lifecycle_name
  local lifecycle_image
  local lifecycle_state

  lifecycle_observed="$(
    _lifecycle_run_remote \
      "${lifecycle_alias}" \
      docker ps --no-trunc --format "${_GLM53_LIFECYCLE_PS_FORMAT}" \
      --filter "${_GLM53_LIFECYCLE_OWNER_FILTER}"
  )" || {
    common_die "the pre-launch service observation failed on a configured node"
    return 1
  }
  while IFS='|' read -r lifecycle_id lifecycle_name lifecycle_image \
    lifecycle_state; do
    [ -n "${lifecycle_name}" ] || continue
    _LIFECYCLE_PRELAUNCH_RECORDS="${_LIFECYCLE_PRELAUNCH_RECORDS}$(
      _lifecycle_join_tab \
        service \
        "${lifecycle_rank}" \
        "${lifecycle_id}" \
        "${lifecycle_name}" \
        "${lifecycle_image}" \
        "${lifecycle_state}"
    )${_GLM53_LIFECYCLE_NEWLINE}"
  done <<EOF
${lifecycle_observed}
EOF
}

# Reads back the immutable identity of one service as
# "id|owner|image|running". Both the quiesce and the restore path compare the
# result against the recorded tuple, so neither can act on a container that
# merely reuses a recorded name.
_lifecycle_observe_service() {
  _lifecycle_run_remote \
    "$1" \
    docker inspect --format "${_GLM53_LIFECYCLE_SERVICE_FORMAT}" \
    "$2" 2>/dev/null
}

_lifecycle_quiesce_prelaunch() {
  local lifecycle_rank=$1
  local lifecycle_alias=${_LIFECYCLE_NODE_ALIASES[$1]}
  local lifecycle_kind
  local lifecycle_record_rank
  local lifecycle_id
  local lifecycle_name
  local lifecycle_image
  local lifecycle_state
  local lifecycle_observed

  while IFS="${_GLM53_LIFECYCLE_TAB}" read -r lifecycle_kind \
    lifecycle_record_rank lifecycle_id lifecycle_name lifecycle_image \
    lifecycle_state; do
    [ "${lifecycle_kind}" = "service" ] || continue
    [ "${lifecycle_record_rank}" = "${lifecycle_rank}" ] || continue
    [ "${lifecycle_state}" = "running" ] || continue
    lifecycle_observed="$(
      _lifecycle_observe_service "${lifecycle_alias}" "${lifecycle_name}"
    )" || {
      common_die "a recorded pre-launch service disappeared before quiesce"
      return 1
    }
    # Exact ID, owner, image and running state, so a service recreated between
    # the pre-launch observation and this sweep is never stopped.
    [ "${lifecycle_observed}" = \
      "${lifecycle_id}|${_GLM53_LIFECYCLE_OWNER}|${lifecycle_image}|true" ] || {
      common_die "a recorded pre-launch service no longer has the recorded identity"
      return 1
    }
    _lifecycle_run_remote \
      "${lifecycle_alias}" \
      docker stop --time "${_GLM53_LIFECYCLE_STOP_TIMEOUT_SECONDS}" \
      "${lifecycle_id}" >/dev/null || {
      common_die "a recorded pre-launch service could not be quiesced"
      return 1
    }
  done <<EOF
${_LIFECYCLE_PRELAUNCH_RECORDS}
EOF
}

# Sub-phase one: strictly read-only rank verification. Nothing here mutates a
# node, so any rejection leaves every node exactly as it was found.
_lifecycle_verify_rank() {
  local lifecycle_rank=$1
  local lifecycle_run_id=$2
  local lifecycle_alias=${_LIFECYCLE_NODE_ALIASES[$1]}
  local lifecycle_container
  local lifecycle_observed
  local lifecycle_name

  lifecycle_container="$(
    _lifecycle_container_name "${lifecycle_run_id}" "${lifecycle_rank}"
  )"

  lifecycle_observed="$(
    _lifecycle_run_remote \
      "${lifecycle_alias}" \
      cat "${_GLM53_LIFECYCLE_MACHINE_ID}"
  )" || {
    common_die "the node identity probe failed during phase one"
    return 1
  }
  lifecycle_observed="$(
    printf '%s' "${lifecycle_observed}" |
      tr -d ' \t\n\r' |
      _lifecycle_sha256_text
  )"
  [ "${lifecycle_observed}" = "${_LIFECYCLE_NODE_MACHINE_DIGESTS[$1]}" ] || {
    common_die "the node identity does not match the configured rank mapping"
    return 1
  }

  lifecycle_observed="$(
    _lifecycle_run_remote \
      "${lifecycle_alias}" \
      docker image inspect --format "${_GLM53_LIFECYCLE_IMAGE_FORMAT}" \
      "$(_lifecycle_image_reference "${lifecycle_run_id}")"
  )" || {
    common_die "the run image is missing on a configured node"
    return 1
  }
  [ "${lifecycle_observed}" = "${_LIFECYCLE_IMAGE_OWNER}" ] || {
    common_die "the run image does not carry the expected owner label"
    return 1
  }

  _lifecycle_run_remote \
    "${lifecycle_alias}" \
    test -d "$(
      _lifecycle_snapshot_path \
        "${lifecycle_rank}" \
        "${_LIFECYCLE_TARGET_REPO}" \
        "${_LIFECYCLE_TARGET_REVISION}"
    )" >/dev/null || {
    common_die "the pinned target model snapshot is missing on a configured node"
    return 1
  }
  _lifecycle_run_remote \
    "${lifecycle_alias}" \
    test -d "$(
      _lifecycle_snapshot_path \
        "${lifecycle_rank}" \
        "${_LIFECYCLE_DRAFT_REPO}" \
        "${_LIFECYCLE_DRAFT_REVISION}"
    )" >/dev/null || {
    common_die "the pinned draft model snapshot is missing on a configured node"
    return 1
  }

  lifecycle_observed="$(
    _lifecycle_run_remote \
      "${lifecycle_alias}" \
      docker ps -a --format "${_GLM53_LIFECYCLE_NAMES_FORMAT}" \
      --filter "name=${lifecycle_container}"
  )" || {
    common_die "the container name reservation probe failed during phase one"
    return 1
  }
  while IFS= read -r lifecycle_name; do
    [ "${lifecycle_name}" = "${lifecycle_container}" ] || continue
    common_die "the run container name is already in use on a configured node"
    return 1
  done <<EOF
${lifecycle_observed}
EOF

  # A port already in use is only tolerable when a recorded owned pre-launch
  # service on this very rank can explain it, because the mutating sub-phase
  # is about to stop exactly those services and nothing else.
  if ! _lifecycle_probe_ports "${lifecycle_rank}"; then
    if ! _lifecycle_rank_has_owned_running "${lifecycle_rank}"; then
      common_die "the API or distributed port is occupied by a foreign listener"
      return 1
    fi
  fi
}

# Sub-phase two: the only mutating sweep of phase one.
_lifecycle_prepare_rank() {
  local lifecycle_rank=$1
  local lifecycle_run_id=$2

  _lifecycle_run_remote \
    "${_LIFECYCLE_NODE_ALIASES[lifecycle_rank]}" \
    mkdir -p "$(
      _lifecycle_log_directory "${lifecycle_rank}" "${lifecycle_run_id}"
    )" >/dev/null || {
    common_die "the run log directory could not be prepared"
    return 1
  }
  _lifecycle_quiesce_prelaunch "${lifecycle_rank}" || return 1
}

# Sub-phase three: read-only confirmation that quiescing actually freed both
# pinned ports before any rank is released.
_lifecycle_confirm_rank_ports() {
  _lifecycle_probe_ports "$1" || {
    common_die "the API or distributed port is still occupied"
    return 1
  }
}

# ---------------------------------------------------------------------------
# Phase two
# ---------------------------------------------------------------------------

_lifecycle_release_ranks() {
  local lifecycle_run_id=$1
  local lifecycle_index
  local lifecycle_command
  local lifecycle_failures=0
  local -a lifecycle_pids
  local -a lifecycle_statuses

  lifecycle_pids=()
  lifecycle_statuses=()
  lifecycle_index=0
  while [ "${lifecycle_index}" -lt 4 ]; do
    _lifecycle_build_release_argv "${lifecycle_index}" "${lifecycle_run_id}"
    lifecycle_command="$(
      _lifecycle_remote_command "${_LIFECYCLE_RELEASE_ARGV[@]}"
    )" || return 1
    # Concurrent rank releases go through the same bounded, stdin-detached SSH
    # helper as every other lifecycle call, so a hung rank cannot stall the
    # collective wait indefinitely. Docker's stdout ID is isolated from
    # diagnostics so an SSH warning cannot corrupt the identity record.
    _lifecycle_bounded_ssh \
      "${_LIFECYCLE_NODE_ALIASES[lifecycle_index]}" \
      "${lifecycle_command}" \
      >"${_GLM53_STATE_ROOT}/runs/${lifecycle_run_id}/rank-${lifecycle_index}.release.id" \
      2>"${_GLM53_STATE_ROOT}/runs/${lifecycle_run_id}/rank-${lifecycle_index}.release.log" &
    lifecycle_pids[lifecycle_index]=$!
    lifecycle_index=$((lifecycle_index + 1))
  done

  lifecycle_index=0
  while [ "${lifecycle_index}" -lt 4 ]; do
    if wait "${lifecycle_pids[lifecycle_index]}"; then
      lifecycle_statuses[lifecycle_index]=0
    else
      lifecycle_statuses[lifecycle_index]=$?
      lifecycle_failures=$((lifecycle_failures + 1))
    fi
    lifecycle_index=$((lifecycle_index + 1))
  done

  lifecycle_index=0
  while [ "${lifecycle_index}" -lt 4 ]; do
    # A transport failure can occur after Docker created the rank and printed
    # its ID. Bind any valid stdout receipt even for a failed SSH status so the
    # abort path can stop that exact container; never rediscover an ID by name.
    if [ -s "${_GLM53_STATE_ROOT}/runs/${lifecycle_run_id}/rank-${lifecycle_index}.release.id" ]; then
      _lifecycle_record_released_container_id \
        "${lifecycle_run_id}" \
        "${lifecycle_index}" || lifecycle_failures=$((lifecycle_failures + 1))
    fi
    lifecycle_index=$((lifecycle_index + 1))
  done

  # Reload after every successful release has been bound. An abort following a
  # partial startup therefore addresses only Docker IDs this record observed.
  _lifecycle_load_run_record "${lifecycle_run_id}" || return 1

  lifecycle_index=0
  while [ "${lifecycle_index}" -lt 4 ]; do
    if [ "${lifecycle_statuses[lifecycle_index]}" -eq 0 ]; then
      _lifecycle_event \
        phase-two \
        release-rank \
        succeeded \
        "rank=${lifecycle_index}" \
        "node_id=${_LIFECYCLE_NODE_IDS[lifecycle_index]}" ||
        lifecycle_failures=$((lifecycle_failures + 1))
    else
      _lifecycle_event \
        phase-two \
        release-rank \
        failed \
        "rank=${lifecycle_index}" \
        "node_id=${_LIFECYCLE_NODE_IDS[lifecycle_index]}" \
        "exit_status=${lifecycle_statuses[lifecycle_index]}" ||
        lifecycle_failures=$((lifecycle_failures + 1))
    fi
    lifecycle_index=$((lifecycle_index + 1))
  done

  [ "${lifecycle_failures}" -eq 0 ] || return 1
}

# Docker prints the immutable ID of a detached container on stdout. Preserve
# that exact value in the run record before a later stop or abort can mutate a
# rank. The dedicated stdout receipt avoids accepting diagnostics as identity;
# config_state.py rejects anything other than one full Docker ID.
_lifecycle_record_released_container_id() {
  local lifecycle_run_id=$1
  local lifecycle_rank=$2
  local lifecycle_container_id

  lifecycle_container_id="$(
    cat "${_GLM53_STATE_ROOT}/runs/${lifecycle_run_id}/rank-${lifecycle_rank}.release.id"
  )" || return 1
  python3 "${_GLM53_LIFECYCLE_STATE_TOOL}" record-rank-container-id \
    --state-root "${_GLM53_STATE_ROOT}" \
    --run-id "${lifecycle_run_id}" \
    --rank "${lifecycle_rank}" \
    --container-id "${lifecycle_container_id}"
}

# Every post-release check reads the recorded run, never the current
# configuration, so a configuration edit during a launch cannot redirect a
# readiness or serving probe away from the run that was actually recorded.
_lifecycle_wait_collective() {
  local lifecycle_run_id=$1
  local lifecycle_attempt=1
  local lifecycle_index
  local lifecycle_ready
  local lifecycle_observed
  local lifecycle_expected

  while [ "${lifecycle_attempt}" -le "${_LIFECYCLE_READY_ATTEMPTS}" ]; do
    lifecycle_ready=1
    lifecycle_index=0
    while [ "${lifecycle_index}" -lt 4 ]; do
      lifecycle_expected="${_LIFECYCLE_RUN_CONTAINER_IDS[lifecycle_index]}|true|${lifecycle_run_id}|${lifecycle_index}|${_LIFECYCLE_RUN_OWNER}"
      if lifecycle_observed="$(
        _lifecycle_run_remote \
          "${_LIFECYCLE_RUN_ALIASES[lifecycle_index]}" \
          docker inspect --format "${_GLM53_LIFECYCLE_RUN_FORMAT}" \
          "${_LIFECYCLE_RUN_CONTAINERS[lifecycle_index]}" 2>/dev/null
      )"; then
        if [ "${lifecycle_observed}" != "${lifecycle_expected}" ]; then
          lifecycle_ready=0
        fi
      else
        lifecycle_ready=0
      fi
      lifecycle_index=$((lifecycle_index + 1))
    done
    if [ "${lifecycle_ready}" -eq 1 ]; then
      return 0
    fi
    sleep "${_LIFECYCLE_READY_INTERVAL}"
    lifecycle_attempt=$((lifecycle_attempt + 1))
  done
  common_die "collective TP4 readiness did not complete within the bounded wait"
  return 1
}

_lifecycle_probe_endpoint() {
  _lifecycle_run_remote \
    "${_LIFECYCLE_RUN_ALIASES[0]}" \
    curl --fail --silent --show-error \
    --max-time "${_GLM53_LIFECYCLE_HEALTH_TIMEOUT_SECONDS}" \
    "$(
      _lifecycle_endpoint_url \
        "${_LIFECYCLE_RUN_FABRIC_IPS[0]}" \
        "${_LIFECYCLE_RUN_API_PORT}" \
        "$1"
    )" 2>/dev/null
}

# Proves the recorded endpoint serves this exact run: the pinned model
# snapshot, a generation server, the recorded served model name, and a real
# single-token generation. A liveness probe alone cannot establish any of it.
_lifecycle_verify_serving_identity() {
  local lifecycle_payload

  lifecycle_payload="$(
    _lifecycle_probe_endpoint "${_GLM53_LIFECYCLE_MODEL_INFO_PATH}"
  )" || return 1
  printf '%s' "${lifecycle_payload}" |
    python3 "${_GLM53_LIFECYCLE_STATE_TOOL}" check-model-info \
      --expected-model-path "${_LIFECYCLE_RUN_MODEL_PATH}" \
      >/dev/null 2>&1 || return 1
  lifecycle_payload="$(
    _lifecycle_probe_endpoint "${_GLM53_LIFECYCLE_SERVED_MODELS_PATH}"
  )" || return 1
  printf '%s' "${lifecycle_payload}" |
    python3 "${_GLM53_LIFECYCLE_STATE_TOOL}" check-served-models \
      --expected-served-name "${_LIFECYCLE_RUN_SERVED_NAME}" \
      >/dev/null 2>&1 || return 1
  _lifecycle_probe_endpoint "${_GLM53_LIFECYCLE_GENERATE_HEALTH_PATH}" \
    >/dev/null 2>&1
}

_lifecycle_wait_api_health() {
  local lifecycle_attempt=1
  while [ "${lifecycle_attempt}" -le "${_LIFECYCLE_READY_ATTEMPTS}" ]; do
    if _lifecycle_verify_serving_identity; then
      return 0
    fi
    sleep "${_LIFECYCLE_READY_INTERVAL}"
    lifecycle_attempt=$((lifecycle_attempt + 1))
  done
  common_die "the direct API did not serve this run within the bounded wait"
  return 1
}

# ---------------------------------------------------------------------------
# Owned stop and recorded rollback
# ---------------------------------------------------------------------------

# Reads one container's identity and separates the three outcomes a caller must
# never conflate. A failed inspect alone cannot distinguish "this name is
# unused" from "this node did not answer", so absence is only ever concluded
# from a second probe that the daemon itself answered.
#
# Prints the observed tuple and returns 0 when the container exists, returns 2
# when the daemon proved the name is unused, and returns 1 when the node or the
# daemon could not be consulted at all.
_lifecycle_probe_container() {
  local lifecycle_alias=$1
  local lifecycle_reference=$2
  local lifecycle_format=$3
  local lifecycle_observed
  local lifecycle_listed
  local lifecycle_filter
  local lifecycle_list_format

  if lifecycle_observed="$(
    _lifecycle_run_remote \
      "${lifecycle_alias}" \
      docker inspect --format "${lifecycle_format}" \
      "${lifecycle_reference}" 2>/dev/null
  )"; then
    printf '%s\n' "${lifecycle_observed}"
    return 0
  fi
  lifecycle_filter="name=${lifecycle_reference}"
  lifecycle_list_format=${_GLM53_LIFECYCLE_NAMES_FORMAT}
  if _lifecycle_is_container_id "${lifecycle_reference}"; then
    lifecycle_filter="id=${lifecycle_reference}"
    lifecycle_list_format=${_GLM53_LIFECYCLE_IDS_FORMAT}
  fi
  lifecycle_listed="$(
    _lifecycle_run_remote \
      "${lifecycle_alias}" \
      docker ps -a --no-trunc \
      --format "${lifecycle_list_format}" \
      --filter "${lifecycle_filter}" 2>/dev/null
  )" || return 1
  # Docker filters may return prefix matches, so the exact comparison
  # happens here. A listed name after a failed inspect is contradictory
  # evidence and is reported as unconsultable rather than absent.
  case "${_GLM53_LIFECYCLE_NEWLINE}${lifecycle_listed}${_GLM53_LIFECYCLE_NEWLINE}" in
    *"${_GLM53_LIFECYCLE_NEWLINE}${lifecycle_reference}${_GLM53_LIFECYCLE_NEWLINE}"*)
      return 1
      ;;
  esac
  return 2
}

_lifecycle_is_container_id() {
  [ "${#1}" -eq 64 ] || return 1
  case "$1" in
    *[!0-9a-f]*) return 1 ;;
  esac
  return 0
}

# Classifies all four recorded ranks strictly read-only. It never mutates a
# node and never appends an event, so callers can decide to fail closed while
# the cluster is still exactly as it was found.
_lifecycle_classify_run_owned() {
  local lifecycle_run_id=$1
  local lifecycle_index
  local lifecycle_observed
  local lifecycle_probe
  local lifecycle_name_probe
  local lifecycle_running
  local lifecycle_stopped

  _LIFECYCLE_OWNED_FLAGS=()
  _LIFECYCLE_OWNED_COUNT=0
  _LIFECYCLE_DRIFT_COUNT=0
  _LIFECYCLE_DRIFT_RANKS=
  _LIFECYCLE_UNKNOWN_COUNT=0
  _LIFECYCLE_UNKNOWN_RANKS=
  lifecycle_index=0
  while [ "${lifecycle_index}" -lt 4 ]; do
    _LIFECYCLE_OWNED_FLAGS[lifecycle_index]=0
    lifecycle_running="${_LIFECYCLE_RUN_CONTAINER_IDS[lifecycle_index]}|true|${lifecycle_run_id}|${lifecycle_index}|${_LIFECYCLE_RUN_OWNER}"
    lifecycle_stopped="${_LIFECYCLE_RUN_CONTAINER_IDS[lifecycle_index]}|false|${lifecycle_run_id}|${lifecycle_index}|${_LIFECYCLE_RUN_OWNER}"
    # The probe reports three outcomes through its exit status, so the
    # assignment must stay inside a condition. A bare command substitution
    # would trip errexit under the dispatcher's `set -eu` and terminate the
    # caller before it could classify, abort, or fail closed.
    if lifecycle_observed="$(
      _lifecycle_probe_container \
        "${_LIFECYCLE_RUN_ALIASES[lifecycle_index]}" \
        "${_LIFECYCLE_RUN_CONTAINERS[lifecycle_index]}" \
        "${_GLM53_LIFECYCLE_RUN_FORMAT}"
    )"; then
      lifecycle_probe=0
    else
      lifecycle_probe=$?
    fi
    case "${lifecycle_probe}" in
      0)
        case "${lifecycle_observed}" in
          "${lifecycle_running}"|"${lifecycle_stopped}")
            _LIFECYCLE_OWNED_FLAGS[lifecycle_index]=1
            _LIFECYCLE_OWNED_COUNT=$((_LIFECYCLE_OWNED_COUNT + 1))
            ;;
          *)
            _LIFECYCLE_DRIFT_COUNT=$((_LIFECYCLE_DRIFT_COUNT + 1))
            _LIFECYCLE_DRIFT_RANKS="${_LIFECYCLE_DRIFT_RANKS}${lifecycle_index}"
            ;;
        esac
        ;;
      2)
        # The recorded name is absent. If its immutable ID still exists under
        # another name, preserve the recorded-name contract and report drift;
        # never stop a renamed container during an operator action.
        if _lifecycle_probe_container \
          "${_LIFECYCLE_RUN_ALIASES[lifecycle_index]}" \
          "${_LIFECYCLE_RUN_CONTAINER_IDS[lifecycle_index]}" \
          "${_GLM53_LIFECYCLE_RUN_FORMAT}" >/dev/null; then
          lifecycle_name_probe=0
        else
          lifecycle_name_probe=$?
        fi
        if [ "${lifecycle_name_probe}" -eq 0 ]; then
          _LIFECYCLE_DRIFT_COUNT=$((_LIFECYCLE_DRIFT_COUNT + 1))
          _LIFECYCLE_DRIFT_RANKS="${_LIFECYCLE_DRIFT_RANKS}${lifecycle_index}"
        elif [ "${lifecycle_name_probe}" -ne 2 ]; then
          _LIFECYCLE_UNKNOWN_COUNT=$((_LIFECYCLE_UNKNOWN_COUNT + 1))
          _LIFECYCLE_UNKNOWN_RANKS="${_LIFECYCLE_UNKNOWN_RANKS}${lifecycle_index}"
        fi
        ;;
      *)
        _LIFECYCLE_UNKNOWN_COUNT=$((_LIFECYCLE_UNKNOWN_COUNT + 1))
        _LIFECYCLE_UNKNOWN_RANKS="${_LIFECYCLE_UNKNOWN_RANKS}${lifecycle_index}"
        ;;
    esac
    lifecycle_index=$((lifecycle_index + 1))
  done
  # Classification itself never fails; the verdict is carried by the owned,
  # drift and unknown counters so callers under errexit can inspect it.
  return 0
}

# Classifies every recorded pre-launch service strictly read-only, mirroring
# the rank classifier. Each recorded service is resolved to exactly one action:
# "skip" when it is already running with the recorded identity, "start" when it
# is stopped with the recorded identity, and "blocked" when its identity
# drifted, it is gone, or its node could not be consulted.
_lifecycle_classify_prelaunch() {
  local lifecycle_rank
  local lifecycle_id
  local lifecycle_name
  local lifecycle_image
  local lifecycle_state
  local lifecycle_observed
  local lifecycle_probe
  local lifecycle_action
  local lifecycle_slot

  _LIFECYCLE_SERVICE_COUNT=0
  _LIFECYCLE_SERVICE_RANKS=()
  _LIFECYCLE_SERVICE_IDS=()
  _LIFECYCLE_SERVICE_NAMES=()
  _LIFECYCLE_SERVICE_ACTIONS=()
  _LIFECYCLE_SERVICE_BLOCKED_COUNT=0
  _LIFECYCLE_SERVICE_BLOCKED_NAMES=

  while IFS="${_GLM53_LIFECYCLE_TAB}" read -r lifecycle_rank lifecycle_id \
    lifecycle_name lifecycle_image lifecycle_state; do
    [ -n "${lifecycle_name}" ] || continue
    [ "${lifecycle_state}" = "running" ] || continue
    # Same errexit-safe three-way capture as the rank classifier: a proven
    # absent service and an unconsultable node must both reach the "blocked"
    # decision below instead of terminating the caller.
    if lifecycle_observed="$(
      _lifecycle_probe_container \
        "${_LIFECYCLE_RUN_ALIASES[lifecycle_rank]}" \
        "${lifecycle_name}" \
        "${_GLM53_LIFECYCLE_SERVICE_FORMAT}"
    )"; then
      lifecycle_probe=0
    else
      lifecycle_probe=$?
    fi
    lifecycle_action=blocked
    if [ "${lifecycle_probe}" -eq 0 ]; then
      # The exact container ID, owner label and image must all still match, so
      # a later container that merely reuses the recorded name is never
      # started.
      case "${lifecycle_observed}" in
        "${lifecycle_id}|${_LIFECYCLE_RUN_OWNER}|${lifecycle_image}|true")
          lifecycle_action=skip
          ;;
        "${lifecycle_id}|${_LIFECYCLE_RUN_OWNER}|${lifecycle_image}|false")
          lifecycle_action=start
          ;;
      esac
    fi
    lifecycle_slot=${_LIFECYCLE_SERVICE_COUNT}
    _LIFECYCLE_SERVICE_RANKS[lifecycle_slot]=${lifecycle_rank}
    _LIFECYCLE_SERVICE_IDS[lifecycle_slot]=${lifecycle_id}
    _LIFECYCLE_SERVICE_NAMES[lifecycle_slot]=${lifecycle_name}
    _LIFECYCLE_SERVICE_ACTIONS[lifecycle_slot]=${lifecycle_action}
    _LIFECYCLE_SERVICE_COUNT=$((_LIFECYCLE_SERVICE_COUNT + 1))
    if [ "${lifecycle_action}" = "blocked" ]; then
      _LIFECYCLE_SERVICE_BLOCKED_COUNT=$((_LIFECYCLE_SERVICE_BLOCKED_COUNT + 1))
      _LIFECYCLE_SERVICE_BLOCKED_NAMES="${_LIFECYCLE_SERVICE_BLOCKED_NAMES}${lifecycle_name} "
    fi
  done <<EOF
${_LIFECYCLE_RUN_SERVICES}
EOF
  # As with the rank classifier, the blocked counter carries the verdict so an
  # abort running under errexit can keep converging.
  return 0
}

# Stops only the ranks a preceding classification proved this run owns.
_lifecycle_stop_classified() {
  local lifecycle_index=0
  local lifecycle_failed=0

  while [ "${lifecycle_index}" -lt 4 ]; do
    if [ "${_LIFECYCLE_OWNED_FLAGS[lifecycle_index]}" -eq 1 ]; then
      _lifecycle_run_remote \
        "${_LIFECYCLE_RUN_ALIASES[lifecycle_index]}" \
        docker stop --time "${_GLM53_LIFECYCLE_STOP_TIMEOUT_SECONDS}" \
        "${_LIFECYCLE_RUN_CONTAINER_IDS[lifecycle_index]}" >/dev/null || {
        common_die "a run-owned container could not be stopped"
        return 1
      }
      _lifecycle_event \
        ownership \
        stop-run-owned \
        succeeded \
        "rank=${lifecycle_index}" \
        "container=${_LIFECYCLE_RUN_CONTAINER_IDS[lifecycle_index]}" ||
        lifecycle_failed=1
    fi
    lifecycle_index=$((lifecycle_index + 1))
  done
  [ "${lifecycle_failed}" -eq 0 ]
}

# Classifies, then refuses every mutation when a recorded run name is held by
# a container this run does not own, or when nothing owned is present.
_lifecycle_require_owned_run() {
  _lifecycle_classify_run_owned "$1" || return 1
  # An unreachable node is never treated as an absent container, because a
  # rank that cannot be consulted may still be running.
  [ "${_LIFECYCLE_UNKNOWN_COUNT}" -eq 0 ] || {
    common_die "a configured node could not be consulted to classify this run"
    return 1
  }
  [ "${_LIFECYCLE_DRIFT_COUNT}" -eq 0 ] || {
    common_die "a container with a recorded run name is not owned by this run"
    return 1
  }
  [ "${_LIFECYCLE_OWNED_COUNT}" -gt 0 ] || {
    common_die "no container owned by this run is present on the configured nodes"
    return 1
  }
}

# Rejects a recorded run whose validated contract no longer matches the current
# one, before any stop, restore, or status transition takes place.
_lifecycle_require_recorded_contract() {
  [ "${_LIFECYCLE_RUN_CONFIG_DIGEST}" = "${_LIFECYCLE_CONFIG_DIGEST}" ] || {
    common_die "the recorded run configuration digest differs from the current one"
    return 1
  }
  [ "${_LIFECYCLE_RUN_LOCK_DIGEST}" = "${_LIFECYCLE_LOCK_DIGEST}" ] || {
    common_die "the recorded run lock digest differs from the current one"
    return 1
  }
}

# Starts exactly the services a preceding classification resolved to "start".
# It deliberately keeps going after a failure so a service ordered behind a
# failing one is still attempted, then reports whether every attempt succeeded.
_lifecycle_restore_classified() {
  local lifecycle_index=0
  local lifecycle_failed=0
  local lifecycle_rank
  local lifecycle_id
  local lifecycle_name

  while [ "${lifecycle_index}" -lt "${_LIFECYCLE_SERVICE_COUNT}" ]; do
    if [ "${_LIFECYCLE_SERVICE_ACTIONS[lifecycle_index]}" = "start" ]; then
      lifecycle_rank=${_LIFECYCLE_SERVICE_RANKS[lifecycle_index]}
      lifecycle_id=${_LIFECYCLE_SERVICE_IDS[lifecycle_index]}
      lifecycle_name=${_LIFECYCLE_SERVICE_NAMES[lifecycle_index]}
      if _lifecycle_run_remote \
        "${_LIFECYCLE_RUN_ALIASES[lifecycle_rank]}" \
        docker start "${lifecycle_id}" >/dev/null; then
        _lifecycle_event \
          rollback \
          restore-service \
          succeeded \
          "rank=${lifecycle_rank}" \
          "container=${lifecycle_id}" ||
          lifecycle_failed=1
      else
        lifecycle_failed=1
        _lifecycle_event_best_effort \
          rollback \
          restore-service \
          failed \
          "rank=${lifecycle_rank}" \
          "container=${lifecycle_id}"
      fi
    fi
    lifecycle_index=$((lifecycle_index + 1))
  done
  [ "${lifecycle_failed}" -eq 0 ]
}

# Unwinds a launch that has already mutated at least one node. Unlike an
# operator rollback, this path cannot fail closed: the cluster is already
# changed, so refusing to act would strand it. It therefore converges instead,
# acting on every resource it can prove and reporting the rest. Containers this
# run provably owns are stopped, every safely proven recorded service is
# restored even when another one is blocked, and nothing whose identity drifted
# is ever touched.
_lifecycle_abort_launch() {
  local lifecycle_run_id=$1
  local lifecycle_reason=$2

  _lifecycle_event_best_effort \
    launch \
    abort-launch \
    failed \
    "reason=${lifecycle_reason}"
  if _lifecycle_load_run_record "${lifecycle_run_id}"; then
    _lifecycle_classify_run_owned "${lifecycle_run_id}"
    if [ "${_LIFECYCLE_UNKNOWN_COUNT}" -ne 0 ]; then
      _lifecycle_event_best_effort \
        ownership \
        classify-failed \
        failed \
        "ranks=${_LIFECYCLE_UNKNOWN_RANKS}"
    fi
    if [ "${_LIFECYCLE_DRIFT_COUNT}" -ne 0 ]; then
      _lifecycle_event_best_effort \
        ownership \
        detect-drift \
        failed \
        "ranks=${_LIFECYCLE_DRIFT_RANKS}"
    fi
    _lifecycle_stop_classified || true
    _lifecycle_classify_prelaunch
    if [ "${_LIFECYCLE_SERVICE_BLOCKED_COUNT}" -ne 0 ]; then
      _lifecycle_event_best_effort \
        rollback \
        detect-service-drift \
        failed \
        "containers=${_LIFECYCLE_SERVICE_BLOCKED_NAMES}"
    fi
    _lifecycle_restore_classified || true
  fi
  _lifecycle_set_run_status "${lifecycle_run_id}" failed || true
  common_die "${lifecycle_reason}"
  return 1
}

# ---------------------------------------------------------------------------
# Public lifecycle operations
# ---------------------------------------------------------------------------

lifecycle_launch() {
  local lifecycle_run_id=$1
  local lifecycle_index
  local lifecycle_records=

  _lifecycle_apply_gate launch "${lifecycle_run_id}" || return

  _LIFECYCLE_PRELAUNCH_RECORDS=
  lifecycle_index=0
  while [ "${lifecycle_index}" -lt 4 ]; do
    _lifecycle_record_prelaunch "${lifecycle_index}" || return 1
    lifecycle_index=$((lifecycle_index + 1))
  done

  lifecycle_index=0
  while [ "${lifecycle_index}" -lt 4 ]; do
    _lifecycle_build_release_argv "${lifecycle_index}" "${lifecycle_run_id}"
    lifecycle_records="${lifecycle_records}$(
      _lifecycle_render_run_records "${lifecycle_index}" "${lifecycle_run_id}"
    )${_GLM53_LIFECYCLE_NEWLINE}"
    lifecycle_index=$((lifecycle_index + 1))
  done

  printf '%s%s' "${lifecycle_records}" "${_LIFECYCLE_PRELAUNCH_RECORDS}" |
    python3 "${_GLM53_LIFECYCLE_STATE_TOOL}" record-run \
      --state-root "${_GLM53_STATE_ROOT}" \
      --run-id "${lifecycle_run_id}" \
      --config-digest "${_LIFECYCLE_CONFIG_DIGEST}" \
      --lock-digest "${_LIFECYCLE_LOCK_DIGEST}" \
      --status launching \
      --owner "${_GLM53_LIFECYCLE_OWNER}" \
      --profile-name "${_LIFECYCLE_PROFILE_NAME}" \
      --image-reference "$(_lifecycle_image_reference "${lifecycle_run_id}")" \
      --api-port "${_LIFECYCLE_API_PORT}" \
      --dist-port "${_LIFECYCLE_DIST_PORT}" \
      --served-model-name "${_LIFECYCLE_SERVED_NAME}" \
      --model-path "$(
        _lifecycle_snapshot_path \
          0 \
          "${_LIFECYCLE_TARGET_REPO}" \
          "${_LIFECYCLE_TARGET_REVISION}"
      )" || {
    common_die "the before-state run record could not be written"
    return 1
  }
  # Every later probe reads the just-recorded run rather than the live
  # configuration, so a concurrent configuration edit cannot retarget them.
  _lifecycle_load_run_record "${lifecycle_run_id}" || {
    common_die "the recorded run could not be reloaded before phase one"
    return 1
  }
  # No node has been mutated yet, so a failure here can still simply stop.
  _lifecycle_event \
    record \
    record-before-state \
    succeeded \
    "run_id=${lifecycle_run_id}" || {
    common_die "the before-state run event could not be recorded"
    return 1
  }

  # Phase one, sub-phase one: read-only verification of all four ranks. No node
  # has been mutated yet, so any rejection stops without recovery.
  lifecycle_index=0
  while [ "${lifecycle_index}" -lt 4 ]; do
    if ! _lifecycle_verify_rank "${lifecycle_index}" "${lifecycle_run_id}"; then
      _lifecycle_event_best_effort \
        phase-one \
        verify-rank \
        failed \
        "rank=${lifecycle_index}" \
        "node_id=${_LIFECYCLE_NODE_IDS[lifecycle_index]}"
      _lifecycle_set_run_status "${lifecycle_run_id}" failed || true
      common_die "phase one rejected a rank before any node was mutated"
      return 1
    fi
    if ! _lifecycle_event \
      phase-one \
      verify-rank \
      succeeded \
      "rank=${lifecycle_index}" \
      "node_id=${_LIFECYCLE_NODE_IDS[lifecycle_index]}"; then
      _lifecycle_set_run_status "${lifecycle_run_id}" failed || true
      common_die "a phase one verification event could not be recorded"
      return 1
    fi
    lifecycle_index=$((lifecycle_index + 1))
  done

  # Phase one, sub-phase two: the first mutating sweep. Every failure from here
  # on unwinds through the abort path.
  lifecycle_index=0
  while [ "${lifecycle_index}" -lt 4 ]; do
    if ! _lifecycle_prepare_rank "${lifecycle_index}" "${lifecycle_run_id}"; then
      _lifecycle_event_best_effort \
        phase-one \
        prepare-rank \
        failed \
        "rank=${lifecycle_index}" \
        "node_id=${_LIFECYCLE_NODE_IDS[lifecycle_index]}"
      _lifecycle_abort_launch \
        "${lifecycle_run_id}" \
        "phase one preparation failed before any rank was released"
      return 1
    fi
    if ! _lifecycle_event \
      phase-one \
      prepare-rank \
      succeeded \
      "rank=${lifecycle_index}" \
      "node_id=${_LIFECYCLE_NODE_IDS[lifecycle_index]}"; then
      _lifecycle_abort_launch \
        "${lifecycle_run_id}" \
        "a phase one preparation event could not be recorded"
      return 1
    fi
    lifecycle_index=$((lifecycle_index + 1))
  done

  # Phase one, sub-phase three: read-only confirmation that both pinned ports
  # are now free on every rank.
  lifecycle_index=0
  while [ "${lifecycle_index}" -lt 4 ]; do
    if ! _lifecycle_confirm_rank_ports "${lifecycle_index}"; then
      _lifecycle_event_best_effort \
        phase-one \
        confirm-rank \
        failed \
        "rank=${lifecycle_index}" \
        "node_id=${_LIFECYCLE_NODE_IDS[lifecycle_index]}"
      _lifecycle_abort_launch \
        "${lifecycle_run_id}" \
        "phase one could not confirm free ports before releasing any rank"
      return 1
    fi
    lifecycle_index=$((lifecycle_index + 1))
  done
  _lifecycle_event phase-one phase-one-complete succeeded ranks=4 || {
    _lifecycle_abort_launch \
      "${lifecycle_run_id}" \
      "the phase one completion event could not be recorded"
    return 1
  }

  if ! _lifecycle_release_ranks "${lifecycle_run_id}"; then
    _lifecycle_abort_launch \
      "${lifecycle_run_id}" \
      "at least one rank failed to release"
    return 1
  fi
  _lifecycle_event phase-two phase-two-complete succeeded ranks=4 || {
    _lifecycle_abort_launch \
      "${lifecycle_run_id}" \
      "the phase two completion event could not be recorded"
    return 1
  }

  if ! _lifecycle_wait_collective "${lifecycle_run_id}"; then
    _lifecycle_abort_launch \
      "${lifecycle_run_id}" \
      "collective TP4 readiness was not observed"
    return 1
  fi
  _lifecycle_event readiness collective-ready succeeded ranks=4 || {
    _lifecycle_abort_launch \
      "${lifecycle_run_id}" \
      "the collective readiness event could not be recorded"
    return 1
  }

  if ! _lifecycle_wait_api_health; then
    _lifecycle_abort_launch \
      "${lifecycle_run_id}" \
      "the direct API never served this run"
    return 1
  fi
  _lifecycle_event \
    api-health \
    api-healthy \
    succeeded \
    "node_id=${_LIFECYCLE_RUN_NODE_IDS[0]}" || {
    _lifecycle_abort_launch \
      "${lifecycle_run_id}" \
      "the API health event could not be recorded"
    return 1
  }

  _lifecycle_set_run_status "${lifecycle_run_id}" ready || {
    _lifecycle_abort_launch \
      "${lifecycle_run_id}" \
      "the run record could not be finalized"
    return 1
  }
  _lifecycle_event \
    launch \
    launch-succeeded \
    succeeded \
    "run_id=${lifecycle_run_id}" || {
    _lifecycle_abort_launch \
      "${lifecycle_run_id}" \
      "the launch completion event could not be recorded"
    return 1
  }
  printf 'APPLY: TP4 launch complete for run %s\n' "${lifecycle_run_id}"
}

lifecycle_stop() {
  local lifecycle_run_id=$1

  _lifecycle_apply_gate stop "${lifecycle_run_id}" || return
  _lifecycle_load_run_record "${lifecycle_run_id}" || return
  _lifecycle_require_recorded_contract || return
  _lifecycle_require_owned_run "${lifecycle_run_id}" || return
  _lifecycle_stop_classified || {
    common_die "a run-owned container could not be stopped or recorded"
    return 1
  }
  _lifecycle_set_run_status "${lifecycle_run_id}" stopped || {
    common_die "the run record could not be updated after stop"
    return 1
  }
  _lifecycle_event \
    stop \
    stop-run \
    succeeded \
    "containers=${_LIFECYCLE_OWNED_COUNT}" || {
    common_die "the stop completion event could not be recorded"
    return 1
  }
  printf 'APPLY: stopped %s run-owned container(s) for run %s\n' \
    "${_LIFECYCLE_OWNED_COUNT}" \
    "${lifecycle_run_id}"
}

lifecycle_rollback() {
  local lifecycle_run_id=$1

  _lifecycle_apply_gate rollback "${lifecycle_run_id}" || return
  _lifecycle_load_run_record "${lifecycle_run_id}" || return
  _lifecycle_require_recorded_contract || return
  # Every rank and every recorded service is classified read-only first, so an
  # operator rollback either performs its whole plan or performs nothing at
  # all. It can never stop a subset and then skip restoration.
  _lifecycle_classify_run_owned "${lifecycle_run_id}" || return
  [ "${_LIFECYCLE_UNKNOWN_COUNT}" -eq 0 ] || {
    _lifecycle_event_best_effort \
      ownership \
      classify-failed \
      failed \
      "ranks=${_LIFECYCLE_UNKNOWN_RANKS}"
    common_die "a configured node could not be consulted to classify this run"
    return 1
  }
  [ "${_LIFECYCLE_DRIFT_COUNT}" -eq 0 ] || {
    _lifecycle_event_best_effort \
      ownership \
      detect-drift \
      failed \
      "ranks=${_LIFECYCLE_DRIFT_RANKS}"
    common_die "a container with a recorded run name is not owned by this run"
    return 1
  }
  _lifecycle_classify_prelaunch
  [ "${_LIFECYCLE_SERVICE_BLOCKED_COUNT}" -eq 0 ] || {
    _lifecycle_event_best_effort \
      rollback \
      detect-service-drift \
      failed \
      "containers=${_LIFECYCLE_SERVICE_BLOCKED_NAMES}"
    common_die "a recorded pre-launch service could not be proven restorable"
    return 1
  }
  _lifecycle_stop_classified || return
  _lifecycle_restore_classified || return
  _lifecycle_set_run_status "${lifecycle_run_id}" rolled-back || {
    common_die "the run record could not be updated after rollback"
    return 1
  }
  _lifecycle_event \
    rollback \
    rollback-run \
    succeeded \
    "run_id=${lifecycle_run_id}" || {
    common_die "the rollback completion event could not be recorded"
    return 1
  }
  printf 'APPLY: restored the recorded pre-launch state for run %s\n' \
    "${lifecycle_run_id}"
}

# ---------------------------------------------------------------------------
# Read-only inspection
# ---------------------------------------------------------------------------

_lifecycle_read_only_setup() {
  local lifecycle_run_id=$1
  [ "${_GLM53_APPLY:-0}" = "0" ] || {
    common_die "this command is strictly read-only and rejects --apply" 2
    return 2
  }
  _lifecycle_validate_run_id "${lifecycle_run_id}" &&
    _lifecycle_load_contract "${_GLM53_CONFIG_PATH}" "${_GLM53_LOCK_PATH}" &&
    _lifecycle_ssh_options &&
    _lifecycle_load_run_record "${lifecycle_run_id}"
}

# Replaces any line that could carry a credential with a fixed marker.
_lifecycle_redact() {
  local lifecycle_line
  local lifecycle_probe
  while IFS= read -r lifecycle_line; do
    lifecycle_probe="$(
      printf '%s' "${lifecycle_line}" | tr '[:upper:]' '[:lower:]'
    )"
    case "${lifecycle_probe}" in
      *token*|*secret*|*password*|*passphrase*|*bearer*|*authorization*|*apikey*|*api_key*|*api-key*|*credential*|*"private key"*|*"begin "*key*)
        printf '[redacted]\n'
        ;;
      *)
        printf '%s\n' "${lifecycle_line}"
        ;;
    esac
  done
}

lifecycle_status() {
  local lifecycle_run_id=$1
  local lifecycle_index
  local lifecycle_observed
  local lifecycle_expected
  local lifecycle_healthy=1

  _lifecycle_read_only_setup "${lifecycle_run_id}" || return

  printf 'run: %s\n' "${lifecycle_run_id}"
  printf 'recorded-status: %s\n' "${_LIFECYCLE_RUN_STATUS}"
  printf 'profile: %s\n' "${_LIFECYCLE_RUN_PROFILE}"
  printf 'image: %s\n' "${_LIFECYCLE_RUN_IMAGE}"
  printf 'recorded-served-model: %s\n' "${_LIFECYCLE_RUN_SERVED_NAME}"
  printf 'endpoint: %s:%s\n' \
    "${_LIFECYCLE_RUN_FABRIC_IPS[0]}" \
    "${_LIFECYCLE_RUN_API_PORT}"
  printf 'recorded-dist-port: %s\n' "${_LIFECYCLE_RUN_DIST_PORT}"
  if [ "${_LIFECYCLE_RUN_CONFIG_DIGEST}" = "${_LIFECYCLE_CONFIG_DIGEST}" ] &&
    [ "${_LIFECYCLE_RUN_LOCK_DIGEST}" = "${_LIFECYCLE_LOCK_DIGEST}" ]; then
    printf 'recorded-contract: matches-current\n'
  else
    # Reported, not fatal: status stays a faithful read-only view. Every
    # mutation path rejects this drift before touching a node.
    printf 'recorded-contract: differs-from-current\n'
  fi
  lifecycle_index=0
  while [ "${lifecycle_index}" -lt 4 ]; do
    lifecycle_expected="${_LIFECYCLE_RUN_CONTAINER_IDS[lifecycle_index]}|true|${lifecycle_run_id}|${lifecycle_index}|${_LIFECYCLE_RUN_OWNER}"
    if lifecycle_observed="$(
      _lifecycle_run_remote \
        "${_LIFECYCLE_RUN_ALIASES[lifecycle_index]}" \
        docker inspect --format "${_GLM53_LIFECYCLE_RUN_FORMAT}" \
        "${_LIFECYCLE_RUN_CONTAINERS[lifecycle_index]}" 2>/dev/null
    )" && [ "${lifecycle_observed}" = "${lifecycle_expected}" ]; then
      printf 'rank %s %s %s run-owned-and-running\n' \
        "${lifecycle_index}" \
        "${_LIFECYCLE_RUN_NODE_IDS[lifecycle_index]}" \
        "${_LIFECYCLE_RUN_CONTAINERS[lifecycle_index]}"
    else
      printf 'rank %s %s %s not-run-owned-or-not-running\n' \
        "${lifecycle_index}" \
        "${_LIFECYCLE_RUN_NODE_IDS[lifecycle_index]}" \
        "${_LIFECYCLE_RUN_CONTAINERS[lifecycle_index]}"
      lifecycle_healthy=0
    fi
    lifecycle_index=$((lifecycle_index + 1))
  done

  # Serving identity, not mere liveness: an unrelated listener on the recorded
  # address, or the right server holding the wrong model, must not pass.
  if _lifecycle_verify_serving_identity; then
    printf 'api: serving-this-run\n'
  else
    printf 'api: not-serving-this-run\n'
    lifecycle_healthy=0
  fi

  [ "${lifecycle_healthy}" -eq 1 ] || return 1
}

lifecycle_logs() {
  local lifecycle_run_id=$1
  local lifecycle_rank=$2
  local lifecycle_output

  _lifecycle_validate_rank "${lifecycle_rank}" || return
  _lifecycle_read_only_setup "${lifecycle_run_id}" || return
  # The remote status is captured directly instead of through a pipeline, so a
  # missing container or a failing SSH call still fails closed without turning
  # on pipefail for the whole controller.
  lifecycle_output="$(
    _lifecycle_run_remote \
      "${_LIFECYCLE_RUN_ALIASES[lifecycle_rank]}" \
      docker logs --tail "${_GLM53_LIFECYCLE_LOG_TAIL_LINES}" \
      "${_LIFECYCLE_RUN_CONTAINER_IDS[lifecycle_rank]}" 2>/dev/null
  )" || {
    common_die "the run-owned container logs could not be read"
    return 1
  }
  printf '%s\n' "${lifecycle_output}" | _lifecycle_redact
}

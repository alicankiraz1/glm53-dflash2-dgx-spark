#!/usr/bin/env bash

# Read-only correctness and throughput validation of one recorded run.
#
# Validation never starts, stops, or reconfigures anything. It attaches itself
# to a run that is already recorded as ready, proves that the recorded endpoint
# still serves that exact run, and then asks rank 0 to execute the requested
# suites and report a sanitized payload.
#
# Four exit codes carry the whole verdict, so an operator or a wrapper never has
# to parse prose:
#   0  every requested suite passed
#   1  a correctness failure: the deployment answered, and answered wrongly
#   2  a usage or gating rejection, decided before any remote call
#   3  an infrastructure failure: the deployment could not be measured at all
#
# Module dependencies, which callers must source first:
#   lib/common.sh     the error contract
#   lib/config.sh     validated cluster configuration
#   lib/doctor.sh     strict key-only SSH options
#   lib/lifecycle.sh  recorded run state, serving identity, bounded SSH

_GLM53_VALIDATE_LIB_DIR="$(
  cd "$(dirname "${BASH_SOURCE[0]}")" && pwd
)"
readonly _GLM53_VALIDATE_LIB_DIR
readonly _GLM53_VALIDATE_ROOT="${_GLM53_VALIDATE_LIB_DIR}/.."
readonly _GLM53_VALIDATE_TOOL="${_GLM53_VALIDATE_ROOT}/tools/api_validation.py"
readonly _GLM53_VALIDATE_DEFAULT_ROOT="${_GLM53_VALIDATE_ROOT}/results/validation"
readonly _GLM53_VALIDATE_REQUIRED_STATUS=ready

# Cheapest gate first: a smoke failure makes every later suite meaningless, and
# the benchmark is the only one that occupies the deployment for minutes.
readonly _GLM53_VALIDATE_ALL_SUITES="smoke correctness needle benchmark"

# Whole-suite SSH watchdogs, in seconds. A 120K-token needle probe and a
# saturated concurrency-4 benchmark are both legitimately slow, so each suite
# carries the bound its own workload needs instead of one pessimistic number.
# They cap the complete remote Python program, including identity calls and
# every HTTP request it issues.
readonly _GLM53_VALIDATE_SMOKE_TIMEOUT=600
readonly _GLM53_VALIDATE_CORRECTNESS_TIMEOUT=900
readonly _GLM53_VALIDATE_NEEDLE_TIMEOUT=2400
readonly _GLM53_VALIDATE_BENCHMARK_TIMEOUT=5400

# Per-request HTTP budgets, in seconds. These values are deliberately separate
# from the suite watchdogs above: a suite contains multiple valid requests, so
# its total wall-clock budget must not be reused as the timeout for each one.
readonly _GLM53_VALIDATE_SMOKE_REQUEST_TIMEOUT=120
readonly _GLM53_VALIDATE_CORRECTNESS_REQUEST_TIMEOUT=120
readonly _GLM53_VALIDATE_NEEDLE_REQUEST_TIMEOUT=300
readonly _GLM53_VALIDATE_BENCHMARK_REQUEST_TIMEOUT=300

# Reports a message and returns the matching status without depending on
# whether errexit happens to be suppressed at the call site.
_validate_die() {
  local validate_status=$2
  common_die "$1" "${validate_status}" || true
  return "${validate_status}"
}

_validate_suite_timeout() {
  case "$1" in
    smoke) printf '%s\n' "${_GLM53_VALIDATE_SMOKE_TIMEOUT}" ;;
    correctness) printf '%s\n' "${_GLM53_VALIDATE_CORRECTNESS_TIMEOUT}" ;;
    needle) printf '%s\n' "${_GLM53_VALIDATE_NEEDLE_TIMEOUT}" ;;
    benchmark) printf '%s\n' "${_GLM53_VALIDATE_BENCHMARK_TIMEOUT}" ;;
    *) _validate_die "unknown validation suite: $1" 2 ;;
  esac
}

# Resolves the default bounded HTTP timeout for one request in a suite.
_validate_request_timeout() {
  case "$1" in
    smoke) printf '%s\n' "${_GLM53_VALIDATE_SMOKE_REQUEST_TIMEOUT}" ;;
    correctness) printf '%s\n' "${_GLM53_VALIDATE_CORRECTNESS_REQUEST_TIMEOUT}" ;;
    needle) printf '%s\n' "${_GLM53_VALIDATE_NEEDLE_REQUEST_TIMEOUT}" ;;
    benchmark) printf '%s\n' "${_GLM53_VALIDATE_BENCHMARK_REQUEST_TIMEOUT}" ;;
    *) _validate_die "unknown validation suite: $1" 2 ;;
  esac
}

# Validates an optional timeout override without accepting zero, negatives, or
# shell-looking input. Environment variables are intentionally integer-only so
# an accidental typo cannot remove either fail-closed bound.
_validate_positive_timeout_override() {
  local validate_override=$1
  local validate_label=$2
  if [ -n "${validate_override}" ]; then
    case "${validate_override}" in
      *[!0-9]*)
        _validate_die \
          "the ${validate_label} override must be a positive integer" \
          2
        return
        ;;
    esac
    [ "${validate_override}" -ge 1 ] || {
      _validate_die \
        "the ${validate_label} override must be at least one second" \
        2
      return
    }
  fi
  return 0
}

# GLM53_VALIDATE_REQUEST_TIMEOUT_SECONDS limits one HTTP operation in the
# remote tool. GLM53_VALIDATE_SSH_TIMEOUT_SECONDS remains the compatible name
# for the larger total SSH-suite watchdog; it never changes an HTTP timeout.
_validate_request_timeout_for() {
  local validate_override=${GLM53_VALIDATE_REQUEST_TIMEOUT_SECONDS:-}
  _validate_positive_timeout_override \
    "${validate_override}" "validation request timeout" || return
  if [ -n "${validate_override}" ]; then
    printf '%s\n' "${validate_override}"
    return 0
  fi
  _validate_request_timeout "$1"
}

_validate_suite_timeout_for() {
  local validate_override=${GLM53_VALIDATE_SSH_TIMEOUT_SECONDS:-}
  _validate_positive_timeout_override \
    "${validate_override}" "validation SSH timeout" || return
  if [ -n "${validate_override}" ]; then
    printf '%s\n' "${validate_override}"
    return 0
  fi
  _validate_suite_timeout "$1"
}

_validate_timeout_overrides() {
  _validate_positive_timeout_override \
    "${GLM53_VALIDATE_REQUEST_TIMEOUT_SECONDS:-}" \
    "validation request timeout" || return
  _validate_positive_timeout_override \
    "${GLM53_VALIDATE_SSH_TIMEOUT_SECONDS:-}" \
    "validation SSH timeout"
}

_validate_results_root() {
  # The override exists so the contract tests can exercise real directory
  # creation without writing into the repository. It is confined to the testing
  # seam so the published evidence location stays fixed in normal operation.
  if [ "${GLM53_TESTING:-0}" = "1" ] &&
    [ -n "${GLM53_VALIDATE_RESULTS_ROOT:-}" ]; then
    printf '%s\n' "${GLM53_VALIDATE_RESULTS_ROOT}"
    return 0
  fi
  printf '%s\n' "${_GLM53_VALIDATE_DEFAULT_ROOT}"
}

_validate_suite_sequence() {
  case "$1" in
    all) printf '%s\n' "${_GLM53_VALIDATE_ALL_SUITES}" ;;
    smoke|correctness|needle|benchmark) printf '%s\n' "$1" ;;
    *)
      _validate_die \
        "the validate suite must be smoke, correctness, needle, benchmark, or all" \
        2
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Gates, all decided before any evidence directory exists
# ---------------------------------------------------------------------------

# Rejects a recorded run whose contract no longer describes what the current
# configuration and lock say. Evidence is only worth keeping when it can be
# attributed to a known contract, and matching digests alone are not enough:
# the recorded serving parameters must still agree too, or a probe would
# measure a different endpoint than the current configuration describes.
_validate_require_recorded_contract() {
  [ "${_LIFECYCLE_RUN_CONFIG_DIGEST}" = "${_LIFECYCLE_CONFIG_DIGEST}" ] &&
    [ "${_LIFECYCLE_RUN_LOCK_DIGEST}" = "${_LIFECYCLE_LOCK_DIGEST}" ] &&
    [ "${_LIFECYCLE_RUN_API_PORT}" = "${_LIFECYCLE_API_PORT}" ] &&
    [ "${_LIFECYCLE_RUN_DIST_PORT}" = "${_LIFECYCLE_DIST_PORT}" ] &&
    [ "${_LIFECYCLE_RUN_SERVED_NAME}" = "${_LIFECYCLE_SERVED_NAME}" ] &&
    [ "${_LIFECYCLE_RUN_PROFILE}" = "${_LIFECYCLE_PROFILE_NAME}" ] || {
    _validate_die \
      "the recorded run contract no longer matches the current validated contract" \
      2
    return
  }
}

_validate_gate() {
  local validate_run_id=$1
  local validate_requested=$2

  [ "${_GLM53_APPLY:-0}" = "0" ] || {
    _validate_die "validate is strictly read-only and rejects --apply" 2
    return
  }
  _validate_suite_sequence "${validate_requested}" >/dev/null || return 2
  _validate_timeout_overrides || return 2
  _lifecycle_validate_run_id "${validate_run_id}" || return 2
  _lifecycle_load_contract "${_GLM53_CONFIG_PATH}" "${_GLM53_LOCK_PATH}" || return 2
  _lifecycle_ssh_options || return 3
  # An unreadable recorded run is infrastructure rather than usage: the request
  # was well formed, and the identity it names simply cannot be established.
  _lifecycle_load_run_record "${validate_run_id}" || return 3
  [ "${_LIFECYCLE_RUN_STATUS}" = "${_GLM53_VALIDATE_REQUIRED_STATUS}" ] || {
    _validate_die "validate requires an active healthy recorded run" 2
    return
  }
  _validate_require_recorded_contract || return 2
  # Serving identity, not liveness. The probe's remote diagnostics are already
  # discarded inside the lifecycle helper, so nothing a served endpoint printed
  # can reach the operator's terminal.
  _lifecycle_verify_serving_identity || {
    _validate_die \
      "infrastructure failure: the recorded endpoint does not serve this run" \
      3
    return
  }
}

# ---------------------------------------------------------------------------
# Evidence directory
# ---------------------------------------------------------------------------

# Runs one evidence tool subcommand. The tool's own diagnostics are discarded
# because they can name local paths; the controller reports fixed phrasing and
# the durable detail stays inside the evidence directory.
_validate_tool() {
  python3 "${_GLM53_VALIDATE_TOOL}" "$@" 2>/dev/null
}

_validate_open_directory() {
  local validate_run_id=$1
  local validate_root

  validate_root="$(_validate_results_root)"
  _VALIDATE_ID="$(_validate_tool new-id)" || {
    _validate_die \
      "infrastructure failure: a validation identity could not be minted" \
      3
    return
  }
  _VALIDATE_DIRECTORY="$(
    _validate_tool prepare-directory \
      --root "${validate_root}" \
      --run-id "${validate_run_id}" \
      --validation-id "${_VALIDATE_ID}"
  )" || {
    _validate_die \
      "infrastructure failure: the run-scoped evidence directory is unusable" \
      3
    return
  }
}

# Rewrites the manifest in place. Completed suites arrive as a single
# space-separated list of "suite=outcome" records, all of which this module
# generated itself.
_validate_write_manifest() {
  local validate_run_id=$1
  local validate_requested=$2
  local validate_status=$3
  local validate_records=$4
  local validate_record
  local -a validate_completed

  validate_completed=()
  for validate_record in ${validate_records}; do
    validate_completed[${#validate_completed[@]}]=--completed-suite
    validate_completed[${#validate_completed[@]}]="${validate_record}"
  done
  # Bash 3.2 treats an empty array expansion as unset under `set -u`, so the
  # optional records are only expanded when at least one exists.
  if [ "${#validate_completed[@]}" -gt 0 ]; then
    _validate_tool manifest \
      --directory "${_VALIDATE_DIRECTORY}" \
      --run-id "${validate_run_id}" \
      --validation-id "${_VALIDATE_ID}" \
      --requested-suite "${validate_requested}" \
      --profile-name "${_LIFECYCLE_RUN_PROFILE}" \
      --served-model-name "${_LIFECYCLE_RUN_SERVED_NAME}" \
      --config-digest "${_LIFECYCLE_RUN_CONFIG_DIGEST}" \
      --lock-digest "${_LIFECYCLE_RUN_LOCK_DIGEST}" \
      --status "${validate_status}" \
      "${validate_completed[@]}"
  else
    _validate_tool manifest \
      --directory "${_VALIDATE_DIRECTORY}" \
      --run-id "${validate_run_id}" \
      --validation-id "${_VALIDATE_ID}" \
      --requested-suite "${validate_requested}" \
      --profile-name "${_LIFECYCLE_RUN_PROFILE}" \
      --served-model-name "${_LIFECYCLE_RUN_SERVED_NAME}" \
      --config-digest "${_LIFECYCLE_RUN_CONFIG_DIGEST}" \
      --lock-digest "${_LIFECYCLE_RUN_LOCK_DIGEST}" \
      --status "${validate_status}"
  fi
}

# ---------------------------------------------------------------------------
# Remote suite execution
# ---------------------------------------------------------------------------

# Builds the single-line program rank 0 runs for one suite. The tool emits an
# already fully quoted command, so the remote shell expands nothing and the
# controller never assembles remote syntax itself.
_validate_remote_program() {
  local validate_suite=$1
  local validate_request_timeout=$2
  _validate_tool encode --mode "${validate_suite}" -- \
    --base-url "http://${_LIFECYCLE_RUN_FABRIC_IPS[0]}:${_LIFECYCLE_RUN_API_PORT}" \
    --timeout-seconds "${validate_request_timeout}" \
    --expected-model-path "${_LIFECYCLE_RUN_MODEL_PATH}" \
    --expected-served-name "${_LIFECYCLE_RUN_SERVED_NAME}"
}

# Runs one suite and persists its payload, printing the recorded outcome.
# Succeeds whenever a payload became evidence, whatever that evidence says, and
# fails only when the suite could not be measured or could not be trusted.
_validate_run_suite() {
  local validate_suite=$1
  local validate_request_timeout
  local validate_suite_timeout
  local validate_program
  local validate_payload

  validate_request_timeout="$(_validate_request_timeout_for "${validate_suite}")" || return 1
  validate_suite_timeout="$(_validate_suite_timeout_for "${validate_suite}")" || return 1
  validate_program="$(
    _validate_remote_program "${validate_suite}" "${validate_request_timeout}"
  )" || return 1
  # The remote suite's stderr is discarded: it is the one channel that could
  # carry a served response body or a remote path back to the operator.
  validate_payload="$(
    _lifecycle_bounded_ssh \
      "${_LIFECYCLE_RUN_ALIASES[0]}" \
      "${validate_program}" \
      "${validate_suite_timeout}" 2>/dev/null
  )" || return 1
  printf '%s' "${validate_payload}" |
    _validate_tool persist \
      --directory "${_VALIDATE_DIRECTORY}" \
      --name "${validate_suite}.json" \
      --expect-suite "${validate_suite}"
}

# ---------------------------------------------------------------------------
# Public entry point
# ---------------------------------------------------------------------------

validate_run() {
  local validate_run_id=$1
  local validate_requested=$2
  local validate_sequence
  local validate_suite
  local validate_outcome
  local validate_status=passed
  local validate_records=

  _validate_gate "${validate_run_id}" "${validate_requested}" || return
  validate_sequence="$(_validate_suite_sequence "${validate_requested}")" || return 2
  _validate_open_directory "${validate_run_id}" || return
  _validate_write_manifest \
    "${validate_run_id}" \
    "${validate_requested}" \
    started \
    "" || {
    _validate_die \
      "infrastructure failure: the validation manifest could not be written" \
      3
    return
  }

  for validate_suite in ${validate_sequence}; do
    if validate_outcome="$(_validate_run_suite "${validate_suite}")"; then
      validate_records="${validate_records} ${validate_suite}=${validate_outcome}"
    else
      validate_outcome=failed-infrastructure
    fi
    _validate_tool append-event \
      --directory "${_VALIDATE_DIRECTORY}" \
      --suite "${validate_suite}" \
      --status "${validate_outcome}" || true
    printf 'validate: %s %s\n' "${validate_suite}" "${validate_outcome}"
    case "${validate_outcome}" in
      passed) ;;
      failed-correctness)
        # A wrong answer is real evidence, and every remaining suite is still
        # read-only, so validation continues and reports each gate it can.
        [ "${validate_status}" = "failed-infrastructure" ] ||
          validate_status=failed-correctness
        ;;
      *)
        # Nothing was measured. Continuing would only add unmeasurable gates,
        # so the evidence collected so far is finalized and validation stops.
        validate_status=failed-infrastructure
        break
        ;;
    esac
  done

  _validate_write_manifest \
    "${validate_run_id}" \
    "${validate_requested}" \
    "${validate_status}" \
    "${validate_records}" || {
    _validate_die \
      "infrastructure failure: the validation manifest could not be finalized" \
      3
    return
  }
  printf 'validate: run %s validation %s %s\n' \
    "${validate_run_id}" \
    "${_VALIDATE_ID}" \
    "${validate_status}"

  case "${validate_status}" in
    passed) return 0 ;;
    failed-correctness)
      _validate_die "validation reported a correctness failure" 1
      return
      ;;
    *)
      _validate_die "validation reported an infrastructure failure" 3
      return
      ;;
  esac
}

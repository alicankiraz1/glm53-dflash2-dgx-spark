#!/usr/bin/env bash

# Read-only validation contract. Every remote call, endpoint, and served
# response in this file is a local fake: nothing here reaches a node, a
# container runtime, an API, or the network.

set -eu

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT_DIR
readonly LOCK_PATH="${ROOT_DIR}/config/reproduction.lock.json"
readonly BASE_CONFIG="${ROOT_DIR}/tests/fixtures/cluster.valid.json"
readonly SERVING_FIXTURE="${ROOT_DIR}/tests/fixtures/lifecycle/serving-identity.json"
readonly RUN_ID=20260828T200000.000000Z-0a1b2c3d4e5f60718293a4b5c6d7e8f9
readonly STOPPED_RUN_ID=20260828T201000.000000Z-1b2c3d4e5f60718293a4b5c6d7e8f9a0
readonly DRIFT_RUN_ID=20260828T202000.000000Z-2c3d4e5f60718293a4b5c6d7e8f9a0b1
readonly MISSING_RUN_ID=20260828T203000.000000Z-3d4e5f60718293a4b5c6d7e8f9a0b1c2
readonly SYMLINK_RUN_ID=20260828T204000.000000Z-4e5f60718293a4b5c6d7e8f9a0b1c2d3
readonly EXPECTED_ENDPOINT=192.0.2.10:8002
readonly SERVED_MODEL=glm-5.3-flash-nvfp4

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

pass() {
  printf 'PASS: %s\n' "$*"
}

assert_contains() {
  local haystack=$1
  local needle=$2
  case "${haystack}" in
    *"${needle}"*) ;;
    *) fail "expected output to contain: ${needle}" ;;
  esac
}

assert_not_contains() {
  local haystack=$1
  local needle=$2
  case "${haystack}" in
    *"${needle}"*) fail "output contains forbidden text: ${needle}" ;;
    *) ;;
  esac
}

assert_log_contains() {
  assert_contains "$(cat "${ssh_log}")" "$1"
}

assert_log_not_contains() {
  assert_not_contains "$(cat "${ssh_log}")" "$1"
}

file_mode() {
  if stat -f '%Lp' "$1" >/dev/null 2>&1; then
    stat -f '%Lp' "$1"
  else
    stat -c '%a' "$1"
  fi
}

temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/glm53-validate-test.XXXXXX")"
cleanup() {
  rm -rf "${temporary_root}"
}
trap cleanup EXIT HUP INT TERM

fake_bin="${temporary_root}/bin"
ssh_log="${temporary_root}/ssh.log"
state_root="${temporary_root}/state"
results_root="${temporary_root}/results"
test_config="${temporary_root}/cluster.json"
drifted_config="${temporary_root}/cluster-drifted.json"
mkdir "${fake_bin}" "${results_root}"

cp "${BASE_CONFIG}" "${test_config}"

cat >"${temporary_root}/seed.py" <<'SEED_EOF'
"""Seed recorded run state for the read-only validation contract tests."""

import json
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(sys.argv[1])))

from tools.config_state import (  # noqa: E402
    STATE_VERSION,
    RunState,
    config_digest,
    load_cluster,
    load_reproduction_lock,
    lock_digest,
    write_run_state,
)

repository_root = pathlib.Path(sys.argv[1])
config_path = pathlib.Path(sys.argv[2])
lock_path = pathlib.Path(sys.argv[3])
state_directory = pathlib.Path(sys.argv[4])
serving_path = pathlib.Path(sys.argv[5])
drifted_config_path = pathlib.Path(sys.argv[6])

cluster = load_cluster(config_path)
lock = load_reproduction_lock(lock_path)
serving = json.loads(serving_path.read_text(encoding="utf-8"))
current_config_digest = config_digest(cluster)
current_lock_digest = lock_digest(lock)

# A second valid configuration whose API port differs from the recorded run, so
# recorded-contract drift can be exercised without inventing invalid input.
drifted = json.loads(config_path.read_text(encoding="utf-8"))
drifted["ports"]["api"] = serving["drifted_current_config"]["api_port"]
drifted_config_path.write_text(json.dumps(drifted, indent=2) + "\n", encoding="utf-8")
drifted_digest = config_digest(load_cluster(drifted_config_path))


def build_ranks(run_id):
    ranks = []
    for node in cluster.nodes:
        ranks.append(
            {
                "rank": node.rank,
                "node_id": node.id,
                "ssh_alias": node.ssh_alias,
                "fabric_ipv4": node.fabric_ipv4,
                "remote_root": node.remote_root,
                "hf_cache_root": node.hf_cache_root,
                "container_name": f"glm53-spark-{run_id}-rank{node.rank}",
                "container_id": f"{node.rank + 1:064x}",
                "argv": ["python3", "-m", "sglang.launch_server"],
                "mounts": [
                    {
                        "source": node.hf_cache_root,
                        "target": node.hf_cache_root,
                        "mode": "ro",
                    }
                ],
                "prelaunch_services": [],
                "rollback_actions": [],
            }
        )
    return ranks


def record(run_id, status, recorded_config_digest):
    write_run_state(
        state_directory,
        RunState(
            version=STATE_VERSION,
            run_id=run_id,
            config_digest=recorded_config_digest,
            lock_digest=current_lock_digest,
            created_at="2026-08-28T20:00:00.000000Z",
            status=status,
            data={
                "owner": "glm53-spark",
                "profile_name": lock.profile.profile_name,
                "image_reference": (
                    f"{lock.runtime.image_repository}:{lock.profile.profile_name}"
                ),
                "served_model_name": lock.profile.served_name,
                "model_path": serving["expected_model_path"],
                "api_port": cluster.ports.api,
                "dist_port": cluster.ports.distributed,
                "ranks": build_ranks(run_id),
            },
        ),
    )


record(sys.argv[7], "ready", current_config_digest)
record(sys.argv[8], "stopped", current_config_digest)
record(sys.argv[9], "ready", drifted_digest)
record(sys.argv[10], "ready", current_config_digest)
print(lock.profile.profile_name)
SEED_EOF

profile_name="$(
  python3 "${temporary_root}/seed.py" \
    "${ROOT_DIR}" \
    "${test_config}" \
    "${LOCK_PATH}" \
    "${state_root}" \
    "${SERVING_FIXTURE}" \
    "${drifted_config}" \
    "${RUN_ID}" \
    "${STOPPED_RUN_ID}" \
    "${DRIFT_RUN_ID}" \
    "${SYMLINK_RUN_ID}"
)"
readonly profile_name
[ -n "${profile_name}" ] || fail "recorded run seeding did not report a profile"

# The fake remote shell answers exactly three things: the serving identity
# probes the recorded run must satisfy, and the encoded validation payload the
# controller asks rank 0 to produce.
cat >"${fake_bin}/ssh" <<'SSH_EOF'
#!/usr/bin/env bash
set -u

fake_log=${GLM53_FAKE_SSH_LOG}
fake_endpoint=${GLM53_FAKE_EXPECTED_ENDPOINT}
fake_model_path=${GLM53_FAKE_MODEL_PATH}
fake_served_name=${GLM53_FAKE_SERVED_NAME}
fake_identity=${GLM53_FAKE_IDENTITY:-ok}
fake_hang_seconds=${GLM53_FAKE_HANG_SECONDS:-0}
fake_request_count=${GLM53_FAKE_REQUEST_COUNT:-0}
fake_request_seconds=${GLM53_FAKE_REQUEST_SECONDS:-0}

fake_arguments=("$@")
fake_count=${#fake_arguments[@]}
if [ "${fake_count}" -lt 2 ]; then
  printf 'fake ssh: alias and command are required\n' >&2
  exit 255
fi
remote_command=${fake_arguments[fake_count - 1]}
alias_name=${fake_arguments[fake_count - 2]}

saw_batch_mode=0
saw_strict_host_key=0
saw_user_known_hosts=0
for fake_argument in "$@"; do
  case "${fake_argument}" in
    *accept-new*|*StrictHostKeyChecking=no*)
      printf 'fake ssh: permissive host key policy\n' >&2
      exit 255
      ;;
    BatchMode=yes) saw_batch_mode=1 ;;
    StrictHostKeyChecking=yes) saw_strict_host_key=1 ;;
    UserKnownHostsFile=*) saw_user_known_hosts=1 ;;
  esac
done
if [ "${saw_batch_mode}" -ne 1 ] ||
  [ "${saw_strict_host_key}" -ne 1 ] ||
  [ "${saw_user_known_hosts}" -ne 1 ]; then
  printf 'fake ssh: strict key-only options are missing\n' >&2
  exit 255
fi

eval "set -- ${remote_command}"

case "$1" in
  curl)
    probe_last=
    for fake_argument in "$@"; do
      probe_last=${fake_argument}
    done
    probe_target=${probe_last#http://}
    probe_path=${probe_target#*/}
    probe_endpoint=${probe_target%%/*}
    printf 'PROBE alias=%s path=%s\n' "${alias_name}" "${probe_path}" >>"${fake_log}"
    if [ "${probe_endpoint}" != "${fake_endpoint}" ]; then
      printf 'fake ssh: probe reached %s, expected %s\n' \
        "${probe_endpoint}" "${fake_endpoint}" >&2
      exit 7
    fi
    if [ "${fake_identity}" = "down" ]; then
      printf 'fake ssh: the endpoint refused the probe\n' >&2
      exit 7
    fi
    case "${probe_path}" in
      get_model_info)
        if [ "${fake_identity}" = "wrong-model" ]; then
          printf '{"model_path":"/srv/hf-cache/models--other--Model/snapshots/0","is_generation":true}\n'
        else
          printf '{"model_path":"%s","tokenizer_path":"%s","is_generation":true}\n' \
            "${fake_model_path}" "${fake_model_path}"
        fi
        ;;
      v1/models)
        printf '{"object":"list","data":[{"id":"%s","object":"model"}]}\n' \
          "${fake_served_name}"
        ;;
      health_generate)
        printf 'ok\n'
        ;;
      *)
        printf 'fake ssh: unsupported probe path %s\n' "${probe_path}" >&2
        exit 7
        ;;
    esac
    exit 0
    ;;
  python3)
    payload_mode=
    payload_base_url=
    payload_timeout=
    payload_expect_next=
    for fake_argument in "$@"; do
      case "${payload_expect_next}" in
        mode) payload_mode=${fake_argument}; payload_expect_next= ;;
        base-url) payload_base_url=${fake_argument}; payload_expect_next= ;;
        timeout-seconds) payload_timeout=${fake_argument}; payload_expect_next= ;;
      esac
      case "${fake_argument}" in
        --mode) payload_expect_next=mode ;;
        --base-url) payload_expect_next=base-url ;;
        --timeout-seconds) payload_expect_next=timeout-seconds ;;
      esac
    done
    printf 'SUITE alias=%s mode=%s base-url=%s timeout-seconds=%s request-count=%s\n' \
      "${alias_name}" "${payload_mode}" "${payload_base_url}" \
      "${payload_timeout}" "${fake_request_count}" >>"${fake_log}"
    if [ "${payload_base_url}" != "http://${fake_endpoint}" ]; then
      printf 'fake ssh: suite targeted %s, expected the recorded endpoint\n' \
        "${payload_base_url}" >&2
      exit 7
    fi
    if [ "${fake_hang_seconds}" != "0" ]; then
      # Match the one-process SSH failure the controller owns: exec prevents a
      # child from retaining the command-substitution pipe after termination.
      exec sleep "${fake_hang_seconds}"
    fi
    fake_request_index=0
    while [ "${fake_request_index}" -lt "${fake_request_count}" ]; do
      sleep "${fake_request_seconds}"
      fake_request_index=$((fake_request_index + 1))
    done
    outcome_variable="GLM53_FAKE_SUITE_$(
      printf '%s' "${payload_mode}" | tr '[:lower:]' '[:upper:]'
    )"
    eval "outcome=\${${outcome_variable}:-passed}"
    case "${outcome}" in
      transport)
        printf 'fake ssh: the remote suite could not run\n' >&2
        exit 1
        ;;
      malformed)
        printf 'this is not a JSON document\n'
        exit 0
        ;;
      leaky)
        printf '{"schema_version":1,"suite":"%s","served_model_name":"%s",' \
          "${payload_mode}" "${fake_served_name}"
        printf '"model_path_matches_recorded_run":true,"outcome":"passed",'
        printf '"request_configuration":{"temperature":0.0},'
        printf '"cases":[{"name":"smoke","suite":"%s","passed":true,' \
          "${payload_mode}"
        printf '"failure_class":null,"detail":"the case matched its expectation",'
        printf '"prompt_tokens":24,"completion_tokens":19,"finish_reason":"stop",'
        printf '"content_characters":5,"reasoning_characters":58,'
        printf '"authorization":"Bearer synthetic-value"}]}\n'
        exit 0
        ;;
    esac
    if [ "${payload_mode}" = "benchmark" ]; then
      printf '{"schema_version":1,"suite":"benchmark","served_model_name":"%s",' \
        "${fake_served_name}"
      printf '"model_path_matches_recorded_run":true,"outcome":"%s",' "${outcome}"
      printf '"request_configuration":{"output_tokens_per_request":1024,'
      printf '"warmup_output_tokens":128,"temperature":0.0,"rounds":3},'
      printf '"concurrency":{"c1":{"concurrency":1,"request_count":3,'
      printf '"succeeded":3,"failed":0,'
      printf '"aggregate_end_to_end_tokens_per_second":32.0,'
      printf '"failure_classes":[]},"c4":{"concurrency":4,"request_count":8,'
      printf '"succeeded":8,"failed":0,'
      printf '"aggregate_end_to_end_tokens_per_second":64.0,'
      printf '"failure_classes":[]}}}\n'
      exit 0
    fi
    printf '{"schema_version":1,"suite":"%s","served_model_name":"%s",' \
      "${payload_mode}" "${fake_served_name}"
    printf '"model_path_matches_recorded_run":true,"outcome":"%s",' "${outcome}"
    printf '"request_configuration":{"temperature":0.0,"max_tokens":4096},'
    printf '"cases":[{"name":"case-one","suite":"%s","passed":true,' \
      "${payload_mode}"
    printf '"failure_class":null,"detail":"the case matched its expectation",'
    printf '"prompt_tokens":24,"completion_tokens":19,"finish_reason":"stop",'
    printf '"content_characters":5,"reasoning_characters":58}],'
    printf '"needle_probes":[]}\n'
    exit 0
    ;;
esac

printf 'fake ssh: unsupported remote command: %s\n' "$1" >&2
exit 255
SSH_EOF
chmod 0700 "${fake_bin}/ssh"

# Validation must never reach a cluster tool from the controller itself.
for forbidden_executable in docker rsync hf curl; do
  cat >"${fake_bin}/${forbidden_executable}" <<'GUARD_EOF'
#!/usr/bin/env bash
printf 'guard: the controller executed a cluster tool locally\n' >&2
exit 90
GUARD_EOF
  chmod 0700 "${fake_bin}/${forbidden_executable}"
done

PATH="${fake_bin}:${PATH}"
export PATH
export GLM53_TESTING=1
export GLM53_FAKE_SSH_LOG="${ssh_log}"
export GLM53_FAKE_EXPECTED_ENDPOINT="${EXPECTED_ENDPOINT}"
export GLM53_FAKE_MODEL_PATH
GLM53_FAKE_MODEL_PATH="$(
  python3 -c 'import json,pathlib,sys; print(json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))["expected_model_path"])' \
    "${SERVING_FIXTURE}"
)"
export GLM53_FAKE_SERVED_NAME="${SERVED_MODEL}"
export GLM53_VALIDATE_RESULTS_ROOT="${results_root}"

reset_environment() {
  : >"${ssh_log}"
  unset GLM53_FAKE_IDENTITY || true
  unset GLM53_FAKE_HANG_SECONDS || true
  unset GLM53_FAKE_REQUEST_COUNT || true
  unset GLM53_FAKE_REQUEST_SECONDS || true
  unset GLM53_FAKE_SUITE_SMOKE || true
  unset GLM53_FAKE_SUITE_CORRECTNESS || true
  unset GLM53_FAKE_SUITE_NEEDLE || true
  unset GLM53_FAKE_SUITE_BENCHMARK || true
}

run_validate() {
  local invocation_config=$1
  shift
  set +e
  validate_output="$(
    "${ROOT_DIR}/glm53-spark" \
      --config "${invocation_config}" \
      --lock "${LOCK_PATH}" \
      --state-root "${state_root}" \
      "$@" 2>&1
  )"
  validate_status=$?
  set -e
}

latest_validation_directory() {
  local run_directory="${results_root}/${1}"
  local candidate
  local newest=
  [ -d "${run_directory}" ] || return 1
  for candidate in "${run_directory}"/*; do
    [ -d "${candidate}" ] || continue
    newest=${candidate}
  done
  [ -n "${newest}" ] || return 1
  printf '%s' "${newest}"
}

count_validation_directories() {
  local run_directory="${results_root}/${1}"
  local candidate
  local total=0
  [ -d "${run_directory}" ] || {
    printf '0'
    return 0
  }
  for candidate in "${run_directory}"/*; do
    [ -d "${candidate}" ] || continue
    total=$((total + 1))
  done
  printf '%s' "${total}"
}

json_field() {
  python3 -c '
import json
import pathlib
import sys

document = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
for key in sys.argv[2].split("."):
    if isinstance(document, list):
        document = document[int(key)]
    else:
        document = document[key]
print(json.dumps(document, sort_keys=True))
' "$1" "$2"
}

# ---------------------------------------------------------------------------
# Argument and gating contract
# ---------------------------------------------------------------------------

reset_environment
run_validate "${test_config}" validate
[ "${validate_status}" -eq 2 ] ||
  fail "validate without --run-id exited ${validate_status}, expected 2"
assert_contains "${validate_output}" "--run-id"
[ ! -s "${ssh_log}" ] || fail "validate contacted a node before validating options"
pass "validate requires an explicit recorded run"

reset_environment
run_validate "${test_config}" --apply validate --run-id "${RUN_ID}"
[ "${validate_status}" -eq 2 ] ||
  fail "validate --apply exited ${validate_status}, expected 2"
assert_contains "${validate_output}" "read-only"
[ ! -s "${ssh_log}" ] || fail "rejected --apply still contacted a node"
[ "$(count_validation_directories "${RUN_ID}")" = "0" ] ||
  fail "rejected --apply created validation output"
pass "validate rejects mutation consent and stays read-only"

reset_environment
run_validate "${test_config}" validate --run-id "${RUN_ID}" --suite everything
[ "${validate_status}" -eq 2 ] ||
  fail "unknown suite exited ${validate_status}, expected 2"
assert_contains "${validate_output}" "suite"
[ ! -s "${ssh_log}" ] || fail "an unknown suite still contacted a node"
pass "validate accepts only the documented suite names"

reset_environment
run_validate "${test_config}" validate --run-id "not-a-run-identity"
[ "${validate_status}" -eq 2 ] ||
  fail "malformed run ID exited ${validate_status}, expected 2"
[ ! -s "${ssh_log}" ] || fail "a malformed run ID still contacted a node"
pass "validate rejects an unsafe run identity before any remote call"

reset_environment
run_validate "${test_config}" validate --run-id "${RUN_ID}" --unsupported x
[ "${validate_status}" -eq 2 ] ||
  fail "unsupported option exited ${validate_status}, expected 2"
assert_contains "${validate_output}" "unsupported validate option"
pass "validate rejects unsupported options"

reset_environment
run_validate "${test_config}" validate --run-id "${RUN_ID}" --suite
[ "${validate_status}" -eq 2 ] ||
  fail "a valueless --suite exited ${validate_status}, expected 2"
pass "validate requires a value for --suite"

reset_environment
run_validate "${test_config}" validate --run-id "${MISSING_RUN_ID}"
[ "${validate_status}" -ne 0 ] || fail "validate accepted an unrecorded run"
[ "${validate_status}" -ne 2 ] || fail "an unreadable run record must not read as usage"
[ ! -s "${ssh_log}" ] || fail "an unrecorded run still contacted a node"
pass "validate refuses a run it cannot read from recorded state"

reset_environment
run_validate "${test_config}" validate --run-id "${STOPPED_RUN_ID}"
[ "${validate_status}" -eq 2 ] ||
  fail "a stopped run exited ${validate_status}, expected 2"
assert_contains "${validate_output}" "active"
[ ! -s "${ssh_log}" ] || fail "a stopped run still contacted a node"
pass "validate requires an active healthy recorded run"

reset_environment
run_validate "${drifted_config}" validate --run-id "${DRIFT_RUN_ID}"
[ "${validate_status}" -eq 2 ] ||
  fail "recorded contract drift exited ${validate_status}, expected 2"
assert_contains "${validate_output}" "recorded"
pass "validate refuses to attribute evidence to a drifted contract"

# ---------------------------------------------------------------------------
# Serving identity gate
# ---------------------------------------------------------------------------

reset_environment
GLM53_FAKE_IDENTITY=down run_validate "${test_config}" \
  validate --run-id "${RUN_ID}" --suite smoke
[ "${validate_status}" -eq 3 ] ||
  fail "an unreachable endpoint exited ${validate_status}, expected 3"
assert_contains "${validate_output}" "infrastructure"
assert_not_contains "${validate_output}" "refused the probe"
[ "$(count_validation_directories "${RUN_ID}")" = "0" ] ||
  fail "a failed identity gate created validation output"
pass "validate fails closed with an infrastructure exit when identity cannot be proven"

reset_environment
GLM53_FAKE_IDENTITY=wrong-model run_validate "${test_config}" \
  validate --run-id "${RUN_ID}" --suite smoke
[ "${validate_status}" -eq 3 ] ||
  fail "a mismatched served model exited ${validate_status}, expected 3"
pass "validate refuses an endpoint that does not serve the recorded model"

# ---------------------------------------------------------------------------
# Successful suites and run-scoped output
# ---------------------------------------------------------------------------

reset_environment
run_validate "${test_config}" validate --run-id "${RUN_ID}" --suite smoke
[ "${validate_status}" -eq 0 ] ||
  fail "the smoke suite exited ${validate_status}: ${validate_output}"
assert_log_contains "path=get_model_info"
assert_log_contains "path=v1/models"
assert_log_contains "mode=smoke"
assert_log_not_contains "mode=benchmark"
smoke_directory="$(latest_validation_directory "${RUN_ID}")"
[ -f "${smoke_directory}/smoke.json" ] || fail "the smoke artifact was not persisted"
[ -f "${smoke_directory}/manifest.json" ] || fail "the validation manifest is missing"
[ -f "${smoke_directory}/events.jsonl" ] || fail "the validation event log is missing"
[ ! -f "${smoke_directory}/benchmark.json" ] ||
  fail "a single-suite run produced an unrequested benchmark artifact"
[ "$(file_mode "${smoke_directory}")" = "700" ] ||
  fail "the validation directory is not restricted to its owner"
[ "$(file_mode "${smoke_directory}/smoke.json")" = "600" ] ||
  fail "the persisted suite artifact is not restricted to its owner"
[ "$(json_field "${smoke_directory}/manifest.json" status)" = '"passed"' ] ||
  fail "the manifest did not record a passing validation"
[ "$(json_field "${smoke_directory}/manifest.json" run_id)" = "\"${RUN_ID}\"" ] ||
  fail "the manifest is not scoped to the validated run"
[ "$(json_field "${smoke_directory}/manifest.json" profile_name)" = "\"${profile_name}\"" ] ||
  fail "the manifest did not record the validated profile"
pass "a passing suite writes restricted, run-scoped, self-describing evidence"

reset_environment
run_validate "${test_config}" validate --run-id "${RUN_ID}" --suite smoke
[ "${validate_status}" -eq 0 ] || fail "the second smoke run exited ${validate_status}"
[ "$(count_validation_directories "${RUN_ID}")" = "2" ] ||
  fail "a repeated validation overwrote the previous evidence"
pass "repeated validation never overwrites earlier evidence"

reset_environment
run_validate "${test_config}" validate --run-id "${RUN_ID}" --suite benchmark
[ "${validate_status}" -eq 0 ] ||
  fail "the benchmark suite exited ${validate_status}: ${validate_output}"
benchmark_directory="$(latest_validation_directory "${RUN_ID}")"
[ -f "${benchmark_directory}/benchmark.json" ] ||
  fail "the benchmark artifact was not persisted"
[ ! -f "${benchmark_directory}/smoke.json" ] ||
  fail "the benchmark suite ran an unrequested API suite"
[ "$(json_field "${benchmark_directory}/benchmark.json" concurrency.c1.concurrency)" = "1" ] ||
  fail "the benchmark artifact does not report concurrency 1"
[ "$(json_field "${benchmark_directory}/benchmark.json" concurrency.c4.concurrency)" = "4" ] ||
  fail "the benchmark artifact does not report concurrency 4"
benchmark_invocations="$(grep -c 'mode=benchmark' "${ssh_log}")"
[ "${benchmark_invocations}" -eq 1 ] ||
  fail "the benchmark suite issued ${benchmark_invocations} remote invocations"
pass "the benchmark suite reports exactly concurrency 1 and 4"

reset_environment
run_validate "${test_config}" validate --run-id "${RUN_ID}" --suite all
[ "${validate_status}" -eq 0 ] ||
  fail "the full suite exited ${validate_status}: ${validate_output}"
all_directory="$(latest_validation_directory "${RUN_ID}")"
for suite_artifact in smoke correctness needle benchmark; do
  [ -f "${all_directory}/${suite_artifact}.json" ] ||
    fail "the full suite did not persist ${suite_artifact}.json"
done
observed_order="$(awk -F'mode=' '/SUITE /{split($2,parts," "); printf "%s ", parts[1]}' "${ssh_log}")"
[ "${observed_order}" = "smoke correctness needle benchmark " ] ||
  fail "the full suite ran gates out of order: ${observed_order}"
pass "the default full suite orders gates from cheapest to most expensive"

reset_environment
run_validate "${test_config}" validate --run-id "${RUN_ID}"
[ "${validate_status}" -eq 0 ] || fail "the default suite exited ${validate_status}"
assert_log_contains "mode=benchmark"
pass "validate defaults to the full suite"

# ---------------------------------------------------------------------------
# Failure classification
# ---------------------------------------------------------------------------

reset_environment
GLM53_FAKE_SUITE_CORRECTNESS=failed-correctness run_validate "${test_config}" \
  validate --run-id "${RUN_ID}" --suite all
[ "${validate_status}" -eq 1 ] ||
  fail "a correctness failure exited ${validate_status}, expected 1"
assert_contains "${validate_output}" "correctness"
correctness_directory="$(latest_validation_directory "${RUN_ID}")"
[ -f "${correctness_directory}/benchmark.json" ] ||
  fail "a correctness failure stopped the remaining read-only gates"
[ "$(json_field "${correctness_directory}/manifest.json" status)" = '"failed-correctness"' ] ||
  fail "the manifest did not record a correctness failure"
pass "a correctness failure is reported without masking later gates"

reset_environment
GLM53_FAKE_SUITE_CORRECTNESS=transport run_validate "${test_config}" \
  validate --run-id "${RUN_ID}" --suite all
[ "${validate_status}" -eq 3 ] ||
  fail "an infrastructure failure exited ${validate_status}, expected 3"
transport_directory="$(latest_validation_directory "${RUN_ID}")"
[ -f "${transport_directory}/smoke.json" ] ||
  fail "an interrupted validation discarded the evidence it had already collected"
[ ! -f "${transport_directory}/needle.json" ] ||
  fail "an infrastructure failure did not stop the remaining gates"
[ "$(json_field "${transport_directory}/manifest.json" status)" = '"failed-infrastructure"' ] ||
  fail "the manifest did not record an infrastructure failure"
assert_not_contains "${validate_output}" "could not run"
pass "an infrastructure failure stops progression and stays inspectable"

reset_environment
GLM53_FAKE_SUITE_SMOKE=malformed run_validate "${test_config}" \
  validate --run-id "${RUN_ID}" --suite smoke
[ "${validate_status}" -eq 3 ] ||
  fail "a malformed suite payload exited ${validate_status}, expected 3"
malformed_directory="$(latest_validation_directory "${RUN_ID}")"
[ ! -f "${malformed_directory}/smoke.json" ] ||
  fail "a malformed payload was persisted as validation evidence"
[ "$(json_field "${malformed_directory}/manifest.json" status)" = '"failed-infrastructure"' ] ||
  fail "a malformed payload was not classified as infrastructure"
pass "a malformed remote payload is rejected as an infrastructure failure"

reset_environment
GLM53_FAKE_SUITE_SMOKE=leaky run_validate "${test_config}" \
  validate --run-id "${RUN_ID}" --suite smoke
[ "${validate_status}" -eq 3 ] ||
  fail "a payload with unknown fields exited ${validate_status}, expected 3"
leaky_directory="$(latest_validation_directory "${RUN_ID}")"
[ ! -f "${leaky_directory}/smoke.json" ] ||
  fail "a payload carrying an unexpected field was persisted"
pass "persisted evidence rejects fields the schema does not define"

# ---------------------------------------------------------------------------
# Output safety
# ---------------------------------------------------------------------------

reset_environment
run_validate "${test_config}" validate --run-id "${RUN_ID}" --suite all
[ "${validate_status}" -eq 0 ] || fail "the sanitation run exited ${validate_status}"
sanitation_directory="$(latest_validation_directory "${RUN_ID}")"
for artifact in "${sanitation_directory}"/*; do
  for forbidden in \
    "192.0.2." \
    "glm53-node-" \
    "/srv/hf-cache" \
    "Authorization" \
    "Bearer" \
    "known_hosts" \
    "Reply with"; do
    if grep -Fq "${forbidden}" "${artifact}"; then
      fail "validation evidence leaked ${forbidden} into $(basename "${artifact}")"
    fi
  done
done
for forbidden in "192.0.2." "/srv/hf-cache" "Bearer"; do
  assert_not_contains "${validate_output}" "${forbidden}"
done
pass "persisted and printed validation output carries no inventory or credentials"

reset_environment
symlinked_run="${results_root}/${SYMLINK_RUN_ID}"
ln -s "${temporary_root}" "${symlinked_run}"
run_validate "${test_config}" validate --run-id "${SYMLINK_RUN_ID}" --suite smoke
[ "${validate_status}" -ne 0 ] ||
  fail "validate wrote evidence through a symlinked run directory"
rm -f "${symlinked_run}"
pass "validate refuses a run output path that is not a plain directory"

reset_environment
# Each fake request is below the one-second HTTP budget, but their aggregate
# duration exceeds it. The larger SSH budget must allow this legitimate suite
# to finish instead of reusing the HTTP value as a suite-wide deadline.
export GLM53_VALIDATE_REQUEST_TIMEOUT_SECONDS=1
export GLM53_VALIDATE_SSH_TIMEOUT_SECONDS=3
GLM53_FAKE_REQUEST_COUNT=3 GLM53_FAKE_REQUEST_SECONDS=0.6 \
  run_validate "${test_config}" \
  validate --run-id "${RUN_ID}" --suite smoke
unset GLM53_VALIDATE_REQUEST_TIMEOUT_SECONDS
unset GLM53_VALIDATE_SSH_TIMEOUT_SECONDS
[ "${validate_status}" -eq 0 ] ||
  fail "cumulative bounded requests exited ${validate_status}, expected 0"
assert_log_contains "mode=smoke"
assert_log_contains "timeout-seconds=1 request-count=3"
pass "per-request and whole-suite validation budgets are independent"

reset_environment
export GLM53_VALIDATE_SSH_TIMEOUT_SECONDS=2
validate_started=${SECONDS}
GLM53_FAKE_HANG_SECONDS=5 run_validate "${test_config}" \
  validate --run-id "${RUN_ID}" --suite smoke
validate_elapsed=$((SECONDS - validate_started))
unset GLM53_VALIDATE_SSH_TIMEOUT_SECONDS
[ "${validate_status}" -eq 3 ] ||
  fail "a hung remote suite exited ${validate_status}, expected 3"
[ "${validate_elapsed}" -le 4 ] ||
  fail "a two-second suite watchdog returned after ${validate_elapsed} seconds"
pass "a hung remote suite is bounded by the controller watchdog"

reset_environment
export GLM53_VALIDATE_REQUEST_TIMEOUT_SECONDS=not-a-timeout
run_validate "${test_config}" validate --run-id "${RUN_ID}" --suite smoke
unset GLM53_VALIDATE_REQUEST_TIMEOUT_SECONDS
[ "${validate_status}" -eq 2 ] ||
  fail "an invalid request timeout exited ${validate_status}, expected 2"
assert_contains "${validate_output}" "request timeout override"
[ ! -s "${ssh_log}" ] || fail "an invalid request timeout contacted a node"
pass "validate rejects an invalid per-request timeout before remote work"

reset_environment
export GLM53_VALIDATE_SSH_TIMEOUT_SECONDS=0
run_validate "${test_config}" validate --run-id "${RUN_ID}" --suite smoke
unset GLM53_VALIDATE_SSH_TIMEOUT_SECONDS
[ "${validate_status}" -eq 2 ] ||
  fail "an invalid suite timeout exited ${validate_status}, expected 2"
assert_contains "${validate_output}" "SSH timeout override"
[ ! -s "${ssh_log}" ] || fail "an invalid suite timeout contacted a node"
pass "validate rejects an invalid whole-suite timeout before remote work"

printf 'Validation contract passed.\n'

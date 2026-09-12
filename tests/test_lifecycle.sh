#!/usr/bin/env bash

set -eu

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT_DIR
readonly LOCK_PATH="${ROOT_DIR}/config/reproduction.lock.json"
readonly BASE_CONFIG="${ROOT_DIR}/tests/fixtures/cluster.valid.json"
readonly LIFECYCLE_FIXTURES="${ROOT_DIR}/tests/fixtures/lifecycle"
readonly PRELAUNCH_FIXTURE="${LIFECYCLE_FIXTURES}/prelaunch-services.json"
readonly RANK_FAILURE_FIXTURE="${LIFECYCLE_FIXTURES}/rank-failure.json"
readonly SERVING_FIXTURE="${LIFECYCLE_FIXTURES}/serving-identity.json"
readonly RUN_ID=20260828T120000.000000Z-00112233445566778899aabbccddeeff
readonly HEALTH_RUN_ID=20260828T130000.000000Z-1122334455667788990011223344aabb
readonly FAIL_RUN_ID=20260828T140000.000000Z-22334455667788990011223344aabbcc
readonly DRIFT_RUN_ID=20260828T150000.000000Z-334455667788990011223344aabbccdd
readonly PORT4_RUN_ID=20260828T160000.000000Z-44556677889900112233445566778899
readonly PORT6_RUN_ID=20260828T161000.000000Z-5566778899001122334455667788990a
readonly PORTFAIL_RUN_ID=20260828T162000.000000Z-66778899001122334455667788990abc
readonly EVENT1_RUN_ID=20260828T170000.000000Z-778899001122334455667788990abcde
readonly EVENT2_RUN_ID=20260828T171000.000000Z-8899001122334455667788990abcdef0
readonly SWAP_RUN_ID=20260828T180000.000000Z-99001122334455667788990abcdef012
readonly MIDDRIFT_RUN_ID=20260828T190000.000000Z-a1b2c3d4e5f60718293a4b5c6d7e8f90
readonly ABORT_RUN_ID=20260828T191000.000000Z-b2c3d4e5f60718293a4b5c6d7e8f90a1
readonly TRANSPORT_RUN_ID=20260828T192000.000000Z-c3d4e5f60718293a4b5c6d7e8f90a1b2
readonly ERREXIT_ABORT_RUN_ID=20260828T193000.000000Z-d4e5f60718293a4b5c6d7e8f90a1b2c3
readonly ERREXIT_GONE_RUN_ID=20260828T194000.000000Z-e5f60718293a4b5c6d7e8f90a1b2c3d4
readonly RANK_SWAP_ABORT_RUN_ID=20260828T195000.000000Z-f60718293a4b5c6d7e8f90a1b2c3d4e5
readonly RECEIPT_FAIL_RUN_ID=20260828T196000.000000Z-0718293a4b5c6d7e8f90a1b2c3d4e5f6
readonly RENAMED_RUN_ID=20260828T197000.000000Z-18293a4b5c6d7e8f90a1b2c3d4e5f607

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

# shellcheck source=/dev/null
. "${ROOT_DIR}/lib/common.sh"
# shellcheck source=/dev/null
. "${ROOT_DIR}/lib/config.sh"
# shellcheck source=/dev/null
. "${ROOT_DIR}/lib/doctor.sh"
# shellcheck source=/dev/null
. "${ROOT_DIR}/lib/lifecycle.sh"

temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/glm53-lifecycle-test.XXXXXX")"
cleanup() {
  rm -rf "${temporary_root}"
}
trap cleanup EXIT HUP INT TERM

fake_bin="${temporary_root}/bin"
fake_containers="${temporary_root}/containers"
fake_machines="${temporary_root}/machines"
ssh_log="${temporary_root}/ssh.log"
doctor_log="${temporary_root}/doctor.log"
state_root="${temporary_root}/state"
test_config="${temporary_root}/cluster.json"
drifted_config="${temporary_root}/cluster-drifted.json"
timeout_config="${temporary_root}/cluster-short-timeout.json"
event_counter="${temporary_root}/event-counter"
mkdir "${fake_bin}" "${fake_containers}" "${fake_machines}"

cat >"${temporary_root}/seed.py" <<'SEED_EOF'
"""Build a lifecycle test cluster config and seed fake container state."""

import hashlib
import json
import pathlib
import sys

fixture_path = pathlib.Path(sys.argv[1])
base_config_path = pathlib.Path(sys.argv[2])
output_config_path = pathlib.Path(sys.argv[3])
containers_root = pathlib.Path(sys.argv[4])
machines_root = pathlib.Path(sys.argv[5])
serving_path = pathlib.Path(sys.argv[6])
drifted_config_path = pathlib.Path(sys.argv[7])
timeout_config_path = pathlib.Path(sys.argv[8])

fixture = json.loads(fixture_path.read_text(encoding="utf-8"))
serving = json.loads(serving_path.read_text(encoding="utf-8"))
config = json.loads(base_config_path.read_text(encoding="utf-8"))
prefix = fixture["machine_id_prefix"]

for node in config["nodes"]:
    machine_id = f"{prefix}-{node['id']}"
    node["expected_machine_id_sha256"] = hashlib.sha256(
        machine_id.encode("utf-8")
    ).hexdigest()
    (machines_root / node["ssh_alias"]).write_text(
        machine_id + "\n",
        encoding="utf-8",
    )
output_config_path.write_text(json.dumps(config, indent=2) + "\n", encoding="utf-8")

# A second, still valid configuration whose API port and rank-0 fabric address
# differ from the recorded run. Read-only inspection must keep using the
# recorded endpoint, and run mutation must reject the recorded contract drift.
drifted = json.loads(json.dumps(config))
drifted["ports"]["api"] = serving["drifted_current_config"]["api_port"]
drifted["nodes"][0]["fabric_ipv4"] = serving["drifted_current_config"][
    "source_fabric_ipv4"
]
drifted_config_path.write_text(json.dumps(drifted, indent=2) + "\n", encoding="utf-8")

# A third valid configuration whose command timeout is short enough that a
# hung remote call can be proven bounded without a slow test.
short_timeout = json.loads(json.dumps(config))
short_timeout["ssh"]["command_timeout_seconds"] = 2
timeout_config_path.write_text(
    json.dumps(short_timeout, indent=2) + "\n",
    encoding="utf-8",
)


def write_container(alias, container_id, name, owner, image, state):
    directory = containers_root / alias
    directory.mkdir(parents=True, exist_ok=True)
    (directory / name).write_text(
        "\n".join(
            (
                f"id={container_id}",
                f"owner={owner}",
                f"image={image}",
                f"state={state}",
                "run-id=",
                "rank=",
            )
        )
        + "\n",
        encoding="utf-8",
    )


for node in fixture["nodes"]:
    (containers_root / node["ssh_alias"]).mkdir(parents=True, exist_ok=True)
    for service in node["services"]:
        write_container(
            node["ssh_alias"],
            service["id"],
            service["name"],
            "glm53-spark",
            service["image"],
            service["state"],
        )
for service in fixture["unowned_services"]:
    write_container(
        service["ssh_alias"],
        service["id"],
        service["name"],
        service["owner"],
        service["image"],
        service["state"],
    )
SEED_EOF

python3 "${temporary_root}/seed.py" \
  "${PRELAUNCH_FIXTURE}" \
  "${BASE_CONFIG}" \
  "${test_config}" \
  "${fake_containers}" \
  "${fake_machines}" \
  "${SERVING_FIXTURE}" \
  "${drifted_config}" \
  "${timeout_config}"

json_field() {
  python3 -c 'import json,pathlib,sys;print(json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))[sys.argv[2]])' \
    "$1" "$2"
}

nested_field() {
  python3 -c '
import json
import pathlib
import sys

value = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
for key in sys.argv[2:]:
    value = value[int(key)] if isinstance(value, list) else value[key]
print(value)
' "$@"
}

failing_rank="$(json_field "${RANK_FAILURE_FIXTURE}" failing_rank)"
failing_phase="$(json_field "${RANK_FAILURE_FIXTURE}" failing_phase)"
failing_exit_code="$(json_field "${RANK_FAILURE_FIXTURE}" failing_exit_code)"
unowned_service_name="$(
  nested_field "${PRELAUNCH_FIXTURE}" unowned_services 0 name
)"
prior_rank2_id="$(nested_field "${PRELAUNCH_FIXTURE}" nodes 2 services 0 id)"
# Every owner-labelled recorded service, in the rank-then-record order the run
# state preserves, so ordering assertions do not restate the fixture.
recorded_service_names="$(
  python3 -c '
import json
import pathlib
import sys

fixture = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
for node in fixture["nodes"]:
    for service in node["services"]:
        print(service["name"])
' "${PRELAUNCH_FIXTURE}"
)"
middle_drift_name="$(
  nested_field "${PRELAUNCH_FIXTURE}" middle_replacement_service name
)"
middle_drift_id="$(
  nested_field "${PRELAUNCH_FIXTURE}" middle_replacement_service id
)"
middle_drift_alias="$(
  nested_field "${PRELAUNCH_FIXTURE}" middle_replacement_service ssh_alias
)"
# The safe services are every recorded service except the drifted one. An
# abort must restore all of them, including those ordered after the drift.
safe_service_names="$(
  printf '%s\n' "${recorded_service_names}" |
    grep -v "^${middle_drift_name}$" |
    sort
)"
replacement_id="$(nested_field "${PRELAUNCH_FIXTURE}" replacement_service id)"
replacement_name="$(nested_field "${PRELAUNCH_FIXTURE}" replacement_service name)"
replacement_alias="$(
  nested_field "${PRELAUNCH_FIXTURE}" replacement_service ssh_alias
)"
expected_served_name="$(
  json_field "${SERVING_FIXTURE}" expected_served_model_name
)"
expected_model_path="$(json_field "${SERVING_FIXTURE}" expected_model_path)"
wrong_served_name="$(json_field "${SERVING_FIXTURE}" wrong_served_model_name)"
wrong_model_path="$(json_field "${SERVING_FIXTURE}" wrong_model_path)"
unrelated_body="$(json_field "${SERVING_FIXTURE}" unrelated_listener_body)"
drifted_api_port="$(
  nested_field "${SERVING_FIXTURE}" drifted_current_config api_port
)"

cat >"${fake_bin}/ssh" <<'SSH_EOF'
#!/usr/bin/env bash
# Local fake that models a remote POSIX shell, docker daemon, and HTTP probe.
set -u

fake_log=${GLM53_FAKE_SSH_LOG}
fake_containers=${GLM53_FAKE_CONTAINERS}
fake_machines=${GLM53_FAKE_MACHINES}
fake_fail_rank=${GLM53_FAKE_FAIL_RANK:--1}
fake_fail_phase=${GLM53_FAKE_FAIL_PHASE:-none}
fake_fail_exit=${GLM53_FAKE_FAIL_EXIT:-1}
fake_health=${GLM53_FAKE_HEALTH:-ok}
fake_log_secret=${GLM53_FAKE_LOG_SECRET:-0}
fake_ss_mode=${GLM53_FAKE_SS_MODE:-free}
fake_ss_alias=${GLM53_FAKE_SS_BUSY_ALIAS:-}
fake_hang_seconds=${GLM53_FAKE_HANG_SECONDS:-0}
fake_endpoint=${GLM53_FAKE_EXPECTED_ENDPOINT:-192.0.2.10:8002}
fake_model_path=${GLM53_FAKE_MODEL_PATH:-}
fake_served_name=${GLM53_FAKE_SERVED_NAME:-}
fake_wrong_model_path=${GLM53_FAKE_WRONG_MODEL_PATH:-}
fake_wrong_served_name=${GLM53_FAKE_WRONG_SERVED_NAME:-}
fake_unrelated_body=${GLM53_FAKE_UNRELATED_BODY:-}
# Swaps one recorded service for a same-name, same-owner container with a
# different ID the instant after the pre-launch observation reads it, which
# models an operator recreating a service between recording and quiescing.
fake_swap_after_ps=${GLM53_FAKE_SWAP_AFTER_PS:-}
# Alias-scoped transport faults. GLM53_FAKE_SSH_DOWN_ALIAS models an
# unreachable node, which real ssh reports as exit 255, and
# GLM53_FAKE_HANG_ALIAS models a node that accepts the connection and then
# never answers, which only the controller watchdog can bound.
fake_down_alias=${GLM53_FAKE_SSH_DOWN_ALIAS:-}
fake_hang_alias=${GLM53_FAKE_HANG_ALIAS:-}
# Replaces a quiesced service with a same-name, same-owner container carrying a
# different ID while the ranks are being released, so a launch abort meets an
# identity drift it could not have seen during quiesce.
fake_swap_on_run=${GLM53_FAKE_SWAP_ON_RUN:-}
fake_swap_on_run_alias=${GLM53_FAKE_SWAP_ON_RUN_ALIAS:-}
# Recreates one newly released rank with its name and labels intact but a new
# Docker ID. This models a replacement after `docker run` returned its ID.
fake_swap_rank_on_run=${GLM53_FAKE_SWAP_RANK_ON_RUN:-}
# Replaces one service only after inspect emitted its original identity, making
# the following mutation prove it addresses the immutable ID rather than name.
fake_swap_after_service_inspect=${GLM53_FAKE_SWAP_AFTER_SERVICE_INSPECT:-}
# Models Docker creating a container and printing its ID before a later SSH
# transport failure is reported to the controller.
fake_create_then_fail_rank=${GLM53_FAKE_CREATE_THEN_FAIL_RANK:--1}

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
saw_connect_timeout=
for fake_argument in "$@"; do
  case "${fake_argument}" in
    *accept-new*|*StrictHostKeyChecking=no*)
      printf 'fake ssh: permissive host key policy\n' >&2
      exit 255
      ;;
    BatchMode=yes) saw_batch_mode=1 ;;
    StrictHostKeyChecking=yes) saw_strict_host_key=1 ;;
    UserKnownHostsFile=*) saw_user_known_hosts=1 ;;
    ConnectTimeout=*) saw_connect_timeout=${fake_argument#ConnectTimeout=} ;;
  esac
done
if [ "${saw_batch_mode}" -ne 1 ] ||
  [ "${saw_strict_host_key}" -ne 1 ] ||
  [ "${saw_user_known_hosts}" -ne 1 ]; then
  printf 'fake ssh: strict key-only options are missing\n' >&2
  exit 255
fi

printf 'INVOKE alias=%s command=%s connect-timeout=%s\n' \
  "${alias_name}" "${remote_command}" "${saw_connect_timeout}" \
  >>"${fake_log}"

if [ -n "${fake_down_alias}" ] && [ "${alias_name}" = "${fake_down_alias}" ]; then
  printf 'fake ssh: connect to host %s port 22: No route to host\n' \
    "${alias_name}" >&2
  exit 255
fi

if [ -n "${fake_hang_alias}" ] && [ "${alias_name}" = "${fake_hang_alias}" ]; then
  exec sleep 30
fi

if [ "${fake_hang_seconds}" != "0" ]; then
  exec sleep "${fake_hang_seconds}"
fi

fake_rank=-1
case "${alias_name}" in
  *-a) fake_rank=0 ;;
  *-b) fake_rank=1 ;;
  *-c) fake_rank=2 ;;
  *-d) fake_rank=3 ;;
esac

container_field() {
  local field_file=$1
  local field_key=$2
  local field_name
  local field_value
  [ -f "${field_file}" ] || return 1
  while IFS='=' read -r field_name field_value; do
    if [ "${field_name}" = "${field_key}" ]; then
      printf '%s' "${field_value}"
      return 0
    fi
  done <"${field_file}"
  return 0
}

container_path_for_ref() {
  local container_ref=$1
  local candidate
  local direct_path="${fake_containers}/${alias_name}/${container_ref}"
  if [ -f "${direct_path}" ]; then
    printf '%s' "${direct_path}"
    return 0
  fi
  for candidate in "${fake_containers}/${alias_name}"/*; do
    [ -f "${candidate}" ] || continue
    if [ "$(container_field "${candidate}" id)" = "${container_ref}" ]; then
      printf '%s' "${candidate}"
      return 0
    fi
  done
  return 1
}

synthetic_id() {
  printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
}

write_container() {
  local container_alias=$1
  local container_id=$2
  local container_name=$3
  local container_owner=$4
  local container_image=$5
  local container_state=$6
  local container_run_id=$7
  local container_rank=$8
  mkdir -p "${fake_containers}/${container_alias}"
  {
    printf 'id=%s\n' "${container_id}"
    printf 'owner=%s\n' "${container_owner}"
    printf 'image=%s\n' "${container_image}"
    printf 'state=%s\n' "${container_state}"
    printf 'run-id=%s\n' "${container_run_id}"
    printf 'rank=%s\n' "${container_rank}"
  } >"${fake_containers}/${container_alias}/${container_name}"
}

set_container_state() {
  local target_ref=$1
  local target_state=$2
  local target_file
  local target_name
  target_file="$(container_path_for_ref "${target_ref}")" || return 1
  target_name="$(basename "${target_file}")"
  write_container \
    "${alias_name}" \
    "$(container_field "${target_file}" id)" \
    "${target_name}" \
    "$(container_field "${target_file}" owner)" \
    "$(container_field "${target_file}" image)" \
    "${target_state}" \
    "$(container_field "${target_file}" run-id)" \
    "$(container_field "${target_file}" rank)"
}

# Parse the remote command exactly as a remote POSIX shell would.
eval "set -- ${remote_command}"

last_argument=
for fake_argument in "$@"; do
  last_argument=${fake_argument}
done

case "$1" in
  cat)
    cat "${fake_machines}/${alias_name}"
    exit 0
    ;;
  test|mkdir)
    exit 0
    ;;
  ss)
    case "${fake_ss_mode}" in
      free)
        exit 0
        ;;
      fail)
        printf 'fake ssh: ss failed\n' >&2
        exit 1
        ;;
      near-miss)
        printf 'LISTEN 0      4096       192.0.2.10:80020      0.0.0.0:*\n'
        printf 'LISTEN 0      4096       192.0.2.10:18002      0.0.0.0:*\n'
        printf 'LISTEN 0      4096       192.0.2.10:8003       0.0.0.0:*\n'
        exit 0
        ;;
      ipv4-busy)
        if [ "${alias_name}" = "${fake_ss_alias}" ]; then
          printf 'LISTEN 0      4096       192.0.2.13:8002       0.0.0.0:*\n'
        fi
        exit 0
        ;;
      ipv6-busy)
        if [ "${alias_name}" = "${fake_ss_alias}" ]; then
          printf 'LISTEN 0      4096            [::]:8002            [::]:*\n'
        fi
        exit 0
        ;;
    esac
    printf 'fake ssh: unsupported ss mode\n' >&2
    exit 1
    ;;
  curl)
    probe_target=${last_argument#http://}
    probe_path=${probe_target#*/}
    probe_endpoint=${probe_target%%/*}
    if [ "${probe_endpoint}" != "${fake_endpoint}" ]; then
      printf 'fake ssh: probe reached %s, expected %s\n' \
        "${probe_endpoint}" "${fake_endpoint}" >&2
      exit 7
    fi
    if [ "${fake_health}" = "fail" ]; then
      printf 'fake ssh: health probe failed\n' >&2
      exit 22
    fi
    case "${probe_path}" in
      get_model_info)
        case "${fake_health}" in
          unrelated)
            printf '%s\n' "${fake_unrelated_body}"
            ;;
          wrong-model)
            printf '{"model_path":"%s","is_generation":true}\n' \
              "${fake_wrong_model_path}"
            ;;
          *)
            printf '{"model_path":"%s","is_generation":true}\n' \
              "${fake_model_path}"
            ;;
        esac
        exit 0
        ;;
      v1/models)
        case "${fake_health}" in
          unrelated)
            printf '%s\n' "${fake_unrelated_body}"
            ;;
          wrong-served)
            printf '{"object":"list","data":[{"id":"%s","object":"model"}]}\n' \
              "${fake_wrong_served_name}"
            ;;
          *)
            printf '{"object":"list","data":[{"id":"%s","object":"model"}]}\n' \
              "${fake_served_name}"
            ;;
        esac
        exit 0
        ;;
      health_generate)
        if [ "${fake_health}" = "generate-fail" ]; then
          printf 'fake ssh: generation probe failed\n' >&2
          exit 22
        fi
        printf 'OK\n'
        exit 0
        ;;
    esac
    printf 'fake ssh: unsupported probe path: %s\n' "${probe_path}" >&2
    exit 22
    ;;
  docker) ;;
  *)
    printf 'fake ssh: unsupported remote command: %s\n' "$1" >&2
    exit 255
    ;;
esac

shift
case "$1" in
  image)
    case "$*" in
      *'io.glm53.owner'*)
        printf 'glm53-spark\n'
        exit 0
        ;;
      *)
        printf 'fake ssh: unexpected runtime image label template\n' >&2
        exit 1
        ;;
    esac
    ;;
  ps)
    case "$*" in
      *label=com.glm53-spark.owner=glm53-spark*)
        [ -d "${fake_containers}/${alias_name}" ] || exit 0
        for candidate in "${fake_containers}/${alias_name}"/*; do
          [ -f "${candidate}" ] || continue
          candidate_owner="$(container_field "${candidate}" owner)"
          candidate_state="$(container_field "${candidate}" state)"
          [ "${candidate_owner}" = "glm53-spark" ] || continue
          [ "${candidate_state}" = "running" ] || continue
          printf '%s|%s|%s|%s\n' \
            "$(container_field "${candidate}" id)" \
            "$(basename "${candidate}")" \
            "$(container_field "${candidate}" image)" \
            "${candidate_state}"
        done
        if [ -n "${fake_swap_after_ps}" ] &&
          [ -f "${fake_containers}/${alias_name}/${fake_swap_after_ps}" ]; then
          swap_file="${fake_containers}/${alias_name}/${fake_swap_after_ps}"
          write_container \
            "${alias_name}" \
            "$(synthetic_id "replacement-${fake_swap_after_ps}")" \
            "${fake_swap_after_ps}" \
            "$(container_field "${swap_file}" owner)" \
            "$(container_field "${swap_file}" image)" \
            "$(container_field "${swap_file}" state)" \
            "$(container_field "${swap_file}" run-id)" \
            "$(container_field "${swap_file}" rank)"
        fi
        exit 0
        ;;
      *name=*)
        name_filter=
        for fake_argument in "$@"; do
          case "${fake_argument}" in
            name=*) name_filter=${fake_argument#name=} ;;
          esac
        done
        [ -d "${fake_containers}/${alias_name}" ] || exit 0
        for candidate in "${fake_containers}/${alias_name}"/*; do
          [ -f "${candidate}" ] || continue
          candidate_name="$(basename "${candidate}")"
          case "${candidate_name}" in
            *"${name_filter}"*) printf '%s\n' "${candidate_name}" ;;
          esac
        done
        exit 0
        ;;
      *id=*)
        id_filter=
        for fake_argument in "$@"; do
          case "${fake_argument}" in
            id=*) id_filter=${fake_argument#id=} ;;
          esac
        done
        [ -d "${fake_containers}/${alias_name}" ] || exit 0
        for candidate in "${fake_containers}/${alias_name}"/*; do
          [ -f "${candidate}" ] || continue
          [ "$(container_field "${candidate}" id)" = "${id_filter}" ] || continue
          printf '%s\n' "$(container_field "${candidate}" id)"
        done
        exit 0
        ;;
    esac
    exit 0
    ;;
  inspect)
    inspect_file="$(container_path_for_ref "${last_argument}")" || {
      printf 'fake ssh: no such container\n' >&2
      exit 1
    }
    inspect_owner="$(container_field "${inspect_file}" owner)"
    inspect_state="$(container_field "${inspect_file}" state)"
    inspect_running=false
    if [ "${inspect_state}" = "running" ]; then
      inspect_running=true
    fi
    case "$*" in
      *com.glm53-spark.run-id*)
        printf '%s|%s|%s|%s|%s\n' \
          "$(container_field "${inspect_file}" id)" \
          "${inspect_running}" \
          "$(container_field "${inspect_file}" run-id)" \
          "$(container_field "${inspect_file}" rank)" \
          "${inspect_owner}"
        ;;
      *'{{.Id}}'*)
        printf '%s|%s|%s|%s\n' \
          "$(container_field "${inspect_file}" id)" \
          "${inspect_owner}" \
          "$(container_field "${inspect_file}" image)" \
          "${inspect_running}"
        if [ -n "${fake_swap_after_service_inspect}" ] &&
          [ "$(basename "${inspect_file}")" = "${fake_swap_after_service_inspect}" ]; then
          write_container \
            "${alias_name}" \
            "$(synthetic_id "post-inspect-${fake_swap_after_service_inspect}")" \
            "${fake_swap_after_service_inspect}" \
            "${inspect_owner}" \
            "$(container_field "${inspect_file}" image)" \
            "$(container_field "${inspect_file}" state)" \
            "$(container_field "${inspect_file}" run-id)" \
            "$(container_field "${inspect_file}" rank)"
        fi
        ;;
      *)
        printf '%s|%s\n' "${inspect_owner}" "${inspect_running}"
        ;;
    esac
    exit 0
    ;;
  run)
    release_name=
    release_image=
    release_run_id=
    release_rank=
    previous_argument=
    for fake_argument in "$@"; do
      if [ "${previous_argument}" = "--name" ]; then
        release_name=${fake_argument}
      fi
      case "${fake_argument}" in
        com.glm53-spark.run-id=*) release_run_id=${fake_argument#*=} ;;
        com.glm53-spark.rank=*) release_rank=${fake_argument#*=} ;;
        glm53-dflash2-dgx-spark:*) release_image=${fake_argument} ;;
      esac
      previous_argument=${fake_argument}
    done
    printf 'RELEASE-START rank=%s name=%s\n' "${fake_rank}" "${release_name}" \
      >>"${fake_log}"
    if [ -n "${fake_swap_on_run}" ] &&
      [ "${alias_name}" = "${fake_swap_on_run_alias}" ] &&
      [ -f "${fake_containers}/${alias_name}/${fake_swap_on_run}" ]; then
      swap_file="${fake_containers}/${alias_name}/${fake_swap_on_run}"
      write_container \
        "${alias_name}" \
        "$(synthetic_id "release-swap-${fake_swap_on_run}")" \
        "${fake_swap_on_run}" \
        "$(container_field "${swap_file}" owner)" \
        "$(container_field "${swap_file}" image)" \
        "$(container_field "${swap_file}" state)" \
        "$(container_field "${swap_file}" run-id)" \
        "$(container_field "${swap_file}" rank)"
    fi
    sleep 1
    if [ "${fake_fail_phase}" = "release" ] &&
      [ "${fake_fail_rank}" = "${fake_rank}" ]; then
      if [ "${fake_create_then_fail_rank}" = "${fake_rank}" ]; then
        write_container \
          "${alias_name}" \
          "$(synthetic_id "${release_name}")" \
          "${release_name}" \
          glm53-spark \
          "${release_image}" \
          running \
          "${release_run_id}" \
          "${release_rank}"
        synthetic_id "${release_name}"
      fi
      printf 'RELEASE-FAIL rank=%s\n' "${fake_rank}" >>"${fake_log}"
      printf 'fake ssh: rank %s release failed\n' "${fake_rank}" >&2
      exit "${fake_fail_exit}"
    fi
    write_container \
      "${alias_name}" \
      "$(synthetic_id "${release_name}")" \
      "${release_name}" \
      glm53-spark \
      "${release_image}" \
      running \
      "${release_run_id}" \
      "${release_rank}"
    if [ "${fake_swap_rank_on_run}" = "${fake_rank}" ]; then
      release_file="${fake_containers}/${alias_name}/${release_name}"
      write_container \
        "${alias_name}" \
        "$(synthetic_id "replacement-${release_name}")" \
        "${release_name}" \
        "$(container_field "${release_file}" owner)" \
        "$(container_field "${release_file}" image)" \
        "$(container_field "${release_file}" state)" \
        "$(container_field "${release_file}" run-id)" \
        "$(container_field "${release_file}" rank)"
    fi
    synthetic_id "${release_name}"
    printf 'RELEASE-END rank=%s name=%s\n' "${fake_rank}" "${release_name}" \
      >>"${fake_log}"
    exit 0
    ;;
  stop)
    stop_name="$(basename "$(container_path_for_ref "${last_argument}")")" || {
      printf 'fake ssh: no such container\n' >&2
      exit 1
    }
    printf 'STOP alias=%s name=%s id=%s\n' \
      "${alias_name}" "${stop_name}" "${last_argument}" \
      >>"${fake_log}"
    set_container_state "${last_argument}" exited || {
      printf 'fake ssh: no such container\n' >&2
      exit 1
    }
    exit 0
    ;;
  start)
    start_name="$(basename "$(container_path_for_ref "${last_argument}")")" || {
      printf 'fake ssh: no such container\n' >&2
      exit 1
    }
    printf 'START alias=%s name=%s\n' "${alias_name}" "${start_name}" \
      >>"${fake_log}"
    set_container_state "${last_argument}" running || {
      printf 'fake ssh: no such container\n' >&2
      exit 1
    }
    exit 0
    ;;
  logs)
    if ! container_path_for_ref "${last_argument}" >/dev/null; then
      printf 'fake ssh: no such container\n' >&2
      exit 1
    fi
    printf 'sglang: server started\n'
    if [ "${fake_log_secret}" = "1" ]; then
      printf 'authorization: Bearer synthetic-value\n'
    fi
    printf 'sglang: all four ranks joined\n'
    exit 0
    ;;
esac

printf 'fake ssh: unsupported docker subcommand: %s\n' "$1" >&2
exit 255
SSH_EOF
chmod 0700 "${fake_bin}/ssh"

# Deterministic append-event fault injection. The wrapper only intercepts the
# append-event subcommand and otherwise execs the real interpreter unchanged.
real_python3="$(command -v python3)"
cat >"${fake_bin}/python3" <<'PYTHON_EOF'
#!/usr/bin/env bash
set -u

fail_at=${GLM53_FAKE_EVENT_FAIL_AT:-0}
if [ "${fail_at}" -gt 0 ]; then
  for python_argument in "$@"; do
    if [ "${python_argument}" = "append-event" ]; then
      python_count=0
      if [ -f "${GLM53_FAKE_EVENT_COUNTER}" ]; then
        python_count="$(cat "${GLM53_FAKE_EVENT_COUNTER}")"
      fi
      python_count=$((python_count + 1))
      printf '%s\n' "${python_count}" >"${GLM53_FAKE_EVENT_COUNTER}"
      if [ "${python_count}" -eq "${fail_at}" ]; then
        printf 'fake python3: injected append-event failure\n' >&2
        exit 2
      fi
      break
    fi
  done
fi
exec "${GLM53_REAL_PYTHON3}" "$@"
PYTHON_EOF
chmod 0700 "${fake_bin}/python3"

# The lifecycle module must never reach a real cluster from these tests.
for forbidden_executable in docker rsync hf curl; do
  cat >"${fake_bin}/${forbidden_executable}" <<'GUARD_EOF'
#!/usr/bin/env bash
printf 'guard: controller executed a cluster tool locally\n' >&2
exit 90
GUARD_EOF
  chmod 0700 "${fake_bin}/${forbidden_executable}"
done

doctor_run() {
  printf 'doctor\n' >>"${doctor_log}"
  return 0
}

# Calling a lifecycle function from inside `if` or after `set +e` suppresses
# errexit for the whole dynamic extent of the call, which hides any unguarded
# non-zero status inside the function. This harness reproduces the production
# dispatcher instead: strict `set -eu`, the real libraries, and a top-level
# call whose status the parent captures from outside the child.
errexit_harness="${temporary_root}/errexit-harness.sh"
cat >"${errexit_harness}" <<'HARNESS_EOF'
#!/usr/bin/env bash
set -eu

_GLM53_ROOT_DIR=${HARNESS_REPO}
_GLM53_APPLY=${HARNESS_APPLY}
_GLM53_PLAN_DIGEST=${HARNESS_PLAN_DIGEST}
_GLM53_CONFIG_PATH=${HARNESS_CONFIG}
_GLM53_LOCK_PATH=${HARNESS_LOCK}
_GLM53_STATE_ROOT=${HARNESS_STATE_ROOT}

. "${_GLM53_ROOT_DIR}/lib/common.sh"
. "${_GLM53_ROOT_DIR}/lib/config.sh"
. "${_GLM53_ROOT_DIR}/lib/doctor.sh"
. "${_GLM53_ROOT_DIR}/lib/lifecycle.sh"

# The read-only preflight is exercised by the doctor suite; this harness only
# needs it to succeed so the apply gate reaches the lifecycle behavior.
doctor_run() {
  return 0
}

"$@"
HARNESS_EOF
chmod 0700 "${errexit_harness}"

# Runs one lifecycle call under production errexit and prints its exit status.
# The status is captured in the parent, so the child is free to terminate the
# way the real dispatcher would.
errexit_call() {
  local harness_status=0
  HARNESS_REPO="${ROOT_DIR}" \
    HARNESS_APPLY="${_GLM53_APPLY}" \
    HARNESS_PLAN_DIGEST="${_GLM53_PLAN_DIGEST}" \
    HARNESS_CONFIG="${_GLM53_CONFIG_PATH}" \
    HARNESS_LOCK="${_GLM53_LOCK_PATH}" \
    HARNESS_STATE_ROOT="${_GLM53_STATE_ROOT}" \
    bash "${errexit_harness}" "$@" \
    >"${temporary_root}/errexit.out" 2>"${temporary_root}/errexit.err" ||
    harness_status=$?
  printf '%s\n' "${harness_status}"
}

export GLM53_FAKE_SSH_LOG="${ssh_log}"
export GLM53_FAKE_CONTAINERS="${fake_containers}"
export GLM53_FAKE_MACHINES="${fake_machines}"
export GLM53_FAKE_MODEL_PATH="${expected_model_path}"
export GLM53_FAKE_SERVED_NAME="${expected_served_name}"
export GLM53_FAKE_WRONG_MODEL_PATH="${wrong_model_path}"
export GLM53_FAKE_WRONG_SERVED_NAME="${wrong_served_name}"
export GLM53_FAKE_UNRELATED_BODY="${unrelated_body}"
export GLM53_FAKE_EVENT_COUNTER="${event_counter}"
export GLM53_REAL_PYTHON3="${real_python3}"
export GLM53_TESTING=1
export GLM53_LIFECYCLE_READY_ATTEMPTS=3
export GLM53_LIFECYCLE_READY_INTERVAL_SECONDS=0

_GLM53_CONFIG_PATH="${test_config}"
_GLM53_LOCK_PATH="${LOCK_PATH}"
_GLM53_STATE_ROOT="${state_root}"
_GLM53_APPLY=0
_GLM53_PLAN_DIGEST=

original_path=${PATH}
PATH="${fake_bin}:${PATH}"

digest_of() {
  shasum -a 256 "$1" | awk '{print $1}'
}

plan_digest_of() {
  lifecycle_plan "$1" "$2" | awk -F': ' '/^PLAN_SHA256: / {print $2}'
}

container_name_for() {
  printf 'glm53-spark-%s-rank%s\n' "$1" "$2"
}

container_state_of() {
  local state_alias=$1
  local state_name=$2
  local state_file="${fake_containers}/${state_alias}/${state_name}"
  [ -f "${state_file}" ] || {
    printf 'absent\n'
    return 0
  }
  awk -F= '$1 == "state" {print $2}' "${state_file}"
}

container_id_of() {
  awk -F= '$1 == "id" {print $2}' "${fake_containers}/$1/$2"
}

set_container_id() {
  local rewrite_file="${fake_containers}/$1/$2"
  local rewrite_id=$3
  python3 - "${rewrite_file}" "${rewrite_id}" <<'REWRITE_EOF'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
lines = [
    f"id={sys.argv[2]}" if line.startswith("id=") else line
    for line in path.read_text(encoding="utf-8").splitlines()
]
path.write_text("\n".join(lines) + "\n", encoding="utf-8")
REWRITE_EOF
}

set_container_owner() {
  local rewrite_file="${fake_containers}/$1/$2"
  local rewrite_owner=$3
  python3 - "${rewrite_file}" "${rewrite_owner}" <<'REWRITE_EOF'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
lines = [
    f"owner={sys.argv[2]}" if line.startswith("owner=") else line
    for line in path.read_text(encoding="utf-8").splitlines()
]
path.write_text("\n".join(lines) + "\n", encoding="utf-8")
REWRITE_EOF
}

log_line_number() {
  awk -v pattern="$1" 'index($0, pattern) > 0 {print NR; exit}' "${ssh_log}"
}

count_log_lines() {
  local count_pattern=$1
  [ -e "${ssh_log}" ] || {
    printf '0\n'
    return 0
  }
  awk -v pattern="${count_pattern}" \
    'index($0, pattern) == 1 {total = total + 1} END {print total + 0}' \
    "${ssh_log}"
}

# ---------------------------------------------------------------------------
# Exact listening-port matching
# ---------------------------------------------------------------------------

_lifecycle_load_contract "${test_config}" "${LOCK_PATH}" ||
  fail "the lifecycle contract could not be loaded"

if ! _lifecycle_ports_free ""; then
  fail "an empty listener table was treated as an occupied port"
fi
if ! _lifecycle_ports_free "$(
  printf '%s\n' \
    'LISTEN 0      4096       192.0.2.10:80020      0.0.0.0:*' \
    'LISTEN 0      4096       192.0.2.10:18002      0.0.0.0:*' \
    'LISTEN 0      4096       192.0.2.10:8003       0.0.0.0:*' \
    'LISTEN 0      4096            [::]:296000           [::]:*'
)"; then
  fail "a near-miss listening port was treated as the configured port"
fi
if _lifecycle_ports_free \
  'LISTEN 0      4096       192.0.2.10:8002       0.0.0.0:*'; then
  fail "an occupied IPv4 API port was reported free"
fi
if _lifecycle_ports_free \
  'LISTEN 0      4096            [::]:8002            [::]:*'; then
  fail "an occupied IPv6 API port was reported free"
fi
if _lifecycle_ports_free \
  'LISTEN 0      4096                *:29600               *:*'; then
  fail "an occupied wildcard distributed port was reported free"
fi
pass "listening-port matching is exact for IPv4, IPv6, and wildcard sockets"

# ---------------------------------------------------------------------------
# Deterministic, pinned, plan-only launch planning
# ---------------------------------------------------------------------------

first_plan="$(lifecycle_plan launch "${RUN_ID}")"
second_plan="$(lifecycle_plan launch "${RUN_ID}")"
[ "${first_plan}" = "${second_plan}" ] ||
  fail "launch plan is not deterministic"
[ ! -e "${ssh_log}" ] || fail "plan-only launch contacted a remote node"
[ ! -e "${doctor_log}" ] || fail "plan-only launch ran doctor"
[ ! -d "${state_root}" ] || fail "plan-only launch created run state"
assert_contains "${first_plan}" "PLAN:"
assert_contains "${first_plan}" "PLAN_SHA256:"
pass "launch plan is deterministic and mutation-free"

launch_plan_digest="$(plan_digest_of launch "${RUN_ID}")"
[ "${#launch_plan_digest}" -eq 64 ] || fail "launch plan digest is malformed"
case "${launch_plan_digest}" in
  *[!0-9a-f]*) fail "launch plan digest is not lowercase hexadecimal" ;;
esac

rank_index=0
while [ "${rank_index}" -lt 4 ]; do
  assert_contains "${first_plan}" "$(container_name_for "${RUN_ID}" "${rank_index}")"
  assert_contains "${first_plan}" "com.glm53-spark.rank=${rank_index}"
  assert_contains "${first_plan}" "node-rank ${rank_index}"
  rank_index=$((rank_index + 1))
done
assert_contains "${first_plan}" "com.glm53-spark.owner=glm53-spark"
assert_contains "${first_plan}" "com.glm53-spark.run-id=${RUN_ID}"
assert_contains "${first_plan}" "com.glm53-spark.profile=dflash-c4-128k-noradix"
assert_contains "${first_plan}" "io.glm53.owner"
assert_contains "${first_plan}" "glm53-dflash2-dgx-spark:${RUN_ID}"
assert_contains "${first_plan}" "192.0.2.10:29600"
assert_contains "${first_plan}" "tp-size 4"
assert_contains "${first_plan}" "nnodes 4"
assert_contains "${first_plan}" "context-length 131072"
assert_contains "${first_plan}" "max-running-requests 4"
assert_contains "${first_plan}" "mem-fraction-static 0.85"
assert_contains "${first_plan}" "speculative-algorithm DFLASH"
assert_contains "${first_plan}" "speculative-num-draft-tokens 8"
assert_contains "${first_plan}" "speculative-dflash-block-size 8"
assert_contains "${first_plan}" "speculative-draft-attention-backend fa4"
assert_contains "${first_plan}" "prefill-attention-backend tilelang"
assert_contains "${first_plan}" "decode-attention-backend tilelang"
assert_contains "${first_plan}" "kv-cache-dtype bfloat16"
assert_contains "${first_plan}" "disable-radix-cache"
assert_contains "${first_plan}" "${expected_model_path}"
assert_contains "${first_plan}" "models--incoai--GLM-5.3-Flash-DFlash2/snapshots/7d74cdd881ed7e32c31175984a67823127b66cfe"
assert_contains "${first_plan}" "/srv/glm53-package/.runtime/launch/${RUN_ID}/logs"
assert_contains "${first_plan}" "bounded-wait"
assert_contains "${first_plan}" "phase-one-complete"
assert_contains "${first_plan}" "phase-two-release"
assert_contains "${first_plan}" "plan-pinned-sha256"
assert_contains "${first_plan}" "lock-pinned-sha256"
assert_contains "${first_plan}" "get_model_info"
assert_contains "${first_plan}" "health_generate"
assert_contains "${first_plan}" "expect-served-model ${expected_served_name}"
assert_contains \
  "${first_plan}" \
  "lib/lifecycle.sh $(digest_of "${ROOT_DIR}/lib/lifecycle.sh")"
assert_contains \
  "${first_plan}" \
  "tools/config_state.py $(digest_of "${ROOT_DIR}/tools/config_state.py")"
pass "launch plan pins ranks, identities, ownership labels, and bytes"

for forbidden_plan_text in \
  "docker rm" \
  "image rm" \
  "rm -rf" \
  "rm -f" \
  sudo \
  apt-get \
  accept-new \
  "StrictHostKeyChecking=no" \
  TOKEN \
  "token=" \
  Bearer; do
  assert_not_contains "${first_plan}" "${forbidden_plan_text}"
done
pass "launch plan contains no destructive, privileged, or secret text"

stale_plan_digest="$(plan_digest_of launch "${HEALTH_RUN_ID}")"
[ "${stale_plan_digest}" != "${launch_plan_digest}" ] ||
  fail "launch plan digest ignores the run identity"
pass "each run identity produces a distinct launch plan digest"

# ---------------------------------------------------------------------------
# Apply gates
# ---------------------------------------------------------------------------

_GLM53_PLAN_DIGEST="${launch_plan_digest}"
if lifecycle_launch "${RUN_ID}" >/dev/null 2>&1; then
  fail "launch mutated without explicit --apply"
fi
[ ! -e "${ssh_log}" ] || fail "launch without --apply contacted a remote node"
[ ! -e "${doctor_log}" ] || fail "launch without --apply ran doctor"
pass "launch refuses to mutate without explicit apply consent"

_GLM53_APPLY=1
_GLM53_PLAN_DIGEST=0000000000000000000000000000000000000000000000000000000000000000
if lifecycle_launch "${RUN_ID}" >/dev/null 2>&1; then
  fail "launch accepted a stale plan digest"
fi
[ ! -e "${ssh_log}" ] || fail "stale plan digest contacted a remote node"
[ ! -e "${doctor_log}" ] || fail "stale plan digest reached doctor"
pass "stale launch plan digest fails closed before doctor"

_GLM53_PLAN_DIGEST="${launch_plan_digest}"
if lifecycle_launch ../escape >/dev/null 2>&1; then
  fail "launch accepted a path-unsafe run identity"
fi
[ ! -e "${ssh_log}" ] || fail "path-unsafe run identity contacted a remote node"
pass "launch rejects path-unsafe run identities"

# ---------------------------------------------------------------------------
# An occupied port fails closed before any phase-one mutation
# ---------------------------------------------------------------------------

occupied_port_launch() {
  local occupied_run_id=$1
  local occupied_mode=$2
  rm -f "${ssh_log}"
  _GLM53_PLAN_DIGEST="$(plan_digest_of launch "${occupied_run_id}")"
  if GLM53_FAKE_SS_MODE="${occupied_mode}" \
    GLM53_FAKE_SS_BUSY_ALIAS=glm53-node-d \
    lifecycle_launch "${occupied_run_id}" >/dev/null 2>&1; then
    fail "launch proceeded while ${occupied_mode} held the API port"
  fi
  [ "$(count_log_lines STOP)" -eq 0 ] ||
    fail "${occupied_mode} quiesced a service before rejecting the port"
  [ "$(count_log_lines RELEASE-START)" -eq 0 ] ||
    fail "${occupied_mode} released a rank while a port was occupied"
  [ "$(count_log_lines START)" -eq 0 ] ||
    fail "${occupied_mode} started a container while a port was occupied"
}

occupied_port_launch "${PORT4_RUN_ID}" ipv4-busy
occupied_port_launch "${PORT6_RUN_ID}" ipv6-busy
for prior_index in 0 1 2; do
  prior_alias="glm53-node-$(printf '%s' abc | cut -c "$((prior_index + 1))")"
  [ "$(
    container_state_of "${prior_alias}" "glm53-spark-prior-rank${prior_index}"
  )" = "running" ] ||
    fail "an occupied port disturbed pre-launch service ${prior_index}"
done
pass "IPv4 and IPv6 occupied ports fail closed before any mutation"

rm -f "${ssh_log}"
_GLM53_PLAN_DIGEST="$(plan_digest_of launch "${PORTFAIL_RUN_ID}")"
if GLM53_FAKE_SS_MODE=fail lifecycle_launch "${PORTFAIL_RUN_ID}" \
  >/dev/null 2>&1; then
  fail "launch proceeded while the listening socket probe failed"
fi
[ "$(count_log_lines STOP)" -eq 0 ] ||
  fail "a failed socket probe still quiesced a service"
[ "$(count_log_lines RELEASE-START)" -eq 0 ] ||
  fail "a failed socket probe still released a rank"
pass "a failed listening socket probe fails closed before any mutation"

# ---------------------------------------------------------------------------
# Successful two-phase launch
# ---------------------------------------------------------------------------

rm -f "${ssh_log}" "${doctor_log}"
_GLM53_PLAN_DIGEST="${launch_plan_digest}"
lifecycle_launch "${RUN_ID}" >/dev/null
[ -f "${doctor_log}" ] || fail "launch did not run a fresh doctor preflight"
[ "$(wc -l <"${doctor_log}" | tr -d ' ')" -eq 1 ] ||
  fail "launch did not run exactly one fresh doctor preflight"

release_start_line="$(log_line_number 'RELEASE-START')"
[ -n "${release_start_line}" ] || fail "launch never released a rank"
stage_lines="$(grep -c "command='mkdir'" "${ssh_log}" | tr -d ' ')"
[ "${stage_lines}" -eq 4 ] || fail "launch staged ${stage_lines} ranks, expected 4"
last_stage_line="$(
  awk "index(\$0, \"command='mkdir'\") > 0 {line = NR} END {print line}" \
    "${ssh_log}"
)"
[ "${last_stage_line}" -lt "${release_start_line}" ] ||
  fail "a rank was released before phase one finished on all four ranks"
phase_one_port_line="$(
  awk "index(\$0, \"command='ss'\") > 0 {line = NR} END {print line}" "${ssh_log}"
)"
[ -n "${phase_one_port_line}" ] || fail "phase one skipped the port check"
[ "${phase_one_port_line}" -lt "${release_start_line}" ] ||
  fail "port validation happened after a rank was released"
first_quiesce_line="$(log_line_number 'STOP ')"
first_port_line="$(
  awk "index(\$0, \"command='ss'\") > 0 {print NR; exit}" "${ssh_log}"
)"
[ "${first_port_line}" -lt "${first_quiesce_line}" ] ||
  fail "phase one quiesced a service before probing listening ports"
pass "phase one completes on all four ranks before any release"

connect_timeouts="$(
  awk -F'connect-timeout=' '/^INVOKE / {print $2}' "${ssh_log}" | sort -u
)"
[ "${connect_timeouts}" = "7" ] ||
  fail "lifecycle SSH used connect timeouts: ${connect_timeouts}, expected 7"
pass "every lifecycle SSH carries the configured connect timeout"

release_start_count="$(grep -c '^RELEASE-START ' "${ssh_log}" | tr -d ' ')"
release_end_count="$(grep -c '^RELEASE-END ' "${ssh_log}" | tr -d ' ')"
[ "${release_start_count}" -eq 4 ] ||
  fail "expected four rank releases, observed ${release_start_count}"
[ "${release_end_count}" -eq 4 ] ||
  fail "expected four completed releases, observed ${release_end_count}"
last_release_start="$(
  awk '/^RELEASE-START / {line = NR} END {print line}' "${ssh_log}"
)"
first_release_end="$(
  awk '/^RELEASE-END / {print NR; exit}' "${ssh_log}"
)"
[ "${last_release_start}" -lt "${first_release_end}" ] ||
  fail "rank releases were serialized instead of concurrent"
pass "all four rank releases are concurrent"

quiesce_stops="$(
  awk '/^STOP / {print $3}' "${ssh_log}" | sed 's/^name=//' | sort
)"
# Derived from the fixture so the owned pre-launch set stays single sourced as
# services are added to it.
expected_quiesce_stops="$(printf '%s\n' "${recorded_service_names}" | sort)"
[ "${quiesce_stops}" = "${expected_quiesce_stops}" ] ||
  fail "launch stopped services outside the recorded owned pre-launch set"
assert_not_contains "${quiesce_stops}" "${unowned_service_name}"
pass "launch quiesces only owner-labelled pre-launch services"

rank_index=0
while [ "${rank_index}" -lt 4 ]; do
  rank_alias="glm53-node-$(
    printf '%s' abcd | cut -c "$((rank_index + 1))"
  )"
  observed_state="$(
    container_state_of \
      "${rank_alias}" \
      "$(container_name_for "${RUN_ID}" "${rank_index}")"
  )"
  [ "${observed_state}" = "running" ] ||
    fail "rank ${rank_index} container state is ${observed_state}"
  [ -f "${state_root}/runs/${RUN_ID}/rank-${rank_index}.release.log" ] ||
    fail "rank ${rank_index} release log was not preserved"
  rank_index=$((rank_index + 1))
done
[ -f "${state_root}/runs/${RUN_ID}/run.json" ] ||
  fail "launch did not record run state"
[ -f "${state_root}/runs/${RUN_ID}/events.jsonl" ] ||
  fail "launch did not append run events"
pass "launch records run state, append-only events, and per-rank logs"

recorded_state="$(cat "${state_root}/runs/${RUN_ID}/run.json")"
assert_contains "${recorded_state}" "glm53-spark-prior-rank0"
assert_contains "${recorded_state}" "$(container_name_for "${RUN_ID}" 3)"
assert_contains "${recorded_state}" "glm53-dflash2-dgx-spark:${RUN_ID}"
assert_contains "${recorded_state}" "${prior_rank2_id}"
rank0_container_id="$(
  printf '%s' "$(container_name_for "${RUN_ID}" 0)" |
    shasum -a 256 | awk '{print $1}'
)"
assert_contains "${recorded_state}" "\"container_id\":\"${rank0_container_id}\""
assert_contains "${recorded_state}" "\"served_model_name\":\"${expected_served_name}\""
assert_contains "${recorded_state}" "\"model_path\":\"${expected_model_path}\""
assert_not_contains "${recorded_state}" "${unowned_service_name}"
recorded_events="$(cat "${state_root}/runs/${RUN_ID}/events.jsonl")"
assert_contains "${recorded_events}" "phase-one"
assert_contains "${recorded_events}" "phase-two"
assert_contains "${recorded_events}" "api-health"
event_sequences="$(
  python3 -c '
import json
import pathlib
import sys

lines = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
sequences = [json.loads(line)["sequence"] for line in lines if line]
print("ok" if sequences == list(range(1, len(sequences) + 1)) else "bad")
' "${state_root}/runs/${RUN_ID}/events.jsonl"
)"
[ "${event_sequences}" = "ok" ] ||
  fail "run events are not append-only with monotonic sequence numbers"
pass "recorded run state and events carry exact identities and ordering"

# ---------------------------------------------------------------------------
# Read-only status and logs bound to the recorded run
# ---------------------------------------------------------------------------

_GLM53_APPLY=0
status_output="$(lifecycle_status "${RUN_ID}")"
assert_contains "${status_output}" "${RUN_ID}"
assert_contains "${status_output}" "rank 3"
assert_contains "${status_output}" "endpoint: 192.0.2.10:8002"
assert_contains "${status_output}" "served-model: ${expected_served_name}"
assert_contains "${status_output}" "contract: matches-current"
assert_contains "${status_output}" "api: serving-this-run"
assert_not_contains "${status_output}" "Bearer"
pass "status reports a healthy run and exits zero"

# A container recreated with the same name and copied lifecycle labels must
# never be stopped: only the exact immutable ID recorded at release is mutable.
rm -f "${ssh_log}"
set_container_id \
  glm53-node-a \
  "$(container_name_for "${RUN_ID}" 0)" \
  "$(printf '%s' copied-run-labels | shasum -a 256 | awk '{print $1}')"
_GLM53_APPLY=1
_GLM53_PLAN_DIGEST="$(plan_digest_of stop "${RUN_ID}")"
if lifecycle_stop "${RUN_ID}" >/dev/null 2>&1; then
  fail "stop accepted a same-name container with copied lifecycle labels"
fi
[ "$(count_log_lines STOP)" -eq 0 ] ||
  fail "stop addressed a same-name replacement instead of failing closed"
set_container_id \
  glm53-node-a \
  "$(container_name_for "${RUN_ID}" 0)" \
  "${rank0_container_id}"
_GLM53_APPLY=0
pass "stop rejects a same-name container with copied lifecycle labels"

for rejected_health in wrong-model wrong-served unrelated generate-fail fail; do
  set +e
  rejected_output="$(
    GLM53_FAKE_HEALTH="${rejected_health}" lifecycle_status "${RUN_ID}" 2>&1
  )"
  rejected_status=$?
  set -e
  [ "${rejected_status}" -ne 0 ] ||
    fail "status accepted a ${rejected_health} serving identity"
  assert_contains "${rejected_output}" "api: not-serving-this-run"
done
pass "status rejects a wrong, missing, or unrelated served model identity"

_GLM53_CONFIG_PATH="${drifted_config}"
drifted_status_output="$(lifecycle_status "${RUN_ID}")"
assert_contains "${drifted_status_output}" "endpoint: 192.0.2.10:8002"
assert_contains "${drifted_status_output}" "contract: differs-from-current"
assert_contains "${drifted_status_output}" "api: serving-this-run"
assert_not_contains "${drifted_status_output}" "${drifted_api_port}"
pass "status probes the recorded endpoint even when the current config drifts"

rm -f "${ssh_log}"
_GLM53_APPLY=1
_GLM53_PLAN_DIGEST="$(plan_digest_of stop "${RUN_ID}")"
if lifecycle_stop "${RUN_ID}" >/dev/null 2>&1; then
  fail "stop proceeded while the recorded contract differs from the current one"
fi
[ "$(count_log_lines STOP)" -eq 0 ] ||
  fail "stop mutated a container despite recorded contract drift"
_GLM53_PLAN_DIGEST="$(plan_digest_of rollback "${RUN_ID}")"
if lifecycle_rollback "${RUN_ID}" >/dev/null 2>&1; then
  fail "rollback proceeded while the recorded contract differs"
fi
[ "$(count_log_lines STOP)" -eq 0 ] ||
  fail "rollback mutated a container despite recorded contract drift"
[ "$(count_log_lines START)" -eq 0 ] ||
  fail "rollback started a container despite recorded contract drift"
_GLM53_CONFIG_PATH="${test_config}"
_GLM53_APPLY=0
pass "recorded contract drift fails closed before any run mutation"

export GLM53_FAKE_LOG_SECRET=1
logs_output="$(lifecycle_logs "${RUN_ID}" 1)"
unset GLM53_FAKE_LOG_SECRET
assert_contains "${logs_output}" "sglang: all four ranks joined"
assert_not_contains "${logs_output}" "synthetic-value"
assert_contains "${logs_output}" "[redacted]"
pass "logs are read-only and redacted"

if lifecycle_logs "${RUN_ID}" 9 >/dev/null 2>&1; then
  fail "logs accepted an out-of-range rank"
fi
pass "logs reject an out-of-range rank"

# ---------------------------------------------------------------------------
# Owned stop
# ---------------------------------------------------------------------------

rm -f "${ssh_log}"
stop_plan="$(lifecycle_plan stop "${RUN_ID}")"
assert_contains "${stop_plan}" "$(container_name_for "${RUN_ID}" 0)"
assert_contains "${stop_plan}" "verify-ownership"
assert_contains "${stop_plan}" "expect-id ${rank0_container_id}"
assert_contains "${stop_plan}" "recorded-config-digest"
assert_contains "${stop_plan}" "recorded-lock-digest"
assert_not_contains "${stop_plan}" "docker rm"
[ ! -e "${ssh_log}" ] || fail "stop planning contacted a remote node"
stop_plan_digest="$(plan_digest_of stop "${RUN_ID}")"

_GLM53_APPLY=1
_GLM53_PLAN_DIGEST="${stop_plan_digest}"
lifecycle_stop "${RUN_ID}" >/dev/null
stopped_names="$(
  awk '/^STOP / {print $3}' "${ssh_log}" | sed 's/^name=//' | sort
)"
expected_stopped_names="$(
  rank_index=0
  while [ "${rank_index}" -lt 4 ]; do
    container_name_for "${RUN_ID}" "${rank_index}"
    rank_index=$((rank_index + 1))
  done | sort
)"
[ "${stopped_names}" = "${expected_stopped_names}" ] ||
  fail "stop touched containers outside the recorded run-owned set"
assert_not_contains "$(cat "${ssh_log}")" "'rm'"
pass "stop touches exactly the recorded run-owned containers"

# ---------------------------------------------------------------------------
# Rollback restores the recorded pre-launch service state
# ---------------------------------------------------------------------------

rm -f "${ssh_log}"
rollback_plan="$(lifecycle_plan rollback "${RUN_ID}")"
assert_contains "${rollback_plan}" "glm53-spark-prior-rank2"
assert_contains "${rollback_plan}" "restore-prelaunch-service"
assert_contains "${rollback_plan}" "expect-id ${prior_rank2_id}"
assert_not_contains "${rollback_plan}" "docker rm"
assert_not_contains "${rollback_plan}" "rm -rf"
rollback_plan_digest="$(plan_digest_of rollback "${RUN_ID}")"
[ ! -e "${ssh_log}" ] || fail "rollback planning contacted a remote node"

_GLM53_PLAN_DIGEST="${rollback_plan_digest}"
lifecycle_rollback "${RUN_ID}" >/dev/null
started_names="$(
  awk '/^START / {print $3}' "${ssh_log}" | sed 's/^name=//' | sort
)"
[ "${started_names}" = "${expected_quiesce_stops}" ] ||
  fail "rollback restored a service outside the recorded pre-launch set"
for prior_index in 0 1 2; do
  prior_alias="glm53-node-$(printf '%s' abc | cut -c "$((prior_index + 1))")"
  prior_state="$(
    container_state_of "${prior_alias}" "glm53-spark-prior-rank${prior_index}"
  )"
  [ "${prior_state}" = "running" ] ||
    fail "rollback left prior service ${prior_index} in state ${prior_state}"
done
[ "$(container_state_of glm53-node-a "$(container_name_for "${RUN_ID}" 0)")" \
  = "exited" ] || fail "rollback left a run-owned container running"
[ "$(container_state_of glm53-node-a "${unowned_service_name}")" = "running" ] ||
  fail "rollback disturbed an unowned service"
[ -f "${state_root}/runs/${RUN_ID}/run.json" ] ||
  fail "rollback deleted the recorded run state"
assert_not_contains "$(cat "${ssh_log}")" "'rm'"
pass "rollback restores only recorded pre-launch services and deletes nothing"

# ---------------------------------------------------------------------------
# A replaced pre-launch container is never restored
# ---------------------------------------------------------------------------

rm -f "${ssh_log}"
set_container_id "${replacement_alias}" "${replacement_name}" "${replacement_id}"
python3 - "${fake_containers}/${replacement_alias}/${replacement_name}" \
  <<'EXIT_EOF'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
lines = [
    "state=exited" if line.startswith("state=") else line
    for line in path.read_text(encoding="utf-8").splitlines()
]
path.write_text("\n".join(lines) + "\n", encoding="utf-8")
EXIT_EOF
_GLM53_PLAN_DIGEST="$(plan_digest_of rollback "${RUN_ID}")"
if lifecycle_rollback "${RUN_ID}" >/dev/null 2>&1; then
  fail "rollback restored a replaced pre-launch container"
fi
[ "$(count_log_lines START)" -eq 0 ] ||
  fail "rollback started a container whose identity no longer matches"
[ "$(
  container_state_of "${replacement_alias}" "${replacement_name}"
)" = "exited" ] || fail "the replaced pre-launch container was started"
set_container_id "${replacement_alias}" "${replacement_name}" "${prior_rank2_id}"
pass "a same-name, same-owner replacement container is never restored"

rm -f "${ssh_log}"
_GLM53_PLAN_DIGEST="$(plan_digest_of rollback "${RUN_ID}")"
lifecycle_rollback "${RUN_ID}" >/dev/null
[ "$(
  container_state_of "${replacement_alias}" "${replacement_name}"
)" = "running" ] || fail "rollback did not restore the recorded container"
pass "rollback restores a pre-launch container whose exact identity matches"

# Classification and start are separate remote calls. A replacement that
# arrives after classification must not be started by its recorded name.
python3 - "${fake_containers}/${replacement_alias}/${replacement_name}" \
  <<'EXIT_EOF'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
lines = [
    "state=exited" if line.startswith("state=") else line
    for line in path.read_text(encoding="utf-8").splitlines()
]
path.write_text("\n".join(lines) + "\n", encoding="utf-8")
EXIT_EOF
rm -f "${ssh_log}"
_GLM53_PLAN_DIGEST="$(plan_digest_of rollback "${RUN_ID}")"
if GLM53_FAKE_SWAP_AFTER_SERVICE_INSPECT="${replacement_name}" \
  lifecycle_rollback "${RUN_ID}" >/dev/null 2>&1; then
  fail "rollback started a service replaced after identity classification"
fi
assert_not_contains \
  "$(cat "${ssh_log}")" \
  "START alias=${replacement_alias} name=${replacement_name}"
[ "$(container_state_of "${replacement_alias}" "${replacement_name}")" = "exited" ] ||
  fail "rollback started a replacement after identity classification"
set_container_id "${replacement_alias}" "${replacement_name}" "${prior_rank2_id}"
_GLM53_PLAN_DIGEST="$(plan_digest_of rollback "${RUN_ID}")"
lifecycle_rollback "${RUN_ID}" >/dev/null
pass "rollback addresses immutable service IDs after identity classification"

_GLM53_APPLY=0
if lifecycle_status "${RUN_ID}" >/dev/null 2>&1; then
  fail "status reported success for a rolled-back run"
fi
pass "status fails after rollback without mutating anything"

# ---------------------------------------------------------------------------
# Bounded readiness waits fail closed
# ---------------------------------------------------------------------------

rm -f "${ssh_log}"
_GLM53_APPLY=1
_GLM53_PLAN_DIGEST="$(plan_digest_of launch "${HEALTH_RUN_ID}")"
if GLM53_FAKE_HEALTH=fail lifecycle_launch "${HEALTH_RUN_ID}" >/dev/null 2>&1; then
  fail "launch succeeded while the direct API never became healthy"
fi
health_stopped="$(
  awk '/^STOP / {print $3}' "${ssh_log}" | sed 's/^name=//' | sort -u
)"
rank_index=0
while [ "${rank_index}" -lt 4 ]; do
  assert_contains \
    "${health_stopped}" \
    "$(container_name_for "${HEALTH_RUN_ID}" "${rank_index}")"
  rank_index=$((rank_index + 1))
done
health_started="$(
  awk '/^START / {print $3}' "${ssh_log}" | sed 's/^name=//' | sort
)"
[ "${health_started}" = "${expected_quiesce_stops}" ] ||
  fail "unhealthy launch did not restore exactly the recorded pre-launch state"
assert_not_contains "$(cat "${ssh_log}")" "'rm'"
pass "an unhealthy direct API stops only run-owned containers and rolls back"

# ---------------------------------------------------------------------------
# Early rank failure
# ---------------------------------------------------------------------------

rm -f "${ssh_log}"
_GLM53_PLAN_DIGEST="$(plan_digest_of launch "${FAIL_RUN_ID}")"
if GLM53_FAKE_FAIL_RANK="${failing_rank}" \
  GLM53_FAKE_FAIL_PHASE="${failing_phase}" \
  GLM53_FAKE_FAIL_EXIT="${failing_exit_code}" \
  lifecycle_launch "${FAIL_RUN_ID}" >/dev/null 2>&1; then
  fail "launch succeeded while rank ${failing_rank} failed to release"
fi
failure_stopped="$(
  awk '/^STOP / {print $3}' "${ssh_log}" | sed 's/^name=//' | sort -u
)"
for surviving_rank in 0 1 3; do
  assert_contains \
    "${failure_stopped}" \
    "$(container_name_for "${FAIL_RUN_ID}" "${surviving_rank}")"
done
assert_not_contains \
  "${failure_stopped}" \
  "$(container_name_for "${FAIL_RUN_ID}" "${failing_rank}")"
assert_not_contains "${failure_stopped}" "${unowned_service_name}"
failure_started="$(
  awk '/^START / {print $3}' "${ssh_log}" | sed 's/^name=//' | sort
)"
[ "${failure_started}" = "${expected_quiesce_stops}" ] ||
  fail "failed launch did not restore exactly the recorded pre-launch state"
[ -f "${state_root}/runs/${FAIL_RUN_ID}/rank-${failing_rank}.release.log" ] ||
  fail "failed rank release evidence was deleted"
failure_events="$(cat "${state_root}/runs/${FAIL_RUN_ID}/events.jsonl")"
assert_contains "${failure_events}" "\"status\":\"failed\""
assert_not_contains "$(cat "${ssh_log}")" "'rm'"
pass "an early rank failure stops only run-owned containers and preserves evidence"

_GLM53_APPLY=0
set +e
missing_logs_output="$(lifecycle_logs "${FAIL_RUN_ID}" "${failing_rank}" 2>&1)"
missing_logs_status=$?
set -e
[ "${missing_logs_status}" -eq 1 ] ||
  fail "logs exited ${missing_logs_status} for an unreadable container"
assert_not_contains "${missing_logs_output}" "sglang"
pass "logs fail closed when the remote container cannot be read"
_GLM53_APPLY=1

# ---------------------------------------------------------------------------
# A run event that cannot be recorded aborts and restores
# ---------------------------------------------------------------------------

event_failure_launch() {
  local event_run_id=$1
  local event_fail_at=$2
  rm -f "${ssh_log}"
  printf '0\n' >"${event_counter}"
  _GLM53_PLAN_DIGEST="$(plan_digest_of launch "${event_run_id}")"
  if GLM53_FAKE_EVENT_FAIL_AT="${event_fail_at}" \
    lifecycle_launch "${event_run_id}" >/dev/null 2>&1; then
    fail "launch succeeded although run event ${event_fail_at} was unrecordable"
  fi
  [ -f "${state_root}/runs/${event_run_id}/event-failures.log" ] ||
    fail "run event failure ${event_fail_at} left no evidence"
  local event_started
  event_started="$(
    awk '/^START / {print $3}' "${ssh_log}" | sed 's/^name=//' | sort
  )"
  [ "${event_started}" = "${expected_quiesce_stops}" ] ||
    fail "event failure ${event_fail_at} did not restore the pre-launch state"
  local event_status
  event_status="$(
    python3 -c '
import json
import pathlib
import sys

print(json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))["status"])
' "${state_root}/runs/${event_run_id}/run.json"
  )"
  [ "${event_status}" = "failed" ] ||
    fail "event failure ${event_fail_at} left run status ${event_status}"
}

# Boundary one: the preparation sub-phase has already quiesced all four nodes,
# but no rank container exists yet.
event_failure_launch "${EVENT1_RUN_ID}" 9
# Boundary two: every rank container is already running.
event_failure_launch "${EVENT2_RUN_ID}" 15
rank_index=0
while [ "${rank_index}" -lt 4 ]; do
  rank_alias="glm53-node-$(printf '%s' abcd | cut -c "$((rank_index + 1))")"
  [ "$(
    container_state_of \
      "${rank_alias}" \
      "$(container_name_for "${EVENT2_RUN_ID}" "${rank_index}")"
  )" = "exited" ] ||
    fail "an unrecordable run event left rank ${rank_index} running"
  rank_index=$((rank_index + 1))
done
printf '0\n' >"${event_counter}"
pass "an unrecordable run event aborts, restores, and preserves evidence"

# ---------------------------------------------------------------------------
# Ownership drift fails closed
# ---------------------------------------------------------------------------

rm -f "${ssh_log}"
_GLM53_PLAN_DIGEST="$(plan_digest_of launch "${DRIFT_RUN_ID}")"
GLM53_FAKE_HEALTH=ok lifecycle_launch "${DRIFT_RUN_ID}" >/dev/null
drift_container="$(container_name_for "${DRIFT_RUN_ID}" 1)"
set_container_owner glm53-node-b "${drift_container}" unrelated-owner

rm -f "${ssh_log}"
_GLM53_PLAN_DIGEST="$(plan_digest_of stop "${DRIFT_RUN_ID}")"
if lifecycle_stop "${DRIFT_RUN_ID}" >/dev/null 2>&1; then
  fail "stop proceeded while a container with the run name was unowned"
fi
[ "$(count_log_lines STOP)" -eq 0 ] ||
  fail "stop mutated a container after detecting ownership drift"
pass "ownership drift fails closed before any stop action"

rm -f "${ssh_log}"
drift_run_digest="$(digest_of "${state_root}/runs/${DRIFT_RUN_ID}/run.json")"
drift_event_lines="$(
  wc -l <"${state_root}/runs/${DRIFT_RUN_ID}/events.jsonl" | tr -d ' '
)"
_GLM53_PLAN_DIGEST="$(plan_digest_of rollback "${DRIFT_RUN_ID}")"
if lifecycle_rollback "${DRIFT_RUN_ID}" >/dev/null 2>&1; then
  fail "rollback proceeded while a container with the run name was unowned"
fi
[ "$(count_log_lines STOP)" -eq 0 ] ||
  fail "rollback stopped a container after detecting ownership drift"
[ "$(count_log_lines START)" -eq 0 ] ||
  fail "rollback started a container after detecting ownership drift"
[ "$(digest_of "${state_root}/runs/${DRIFT_RUN_ID}/run.json")" \
  = "${drift_run_digest}" ] ||
  fail "rollback changed the recorded run state after detecting drift"
# The rejected rollback may record why it refused, but it must not record any
# stop or restore action, because it performed none.
drift_events="$(
  tail -n "+$((drift_event_lines + 1))" \
    "${state_root}/runs/${DRIFT_RUN_ID}/events.jsonl"
)"
assert_contains "${drift_events}" '"action":"detect-drift"'
assert_not_contains "${drift_events}" '"action":"stop-run-owned"'
assert_not_contains "${drift_events}" '"action":"restore-service"'
assert_not_contains "${drift_events}" '"status":"succeeded"'
rank_index=0
while [ "${rank_index}" -lt 4 ]; do
  rank_alias="glm53-node-$(printf '%s' abcd | cut -c "$((rank_index + 1))")"
  [ "$(
    container_state_of \
      "${rank_alias}" \
      "$(container_name_for "${DRIFT_RUN_ID}" "${rank_index}")"
  )" = "running" ] ||
    fail "rollback stopped rank ${rank_index} despite ownership drift"
  rank_index=$((rank_index + 1))
done
for prior_index in 0 1 2; do
  prior_alias="glm53-node-$(printf '%s' abc | cut -c "$((prior_index + 1))")"
  [ "$(
    container_state_of "${prior_alias}" "glm53-spark-prior-rank${prior_index}"
  )" = "exited" ] ||
    fail "rollback restored prior service ${prior_index} despite drift"
done
pass "rollback fails closed with zero mutations when ownership drifts"

rm -f "${ssh_log}"
set_container_owner glm53-node-b "${drift_container}" glm53-spark
_GLM53_PLAN_DIGEST="$(plan_digest_of rollback "${DRIFT_RUN_ID}")"
lifecycle_rollback "${DRIFT_RUN_ID}" >/dev/null
[ "$(count_log_lines START)" -eq "$(printf '%s\n' "${expected_quiesce_stops}" | wc -l | tr -d ' ')" ] ||
  fail "resolved-drift rollback did not restore all recorded services"
pass "rollback proceeds once the ownership drift is resolved"

# A repeated rollback must converge on the same state rather than drifting or
# failing, because an operator may retry after a partial outage.
rm -f "${ssh_log}"
_GLM53_PLAN_DIGEST="$(plan_digest_of rollback "${DRIFT_RUN_ID}")"
lifecycle_rollback "${DRIFT_RUN_ID}" >/dev/null ||
  fail "a repeated rollback did not succeed"
[ "$(count_log_lines START)" -eq 0 ] ||
  fail "a repeated rollback restarted an already-running recorded service"
rank_index=0
while [ "${rank_index}" -lt 4 ]; do
  rank_alias="glm53-node-$(printf '%s' abcd | cut -c "$((rank_index + 1))")"
  [ "$(
    container_state_of \
      "${rank_alias}" \
      "$(container_name_for "${DRIFT_RUN_ID}" "${rank_index}")"
  )" = "exited" ] ||
    fail "a repeated rollback left rank ${rank_index} running"
  rank_index=$((rank_index + 1))
done
for prior_index in 0 1 2; do
  prior_alias="glm53-node-$(printf '%s' abc | cut -c "$((prior_index + 1))")"
  [ "$(
    container_state_of "${prior_alias}" "glm53-spark-prior-rank${prior_index}"
  )" = "running" ] ||
    fail "a repeated rollback disturbed restored prior service ${prior_index}"
done
pass "rollback is idempotent and converges on the recorded pre-launch state"

# ---------------------------------------------------------------------------
# A pre-launch service replaced between recording and quiescing is not stopped
# ---------------------------------------------------------------------------

rm -f "${ssh_log}"
_GLM53_PLAN_DIGEST="$(plan_digest_of launch "${SWAP_RUN_ID}")"
if GLM53_FAKE_SWAP_AFTER_PS=glm53-spark-prior-rank0 \
  lifecycle_launch "${SWAP_RUN_ID}" >/dev/null 2>&1; then
  fail "launch quiesced a replaced pre-launch service"
fi
assert_not_contains "$(cat "${ssh_log}")" "STOP alias=glm53-node-a name=glm53-spark-prior-rank0"
[ "$(container_state_of glm53-node-a glm53-spark-prior-rank0)" = "running" ] ||
  fail "a replaced pre-launch service was stopped during quiesce"
pass "quiesce refuses a same-name replacement and never stops it"

# Inspect can succeed and a replacement can still arrive immediately before
# the mutating stop. Addressing the recorded ID must leave it untouched.
rm -f "${ssh_log}"
_GLM53_PLAN_DIGEST="$(plan_digest_of launch "${MIDDRIFT_RUN_ID}")"
if GLM53_FAKE_SWAP_AFTER_SERVICE_INSPECT=glm53-spark-prior-rank0 \
  lifecycle_launch "${MIDDRIFT_RUN_ID}" >/dev/null 2>&1; then
  fail "launch quiesced a service replaced after its identity inspection"
fi
assert_not_contains \
  "$(cat "${ssh_log}")" \
  "STOP alias=glm53-node-a name=glm53-spark-prior-rank0"
[ "$(container_state_of glm53-node-a glm53-spark-prior-rank0)" = "running" ] ||
  fail "quiesce stopped a replacement after identity inspection"
pass "quiesce addresses immutable service IDs after identity inspection"

# ---------------------------------------------------------------------------
# An operator rollback classifies every recorded service before mutating
# ---------------------------------------------------------------------------

rm -f "${ssh_log}"
_GLM53_PLAN_DIGEST="$(plan_digest_of launch "${MIDDRIFT_RUN_ID}")"
lifecycle_launch "${MIDDRIFT_RUN_ID}" >/dev/null
middrift_original_id="$(
  container_id_of "${middle_drift_alias}" "${middle_drift_name}"
)"
set_container_id "${middle_drift_alias}" "${middle_drift_name}" \
  "${middle_drift_id}"

rm -f "${ssh_log}"
middrift_run_digest="$(digest_of "${state_root}/runs/${MIDDRIFT_RUN_ID}/run.json")"
_GLM53_PLAN_DIGEST="$(plan_digest_of rollback "${MIDDRIFT_RUN_ID}")"
if lifecycle_rollback "${MIDDRIFT_RUN_ID}" >/dev/null 2>&1; then
  fail "rollback proceeded while a recorded service identity had drifted"
fi
[ "$(count_log_lines STOP)" -eq 0 ] ||
  fail "rollback stopped a rank before classifying every recorded service"
[ "$(count_log_lines START)" -eq 0 ] ||
  fail "rollback started a service before classifying every recorded service"
[ "$(digest_of "${state_root}/runs/${MIDDRIFT_RUN_ID}/run.json")" \
  = "${middrift_run_digest}" ] ||
  fail "a rejected rollback changed the recorded run state"
rank_index=0
while [ "${rank_index}" -lt 4 ]; do
  rank_alias="glm53-node-$(printf '%s' abcd | cut -c "$((rank_index + 1))")"
  [ "$(
    container_state_of \
      "${rank_alias}" \
      "$(container_name_for "${MIDDRIFT_RUN_ID}" "${rank_index}")"
  )" = "running" ] ||
    fail "a rejected rollback stopped rank ${rank_index}"
  rank_index=$((rank_index + 1))
done
pass "a mid-list service identity drift rejects rollback with zero mutations"

# The rejection must be stable, not a one-shot that leaves a half-applied state
# behind for the next attempt to trip over.
rm -f "${ssh_log}"
_GLM53_PLAN_DIGEST="$(plan_digest_of rollback "${MIDDRIFT_RUN_ID}")"
if lifecycle_rollback "${MIDDRIFT_RUN_ID}" >/dev/null 2>&1; then
  fail "a retried rollback proceeded despite unresolved identity drift"
fi
[ "$(count_log_lines STOP)" -eq 0 ] ||
  fail "a retried rollback stopped a rank despite unresolved drift"
[ "$(count_log_lines START)" -eq 0 ] ||
  fail "a retried rollback started a service despite unresolved drift"
pass "a rejected rollback fails closed consistently when retried"

rm -f "${ssh_log}"
set_container_id "${middle_drift_alias}" "${middle_drift_name}" \
  "${middrift_original_id}"
_GLM53_PLAN_DIGEST="$(plan_digest_of rollback "${MIDDRIFT_RUN_ID}")"
lifecycle_rollback "${MIDDRIFT_RUN_ID}" >/dev/null ||
  fail "rollback failed once the recorded service identity was restored"
middrift_started="$(
  awk '/^START / {print $3}' "${ssh_log}" | sed 's/^name=//' | sort
)"
[ "${middrift_started}" = "${expected_quiesce_stops}" ] ||
  fail "a resolved rollback did not restore every recorded service"
pass "rollback restores every recorded service once the drift is resolved"

# ---------------------------------------------------------------------------
# A launch abort converges: every safely proven service is restored
# ---------------------------------------------------------------------------

rm -f "${ssh_log}"
_GLM53_PLAN_DIGEST="$(plan_digest_of launch "${ABORT_RUN_ID}")"
if GLM53_FAKE_HEALTH=fail \
  GLM53_FAKE_SWAP_ON_RUN="${middle_drift_name}" \
  GLM53_FAKE_SWAP_ON_RUN_ALIAS="${middle_drift_alias}" \
  lifecycle_launch "${ABORT_RUN_ID}" >/dev/null 2>&1; then
  fail "launch succeeded although the direct API never served the run"
fi
abort_started="$(
  awk '/^START / {print $3}' "${ssh_log}" | sed 's/^name=//' | sort
)"
# Every safe service must be restored, including the two ordered after the
# drifted one, and the replacement must never be started.
[ "${abort_started}" = "${safe_service_names}" ] ||
  fail "abort restored ${abort_started} instead of the safe recorded services"
[ "$(container_state_of "${middle_drift_alias}" "${middle_drift_name}")" \
  = "exited" ] ||
  fail "abort started a replacement carrying a recorded service name"
rank_index=0
while [ "${rank_index}" -lt 4 ]; do
  rank_alias="glm53-node-$(printf '%s' abcd | cut -c "$((rank_index + 1))")"
  [ "$(
    container_state_of \
      "${rank_alias}" \
      "$(container_name_for "${ABORT_RUN_ID}" "${rank_index}")"
  )" = "exited" ] ||
    fail "abort left rank ${rank_index} running"
  rank_index=$((rank_index + 1))
done
abort_events="$(cat "${state_root}/runs/${ABORT_RUN_ID}/events.jsonl")"
assert_contains "${abort_events}" '"action":"restore-service"'
assert_contains "${abort_events}" '"action":"detect-service-drift"'
abort_status="$(
  python3 -c '
import json
import pathlib
import sys

print(json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))["status"])
' "${state_root}/runs/${ABORT_RUN_ID}/run.json"
)"
[ "${abort_status}" = "failed" ] ||
  fail "abort left run status ${abort_status}"
pass "abort restores every safe service, skips the drifted one, and reports it"

# Restore the fixture identity so later tests see the recorded pre-launch set.
set_container_id "${middle_drift_alias}" "${middle_drift_name}" \
  "${middrift_original_id}"

# ---------------------------------------------------------------------------
# A node that cannot be classified never counts as absent
# ---------------------------------------------------------------------------

transport_run_state() {
  python3 -c '
import json
import pathlib
import sys

print(json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))["status"])
' "${state_root}/runs/${TRANSPORT_RUN_ID}/run.json"
}

# The run is launched under the short command timeout so a hung classification
# can be proven bounded without a slow test. The recorded contract must match
# the configuration in force at mutation time, so both use the same file.
_GLM53_CONFIG_PATH="${timeout_config}"
rm -f "${ssh_log}"
_GLM53_PLAN_DIGEST="$(plan_digest_of launch "${TRANSPORT_RUN_ID}")"
lifecycle_launch "${TRANSPORT_RUN_ID}" >/dev/null
[ "$(transport_run_state)" = "ready" ] ||
  fail "the transport fixture run did not reach the ready state"

for transport_command in stop rollback; do
  for transport_fault in down hang; do
    rm -f "${ssh_log}"
    transport_digest="$(
      digest_of "${state_root}/runs/${TRANSPORT_RUN_ID}/run.json"
    )"
    _GLM53_PLAN_DIGEST="$(
      plan_digest_of "${transport_command}" "${TRANSPORT_RUN_ID}"
    )"
    set +e
    if [ "${transport_fault}" = "down" ]; then
      GLM53_FAKE_SSH_DOWN_ALIAS=glm53-node-c \
        "lifecycle_${transport_command}" "${TRANSPORT_RUN_ID}" >/dev/null 2>&1
    else
      GLM53_FAKE_HANG_ALIAS=glm53-node-d \
        "lifecycle_${transport_command}" "${TRANSPORT_RUN_ID}" >/dev/null 2>&1
    fi
    transport_status=$?
    set -e
    [ "${transport_status}" -eq 1 ] ||
      fail "${transport_command} exited ${transport_status} on a ${transport_fault} node"
    [ "$(count_log_lines STOP)" -eq 0 ] ||
      fail "${transport_command} stopped a container with a ${transport_fault} node"
    [ "$(count_log_lines START)" -eq 0 ] ||
      fail "${transport_command} started a container with a ${transport_fault} node"
    [ "$(digest_of "${state_root}/runs/${TRANSPORT_RUN_ID}/run.json")" \
      = "${transport_digest}" ] ||
      fail "${transport_command} changed run state with a ${transport_fault} node"
    [ "$(transport_run_state)" = "ready" ] ||
      fail "${transport_command} transitioned run status with a ${transport_fault} node"
  done
done
rank_index=0
while [ "${rank_index}" -lt 4 ]; do
  rank_alias="glm53-node-$(printf '%s' abcd | cut -c "$((rank_index + 1))")"
  [ "$(
    container_state_of \
      "${rank_alias}" \
      "$(container_name_for "${TRANSPORT_RUN_ID}" "${rank_index}")"
  )" = "running" ] ||
    fail "an unclassifiable node left rank ${rank_index} orphaned"
  rank_index=$((rank_index + 1))
done
pass "an unclassifiable node fails stop and rollback closed with zero mutations"

rm -f "${ssh_log}"
_GLM53_PLAN_DIGEST="$(plan_digest_of rollback "${TRANSPORT_RUN_ID}")"
lifecycle_rollback "${TRANSPORT_RUN_ID}" >/dev/null ||
  fail "rollback failed once every node was reachable again"
[ "$(transport_run_state)" = "rolled-back" ] ||
  fail "a recovered rollback did not record the rolled-back status"
pass "rollback converges once every node can be classified again"
_GLM53_CONFIG_PATH="${test_config}"

# ---------------------------------------------------------------------------
# Classification runs under the production errexit context
# ---------------------------------------------------------------------------

# An abort classifies ranks whose container was never created, so the probe
# reports a proven-absent container. Under `set -e` an unguarded status capture
# would terminate the abort before it stopped anything or restored anything.
rm -f "${ssh_log}"
_GLM53_APPLY=1
_GLM53_PLAN_DIGEST="$(plan_digest_of launch "${ERREXIT_ABORT_RUN_ID}")"
errexit_status="$(
  GLM53_FAKE_FAIL_PHASE="${failing_phase}" \
    GLM53_FAKE_FAIL_RANK="${failing_rank}" \
    GLM53_FAKE_FAIL_EXIT="${failing_exit_code}" \
    errexit_call lifecycle_launch "${ERREXIT_ABORT_RUN_ID}"
)"
[ "${errexit_status}" -eq 1 ] ||
  fail "an aborted launch exited ${errexit_status} under production errexit"
assert_contains "$(cat "${temporary_root}/errexit.err")" "glm53-spark: error:"
errexit_started="$(
  awk '/^START / {print $3}' "${ssh_log}" | sed 's/^name=//' | sort
)"
# Every service this run quiesced must come back, so the expectation is derived
# from the quiesce actions of this same run rather than from fixture state that
# earlier drift scenarios may have left behind.
errexit_quiesced="$(
  awk '/^STOP / {print $3}' "${ssh_log}" | sed 's/^name=//' |
    grep -v "^glm53-spark-${ERREXIT_ABORT_RUN_ID}-rank" | sort -u
)"
[ -n "${errexit_quiesced}" ] ||
  fail "the abort fixture quiesced no pre-launch service to restore"
[ "${errexit_started}" = "${errexit_quiesced}" ] ||
  fail "an abort under errexit restored ${errexit_started} of ${errexit_quiesced}"
rank_index=0
while [ "${rank_index}" -lt 4 ]; do
  rank_alias="glm53-node-$(printf '%s' abcd | cut -c "$((rank_index + 1))")"
  errexit_state="$(
    container_state_of \
      "${rank_alias}" \
      "$(container_name_for "${ERREXIT_ABORT_RUN_ID}" "${rank_index}")"
  )"
  if [ "${rank_index}" = "${failing_rank}" ]; then
    [ "${errexit_state}" = "absent" ] ||
      fail "the failing rank container should never have been created"
  else
    [ "${errexit_state}" = "exited" ] ||
      fail "an abort under errexit left rank ${rank_index} orphaned"
  fi
  rank_index=$((rank_index + 1))
done
errexit_run_status="$(
  python3 -c '
import json
import pathlib
import sys

print(json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))["status"])
' "${state_root}/runs/${ERREXIT_ABORT_RUN_ID}/run.json"
)"
[ "${errexit_run_status}" = "failed" ] ||
  fail "an abort under errexit left run status ${errexit_run_status}"
pass "an early launch failure completes the whole abort under production errexit"

# A recorded service removed after the launch makes the service probe report a
# proven-absent container during an operator rollback.
rm -f "${ssh_log}"
_GLM53_PLAN_DIGEST="$(plan_digest_of launch "${ERREXIT_GONE_RUN_ID}")"
errexit_status="$(errexit_call lifecycle_launch "${ERREXIT_GONE_RUN_ID}")"
[ "${errexit_status}" -eq 0 ] ||
  fail "the removed-service fixture launch exited ${errexit_status}"
# The recorded service is read back from the run record itself, so the removal
# is guaranteed to hit a service this run actually recorded.
gone_service="$(
  python3 -c '
import json
import pathlib
import sys

run = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))["data"]
for rank in run["ranks"]:
    for service in rank["prelaunch_services"]:
        print(rank["ssh_alias"], service["name"])
        raise SystemExit(0)
raise SystemExit("the launch recorded no pre-launch service")
' "${state_root}/runs/${ERREXIT_GONE_RUN_ID}/run.json"
)"
gone_alias=${gone_service% *}
gone_name=${gone_service#* }
rm -f "${fake_containers}/${gone_alias}/${gone_name}"

rm -f "${ssh_log}"
errexit_run_digest="$(
  digest_of "${state_root}/runs/${ERREXIT_GONE_RUN_ID}/run.json"
)"
_GLM53_PLAN_DIGEST="$(plan_digest_of rollback "${ERREXIT_GONE_RUN_ID}")"
errexit_status="$(errexit_call lifecycle_rollback "${ERREXIT_GONE_RUN_ID}")"
[ "${errexit_status}" -eq 1 ] ||
  fail "rollback exited ${errexit_status} for a removed recorded service"
assert_contains "$(cat "${temporary_root}/errexit.err")" "glm53-spark: error:"
[ "$(count_log_lines STOP)" -eq 0 ] ||
  fail "rollback stopped a rank although a recorded service was removed"
[ "$(count_log_lines START)" -eq 0 ] ||
  fail "rollback started a service although a recorded service was removed"
[ "$(digest_of "${state_root}/runs/${ERREXIT_GONE_RUN_ID}/run.json")" \
  = "${errexit_run_digest}" ] ||
  fail "a rejected rollback changed the recorded run state under errexit"
assert_contains \
  "$(cat "${state_root}/runs/${ERREXIT_GONE_RUN_ID}/events.jsonl")" \
  '"action":"detect-service-drift"'
pass "a removed recorded service rejects rollback with a stable exit under errexit"

# An unreachable node makes the rank probe report an unconsultable node.
rm -f "${ssh_log}"
_GLM53_PLAN_DIGEST="$(plan_digest_of stop "${ERREXIT_GONE_RUN_ID}")"
errexit_status="$(
  GLM53_FAKE_SSH_DOWN_ALIAS=glm53-node-c \
    errexit_call lifecycle_stop "${ERREXIT_GONE_RUN_ID}"
)"
[ "${errexit_status}" -eq 1 ] ||
  fail "stop exited ${errexit_status} for an unreachable node under errexit"
assert_contains "$(cat "${temporary_root}/errexit.err")" "glm53-spark: error:"
[ "$(count_log_lines STOP)" -eq 0 ] ||
  fail "stop mutated a container although a node was unreachable"
rank_index=0
while [ "${rank_index}" -lt 4 ]; do
  rank_alias="glm53-node-$(printf '%s' abcd | cut -c "$((rank_index + 1))")"
  [ "$(
    container_state_of \
      "${rank_alias}" \
      "$(container_name_for "${ERREXIT_GONE_RUN_ID}" "${rank_index}")"
  )" = "running" ] ||
    fail "an unreachable node orphaned rank ${rank_index} under errexit"
  rank_index=$((rank_index + 1))
done
pass "an unconsultable node fails stop closed with a stable exit under errexit"

# ---------------------------------------------------------------------------
# Every lifecycle SSH is bounded by the configured command timeout
# ---------------------------------------------------------------------------

rm -f "${ssh_log}"
_lifecycle_load_contract "${test_config}" "${LOCK_PATH}" ||
  fail "the lifecycle contract could not be reloaded"
_lifecycle_ssh_options || fail "the strict SSH option set could not be built"
_LIFECYCLE_COMMAND_TIMEOUT=1
timeout_started="$(date +%s)"
set +e
GLM53_FAKE_HANG_SECONDS=30 \
  _lifecycle_run_remote glm53-node-a test -d /srv >/dev/null 2>&1
timeout_status=$?
set -e
timeout_elapsed=$(($(date +%s) - timeout_started))
[ "${timeout_status}" -ne 0 ] ||
  fail "a hung remote command reported success"
[ "${timeout_elapsed}" -lt 10 ] ||
  fail "a hung remote command took ${timeout_elapsed}s despite a 1s bound"
pass "a hung remote command is bounded by the configured command timeout"

# A partial startup can race with an operator recreating an already-released
# rank. The abort must leave that copied-label replacement running because the
# recorded Docker ID no longer resolves to it.
rm -f "${ssh_log}"
_GLM53_APPLY=1
_GLM53_PLAN_DIGEST="$(plan_digest_of launch "${RANK_SWAP_ABORT_RUN_ID}")"
if GLM53_FAKE_FAIL_RANK="${failing_rank}" \
  GLM53_FAKE_FAIL_PHASE="${failing_phase}" \
  GLM53_FAKE_FAIL_EXIT="${failing_exit_code}" \
  GLM53_FAKE_SWAP_RANK_ON_RUN=0 \
  lifecycle_launch "${RANK_SWAP_ABORT_RUN_ID}" >/dev/null 2>&1; then
  fail "launch succeeded while a rank release failed after a rank replacement"
fi
rank_swap_name="$(container_name_for "${RANK_SWAP_ABORT_RUN_ID}" 0)"
[ "$(container_state_of glm53-node-a "${rank_swap_name}")" = "running" ] ||
  fail "abort stopped a same-name rank replacement with copied labels"
assert_not_contains \
  "$(cat "${ssh_log}")" \
  "STOP alias=glm53-node-a name=${rank_swap_name}"
rank_swap_events="$(cat "${state_root}/runs/${RANK_SWAP_ABORT_RUN_ID}/events.jsonl")"
assert_contains "${rank_swap_events}" '"action":"detect-drift"'
pass "a partial-startup abort never stops a same-name rank replacement"

# Docker can create a rank and print its immutable ID before SSH reports a
# transport failure. That valid receipt must still make the abort stop the
# exact container rather than leave it orphaned or infer an ID by name.
rm -f "${ssh_log}"
_GLM53_APPLY=1
_GLM53_PLAN_DIGEST="$(plan_digest_of launch "${RECEIPT_FAIL_RUN_ID}")"
if GLM53_FAKE_FAIL_RANK="${failing_rank}" \
  GLM53_FAKE_FAIL_PHASE="${failing_phase}" \
  GLM53_FAKE_FAIL_EXIT="${failing_exit_code}" \
  GLM53_FAKE_CREATE_THEN_FAIL_RANK="${failing_rank}" \
  lifecycle_launch "${RECEIPT_FAIL_RUN_ID}" >/dev/null 2>&1; then
  fail "launch succeeded after Docker printed an ID and SSH reported failure"
fi
receipt_fail_name="$(container_name_for "${RECEIPT_FAIL_RUN_ID}" "${failing_rank}")"
receipt_fail_id="$(printf '%s' "${receipt_fail_name}" | shasum -a 256 | awk '{print $1}')"
receipt_fail_alias="glm53-node-$(printf '%s' abcd | cut -c "$((failing_rank + 1))")"
[ "$(container_state_of "${receipt_fail_alias}" "${receipt_fail_name}")" = "exited" ] ||
  fail "abort left a rank created before SSH failure running"
assert_contains \
  "$(cat "${ssh_log}")" \
  "STOP alias=${receipt_fail_alias} name=${receipt_fail_name} id=${receipt_fail_id}"
assert_contains \
  "$(cat "${state_root}/runs/${RECEIPT_FAIL_RUN_ID}/run.json")" \
  "\"container_id\":\"${receipt_fail_id}\""
pass "abort stops a valid Docker ID receipt despite later SSH failure"

# A rank can be renamed without changing its immutable ID. The recorded-name
# contract must reject the drift before any stop, while the ID fallback proves
# it was not simply deleted.
rm -f "${ssh_log}"
_GLM53_PLAN_DIGEST="$(plan_digest_of launch "${RENAMED_RUN_ID}")"
lifecycle_launch "${RENAMED_RUN_ID}" >/dev/null
renamed_original="$(container_name_for "${RENAMED_RUN_ID}" 0)"
renamed_actual="${renamed_original}-renamed"
mv \
  "${fake_containers}/glm53-node-a/${renamed_original}" \
  "${fake_containers}/glm53-node-a/${renamed_actual}"
_GLM53_APPLY=0
if lifecycle_status "${RENAMED_RUN_ID}" >/dev/null 2>&1; then
  fail "status accepted a rank whose recorded name was replaced"
fi
rm -f "${ssh_log}"
_GLM53_APPLY=1
_GLM53_PLAN_DIGEST="$(plan_digest_of stop "${RENAMED_RUN_ID}")"
if lifecycle_stop "${RENAMED_RUN_ID}" >/dev/null 2>&1; then
  fail "stop accepted a rank whose recorded name had drifted"
fi
[ "$(count_log_lines STOP)" -eq 0 ] ||
  fail "stop mutated a cluster containing a renamed recorded rank"
rm -f "${ssh_log}"
_GLM53_PLAN_DIGEST="$(plan_digest_of rollback "${RENAMED_RUN_ID}")"
if lifecycle_rollback "${RENAMED_RUN_ID}" >/dev/null 2>&1; then
  fail "rollback accepted a rank whose recorded name had drifted"
fi
[ "$(count_log_lines STOP)" -eq 0 ] ||
  fail "rollback stopped a cluster containing a renamed recorded rank"
[ "$(count_log_lines START)" -eq 0 ] ||
  fail "rollback restored services while a recorded rank name had drifted"
rank_index=0
while [ "${rank_index}" -lt 4 ]; do
  rank_alias="glm53-node-$(printf '%s' abcd | cut -c "$((rank_index + 1))")"
  rank_name="$(container_name_for "${RENAMED_RUN_ID}" "${rank_index}")"
  if [ "${rank_index}" = 0 ]; then
    rank_name=${renamed_actual}
  fi
  [ "$(container_state_of "${rank_alias}" "${rank_name}")" = "running" ] ||
    fail "renamed-rank rejection changed rank ${rank_index}"
  rank_index=$((rank_index + 1))
done
pass "a renamed rank fails closed before any lifecycle mutation"

PATH=${original_path}

# ---------------------------------------------------------------------------
# CLI dispatch parity
# ---------------------------------------------------------------------------

cli_state_root="${temporary_root}/cli-state"
cli_plan="$(
  "${ROOT_DIR}/glm53-spark" \
    --config "${test_config}" \
    --lock "${LOCK_PATH}" \
    --state-root "${cli_state_root}" \
    launch \
    --run-id "${RUN_ID}"
)"
assert_contains "${cli_plan}" "PLAN_SHA256:"
assert_contains "${cli_plan}" "$(container_name_for "${RUN_ID}" 2)"
[ ! -d "${cli_state_root}" ] || fail "CLI launch plan created run state"
pass "CLI launch defaults to a non-mutating plan"

for read_only_command in status logs; do
  set +e
  read_only_output="$(
    "${ROOT_DIR}/glm53-spark" \
      --config "${test_config}" \
      --lock "${LOCK_PATH}" \
      --state-root "${state_root}" \
      --apply \
      "${read_only_command}" \
      --run-id "${RUN_ID}" 2>&1
  )"
  read_only_status=$?
  set -e
  [ "${read_only_status}" -eq 2 ] ||
    fail "${read_only_command} --apply exited ${read_only_status}, expected 2"
  assert_contains "${read_only_output}" "read-only"
done
pass "status and logs reject mutation flags with exit 2"

set +e
missing_digest_output="$(
  "${ROOT_DIR}/glm53-spark" \
    --config "${test_config}" \
    --lock "${LOCK_PATH}" \
    --state-root "${state_root}" \
    --apply \
    launch \
    --run-id "${RUN_ID}" 2>&1
)"
missing_digest_status=$?
set -e
[ "${missing_digest_status}" -eq 2 ] ||
  fail "launch --apply without --plan-digest exited ${missing_digest_status}"
assert_contains "${missing_digest_output}" "--plan-digest"
pass "launch --apply requires an explicit plan digest"

set +e
missing_run_output="$(
  "${ROOT_DIR}/glm53-spark" \
    --config "${test_config}" \
    --lock "${LOCK_PATH}" \
    --state-root "${cli_state_root}" \
    validate \
    --run-id "${RUN_ID}" 2>&1
)"
missing_run_status=$?
set -e
[ "${missing_run_status}" -eq 3 ] ||
  fail "validate missing run exited ${missing_run_status}, expected 3"
assert_contains "${missing_run_output}" "recorded run state is missing or unreadable"
pass "validate reports a missing recorded run ID"

printf 'Lifecycle contract passed.\n'

#!/usr/bin/env bash

set -eu

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT_DIR
cd "${ROOT_DIR}"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

pass() {
  printf 'PASS: %s\n' "$*"
}

assert_contains() {
  haystack=$1
  needle=$2
  message=$3
  case "${haystack}" in
    *"${needle}"*) ;;
    *) fail "${message}: expected '${needle}'" ;;
  esac
}

readonly CLI="${ROOT_DIR}/glm53-spark"
readonly BASE_CONFIG="${ROOT_DIR}/tests/fixtures/cluster.valid.json"
readonly LOCK="${ROOT_DIR}/config/reproduction.lock.json"
readonly HEALTHY_FIXTURE="${ROOT_DIR}/tests/fixtures/fabric/healthy.json"
readonly MISSING_LINK_FIXTURE="${ROOT_DIR}/tests/fixtures/fabric/missing-link.json"

temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/glm53-doctor.XXXXXX")"
cleanup() {
  rm -rf "${temporary_directory}"
}
trap cleanup EXIT HUP INT TERM

fake_bin="${temporary_directory}/bin"
doctor_bin="${temporary_directory}/doctor-bin"
mkdir "${fake_bin}" "${doctor_bin}"
known_hosts="${temporary_directory}/known hosts"
expanded_known_hosts="$(
  python3 -c 'import pathlib, sys; print(pathlib.Path(sys.argv[1]).expanduser())' \
    "${known_hosts}"
)"
config="${temporary_directory}/cluster.json"
ssh_log="${temporary_directory}/ssh.log"
mutation_log="${temporary_directory}/mutation.log"
real_python="$(command -v python3)"
for doctor_command in bash dirname; do
  doctor_command_path="$(command -v "${doctor_command}")"
  [ -n "${doctor_command_path}" ] ||
    fail "test host lacks required command: ${doctor_command}"
  ln -s "${doctor_command_path}" "${doctor_bin}/${doctor_command}"
done
doctor_path="${fake_bin}:${doctor_bin}"
: >"${known_hosts}"
: >"${ssh_log}"
: >"${mutation_log}"
chmod 0600 "${known_hosts}"

python3 - "${BASE_CONFIG}" "${config}" "${known_hosts}" <<'PY'
import json
import pathlib
import sys

source = pathlib.Path(sys.argv[1])
destination = pathlib.Path(sys.argv[2])
payload = json.loads(source.read_text(encoding="utf-8"))
payload["ssh"]["known_hosts_file"] = sys.argv[3]
destination.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
PY

cat >"${fake_bin}/ssh-keygen" <<'EOF'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >>"${FAKE_SSH_LOG:?}"
[ "$#" -eq 4 ] || exit 2
[ "$1" = "-F" ] || exit 2
[ "$3" = "-f" ] || exit 2
case "$2" in
  glm53-node-a|glm53-node-b|glm53-node-c|glm53-node-d) exit 0 ;;
  *) exit 1 ;;
esac
EOF

cat >"${fake_bin}/python3" <<'EOF'
#!/bin/sh
set -eu
if [ -n "${FAIL_FABRIC_COMMAND:-}" ]; then
  case " $* " in
    *"/fabric_probe.py ${FAIL_FABRIC_COMMAND} "*)
      printf '%s\n' "${FAKE_HELPER_SECRET:-helper failure}" >&2
      exit 91
      ;;
  esac
fi
exec "${REAL_PYTHON:?}" "$@"
EOF

cat >"${fake_bin}/ssh" <<'EOF'
#!/usr/bin/env bash
set -eu
alias_name=
for argument in "$@"; do
  printf 'arg=%s\n' "${argument}" >>"${FAKE_SSH_LOG:?}"
done
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o)
      shift 2
      ;;
    *)
      alias_name=$1
      shift
      break
      ;;
  esac
done
printf 'alias=%s\n' "${alias_name}" >>"${FAKE_SSH_LOG:?}"
if IFS= read -r unexpected_input; then
  printf 'stdin=attached:%s\n' "${unexpected_input}" >>"${FAKE_SSH_LOG:?}"
else
  printf 'stdin=detached\n' >>"${FAKE_SSH_LOG:?}"
fi
if [ "${FAKE_SSH_FAIL_ALIAS:-}" = "${alias_name}" ]; then
  printf '%s\n' "${FAKE_SSH_SECRET_MARKER:-remote failure}" >&2
  exit 9
fi
case "${alias_name}" in
  glm53-node-a) node_index=0 ;;
  glm53-node-b) node_index=1 ;;
  glm53-node-c) node_index=2 ;;
  glm53-node-d) node_index=3 ;;
  *) exit 8 ;;
esac
case "$*" in
  *"--mode reachability"*) probe_mode=reachability ;;
  *) probe_mode=node ;;
esac
python3 - "${FAKE_FABRIC_FIXTURE:?}" "${node_index}" "${probe_mode}" <<'PY'
import json
import pathlib
import sys

payload = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
node = payload["nodes"][int(sys.argv[2])]
if sys.argv[3] == "reachability":
    node = {
        "id": node["id"],
        "reachable_node_ids": node["reachable_node_ids"],
    }
else:
    node["reachable_node_ids"] = []
print(json.dumps(node, separators=(",", ":")))
PY
EOF

for mutating_tool in sudo apt apt-get dnf yum firewall-cmd; do
  cat >"${fake_bin}/${mutating_tool}" <<'EOF'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$0 $*" >>"${FAKE_MUTATION_LOG:?}"
exit 97
EOF
done
chmod 0700 "${fake_bin}/"*

doctor_environment() {
  env \
    "PATH=${doctor_path}" \
    "REAL_PYTHON=${real_python}" \
    "FAKE_SSH_LOG=${ssh_log}" \
    "FAKE_MUTATION_LOG=${mutation_log}" \
    "FAKE_FABRIC_FIXTURE=${FAKE_FABRIC_FIXTURE:-${HEALTHY_FIXTURE}}" \
    "FAKE_SSH_FAIL_ALIAS=${FAKE_SSH_FAIL_ALIAS:-}" \
    "FAKE_SSH_SECRET_MARKER=${FAKE_SSH_SECRET_MARKER:-}" \
    "FAIL_FABRIC_COMMAND=${FAIL_FABRIC_COMMAND:-}" \
    "FAKE_HELPER_SECRET=${FAKE_HELPER_SECRET:-}" \
    "$@"
}

ssh_options="$(
  bash -c \
    '. "$1"; _DOCTOR_CONNECT_TIMEOUT_SECONDS=7; doctor_ssh_options "$2"' \
    doctor-options \
    "${ROOT_DIR}/lib/doctor.sh" \
    "${known_hosts}"
)"
expected_ssh_options="$(printf '%s\n' \
  -o \
  BatchMode=yes \
  -o \
  StrictHostKeyChecking=yes \
  -o \
  "UserKnownHostsFile=${known_hosts}" \
  -o \
  GlobalKnownHostsFile=/dev/null \
  -o \
  ConnectTimeout=7 \
  -o \
  ConnectionAttempts=1 \
  -o \
  LogLevel=ERROR)"
[ "${ssh_options}" = "${expected_ssh_options}" ] ||
  fail "doctor_ssh_options did not return the exact strict SSH argv"
pass "strict SSH argv is exact"

if PATH="${doctor_path}" command -v timeout >/dev/null 2>&1 ||
  PATH="${doctor_path}" command -v gtimeout >/dev/null 2>&1; then
  fail "stock-shell doctor test path unexpectedly contains timeout"
fi

set +e
text_output="$(
  printf 'caller input must not reach ssh\n' |
    doctor_environment "${CLI}" \
      --config "${config}" \
      --lock "${LOCK}" \
      doctor
)"
text_status=$?
set -e
[ "${text_status}" -eq 0 ] ||
  fail "healthy doctor exited ${text_status}; SSH log: $(cat "${ssh_log}")"
second_text_output="$(
  printf 'second caller input\n' |
    doctor_environment "${CLI}" \
      --config "${config}" \
      --lock "${LOCK}" \
      doctor
)"
[ "${text_output}" = "${second_text_output}" ] ||
  fail "healthy text output is not stable"
assert_contains "${text_output}" "PASS node.node-a.identity:" \
  "healthy text omitted identity result"
assert_contains "${text_output}" "PASS fabric.pair.node-c.node-d:" \
  "healthy text omitted sixth unordered pair"
assert_contains "${text_output}" "SUMMARY healthy:" \
  "healthy text omitted summary"
pass "healthy doctor text is stable"

ssh_log_content="$(cat "${ssh_log}")"
for strict_option in \
  "BatchMode=yes" \
  "StrictHostKeyChecking=yes" \
  "UserKnownHostsFile=${expanded_known_hosts}" \
  "GlobalKnownHostsFile=/dev/null" \
  "ConnectTimeout=7" \
  "ConnectionAttempts=1"; do
  assert_contains "${ssh_log_content}" "arg=${strict_option}" \
    "SSH invocation omitted ${strict_option}"
done
if printf '%s\n' "${ssh_log_content}" | grep -Fq "stdin=attached"; then
  fail "SSH inherited caller stdin"
fi
detached_count="$(
  printf '%s\n' "${ssh_log_content}" |
    awk '$0 == "stdin=detached" { count += 1 } END { print count + 0 }'
)"
[ "${detached_count}" -eq 16 ] ||
  fail "expected sixteen detached SSH calls across two runs, got ${detached_count}"
for alias_name in glm53-node-a glm53-node-b glm53-node-c glm53-node-d; do
  alias_count="$(
    printf '%s\n' "${ssh_log_content}" |
      awk -v expected="alias=${alias_name}" '$0 == expected { count += 1 } END { print count + 0 }'
  )"
  [ "${alias_count}" -eq 4 ] ||
    fail "SSH alias ${alias_name} did not receive both read-only probes per run"
done
pass "SSH calls are strict, Python-bounded, and stdin-detached"

json_output="$(
  doctor_environment "${CLI}" \
    --config "${config}" \
    --lock "${LOCK}" \
    doctor --json
)"
printf '%s' "${json_output}" |
  python3 -c '
import json
import sys

payload = json.load(sys.stdin)
assert payload["status"] == "healthy"
assert payload["summary"]["failed"] == 0
assert not any(item["id"] == "local.tool.timeout" for item in payload["findings"])
assert len([item for item in payload["findings"] if item["id"].startswith("fabric.pair.")]) == 6
'
pass "healthy JSON works without timeout binaries"

before_rejection_lines="$(wc -l <"${ssh_log}" | tr -d ' ')"
for mutation_option in \
  global-apply \
  --apply \
  --fix \
  --repair \
  --install \
  --enroll-keys \
  --configure-firewall \
  --sudo; do
  if [ "${mutation_option}" = global-apply ]; then
    set -- --apply doctor
    invocation="--apply doctor"
  else
    set -- doctor "${mutation_option}"
    invocation="doctor ${mutation_option}"
  fi
  set +e
  rejection_output="$(
    doctor_environment "${CLI}" \
      --config "${config}" \
      --lock "${LOCK}" \
      "$@" 2>&1
  )"
  rejection_status=$?
  set -e
  [ "${rejection_status}" -eq 2 ] ||
    fail "'${invocation}' exited ${rejection_status}, expected 2"
  assert_contains "${rejection_output}" "doctor" \
    "'${invocation}' did not explain doctor rejection"
done
after_rejection_lines="$(wc -l <"${ssh_log}" | tr -d ' ')"
[ "${before_rejection_lines}" -eq "${after_rejection_lines}" ] ||
  fail "rejected doctor options reached SSH probes"
pass "doctor rejects global apply and mutating-looking options"

set +e
missing_output="$(
  FAKE_FABRIC_FIXTURE="${MISSING_LINK_FIXTURE}" \
    doctor_environment "${CLI}" \
      --config "${config}" \
      --lock "${LOCK}" \
      doctor --json
)"
missing_status=$?
set -e
[ "${missing_status}" -eq 1 ] ||
  fail "missing fabric direction exited ${missing_status}, expected 1"
printf '%s' "${missing_output}" |
  python3 -c '
import json
import sys

payload = json.load(sys.stdin)
failed = [item["id"] for item in payload["findings"] if not item["ok"]]
assert payload["status"] == "failed"
assert failed == ["fabric.pair.node-c.node-d"]
'
pass "missing fabric direction exits 1"

helper_secret="HELPER-SENSITIVE-MARKER"
for helper_command in extract-addresses merge-reachability evaluate; do
  case "${helper_command}" in
    extract-addresses) helper_finding=doctor.pipeline.extract_addresses ;;
    merge-reachability) helper_finding=doctor.pipeline.merge_reachability ;;
    evaluate) helper_finding=doctor.pipeline.evaluate ;;
    *) fail "unexpected helper command in test" ;;
  esac
  set +e
  helper_output="$(
    FAIL_FABRIC_COMMAND="${helper_command}" \
      FAKE_HELPER_SECRET="${helper_secret}" \
      doctor_environment "${CLI}" \
        --config "${config}" \
        --lock "${LOCK}" \
        doctor --json 2>&1
  )"
  helper_status=$?
  set -e
  [ "${helper_status}" -eq 1 ] ||
    fail "${helper_command} failure exited ${helper_status}, expected 1"
  case "${helper_output}" in
    *"${helper_secret}"*) fail "${helper_command} exposed helper stderr" ;;
  esac
  printf '%s' "${helper_output}" |
    python3 -c "
import json
import sys

payload = json.load(sys.stdin)
failed = [item[\"id\"] for item in payload[\"findings\"] if not item[\"ok\"]]
assert payload[\"status\"] == \"failed\"
assert \"${helper_finding}\" in failed
"
done
pass "helper failures are redacted and aggregated"

secret_marker="REMOTE-SENSITIVE-MARKER"
set +e
redacted_output="$(
  FAKE_SSH_FAIL_ALIAS=glm53-node-b \
    FAKE_SSH_SECRET_MARKER="${secret_marker}" \
    doctor_environment "${CLI}" \
      --config "${config}" \
      --lock "${LOCK}" \
      doctor --json 2>&1
)"
redacted_status=$?
set -e
[ "${redacted_status}" -eq 1 ] ||
  fail "failed SSH probe exited ${redacted_status}, expected 1"
case "${redacted_output}" in
  *"${secret_marker}"*) fail "doctor exposed remote stderr" ;;
esac
assert_contains "${redacted_output}" '"id":"node.node-b.ssh"' \
  "failed SSH probe was not aggregated"
[ ! -s "${mutation_log}" ] || fail "doctor invoked a mutating tool"
pass "remote failures are aggregated and redacted without mutation"

if grep -Fq "GLM53_REACHABILITY_PROBE" \
  "${ROOT_DIR}/lib/doctor.sh" \
  "${ROOT_DIR}/tools/node_probe.py"; then
  fail "production remote probes contain the test-only mode marker"
fi
pass "remote probes use an explicit production mode"

printf 'Doctor contract passed.\n'

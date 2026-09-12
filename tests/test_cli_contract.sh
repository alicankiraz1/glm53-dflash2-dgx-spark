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
    *) fail "${message}: expected '${needle}' in '${haystack}'" ;;
  esac
}

readonly CLI="${ROOT_DIR}/glm53-spark"
readonly CONFIG="${ROOT_DIR}/tests/fixtures/cluster.valid.json"
readonly LOCK="${ROOT_DIR}/config/reproduction.lock.json"

[ -x "${CLI}" ] || fail "CLI is missing or not executable: ${CLI}"

unset_line="$(awk '/^unset APPLY$/ { print NR; exit }' "${CLI}")"
init_line="$(awk '/^_GLM53_APPLY=0$/ { print NR; exit }' "${CLI}")"
strict_line="$(awk '/^set -eu$/ { print NR; exit }' "${CLI}")"
[ -n "${unset_line}" ] || fail "CLI does not unset inherited APPLY"
[ -n "${init_line}" ] || fail "CLI does not initialize internal apply consent"
[ -n "${strict_line}" ] || fail "CLI does not enable strict shell options"
[ "${unset_line}" -eq "$((strict_line + 1))" ] ||
  fail "inherited APPLY removal is not the first statement after strict options"
[ "${init_line}" -eq "$((unset_line + 1))" ] ||
  fail "internal apply initialization does not immediately follow inherited removal"
pass "apply consent is reset before option parsing"

temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/glm53-cli-contract.XXXXXX")"
cleanup() {
  rm -rf "${temporary_directory}"
}
trap cleanup EXIT HUP INT TERM

state_root="${temporary_directory}/state"
fixed_sentinel="${state_root}/test-apply-sentinel"
malicious_action="${temporary_directory}/caller-action"
malicious_sentinel="${temporary_directory}/caller-action-executed"
cat >"${malicious_action}" <<'EOF'
#!/usr/bin/env bash
set -eu
: >"${MALICIOUS_SENTINEL:?}"
EOF
chmod 0700 "${malicious_action}"

set +e
plan_output="$(
  APPLY=1 GLM53_TESTING=1 "${CLI}" \
    --config "${CONFIG}" \
    --lock "${LOCK}" \
    --state-root "${state_root}" \
    __test-plan-or-apply \
    pass 2>&1
)"
plan_status=$?
set -e
[ "${plan_status}" -eq 0 ] ||
  fail "inherited APPLY plan command failed with status ${plan_status}: ${plan_output}"
[ ! -e "${fixed_sentinel}" ] ||
  fail "inherited APPLY authorized fake mutation"
assert_contains "${plan_output}" "PLAN:" "plan-only invocation did not print a plan"
assert_contains "${plan_output}" "test_write_mutation_sentinel" "plan omitted fixed action"
pass "inherited APPLY remains plan-only"

set +e
blocked_output="$(
  GLM53_TESTING=1 "${CLI}" \
    --config "${CONFIG}" \
    --lock "${LOCK}" \
    --state-root "${state_root}" \
    --apply \
    __test-plan-or-apply \
    fail 2>&1
)"
blocked_status=$?
set -e
[ "${blocked_status}" -ne 0 ] ||
  fail "explicit --apply bypassed a failed preflight gate"
[ ! -e "${fixed_sentinel}" ] ||
  fail "failed preflight gate allowed fake mutation"
assert_contains "${blocked_output}" "preflight gate" "failed gate error was not actionable"
pass "failed preflight blocks explicit apply"

apply_output="$(
  GLM53_TESTING=1 "${CLI}" \
    --config "${CONFIG}" \
    --lock "${LOCK}" \
    --state-root "${state_root}" \
    --apply \
    __test-plan-or-apply \
    pass
)"
[ "${apply_output}" = "APPLY: preflight passed" ] ||
  fail "explicit apply output was unexpected: ${apply_output}"
[ -f "${fixed_sentinel}" ] ||
  fail "explicit --apply did not create the fixed mutation sentinel"
[ "$(cat "${fixed_sentinel}")" = "applied" ] ||
  fail "fixed mutation sentinel content was unexpected"
pass "explicit --apply executes only after preflight"

rm -f "${fixed_sentinel}"
set +e
arbitrary_output="$(
  MALICIOUS_SENTINEL="${malicious_sentinel}" GLM53_TESTING=1 "${CLI}" \
    --config "${CONFIG}" \
    --lock "${LOCK}" \
    --state-root "${state_root}" \
    --apply \
    __test-plan-or-apply \
    pass \
    "${malicious_action}" 2>&1
)"
arbitrary_status=$?
set -e
[ "${arbitrary_status}" -eq 2 ] ||
  fail "caller-supplied action exited ${arbitrary_status}, expected 2"
[ ! -e "${malicious_sentinel}" ] ||
  fail "CLI executed a caller-supplied action"
assert_contains "${arbitrary_output}" "accepts only" "extra-action rejection missing"
pass "test seam rejects caller-supplied actions"

cli_export() {
  GLM53_TESTING=1 "${CLI}" \
    --config "${CONFIG}" \
    --lock "${LOCK}" \
    __test-config-export "$1"
}

assert_export() {
  export_field=$1
  expected_value=$2
  actual_value="$(cli_export "${export_field}")"
  [ "${actual_value}" = "${expected_value}" ] ||
    fail "config export ${export_field} returned '${actual_value}', expected '${expected_value}'"
}

assert_export version 1
assert_export node_count 4
assert_export source_node_id node-a
assert_export source_ssh_alias glm53-node-a
assert_export source_remote_root /srv/glm53-package
assert_export source_hf_cache_root /srv/hf-cache
expected_known_hosts_path=\~/.ssh/glm53_known_hosts
assert_export ssh_known_hosts_file "${expected_known_hosts_path}"
assert_export ssh_fabric_known_hosts_file /srv/glm53-operator/fabric_known_hosts
assert_export ssh_connect_timeout_seconds 7
assert_export ssh_command_timeout_seconds 30
assert_export fabric_ipv4_cidr 192.0.2.0/24
assert_export fabric_require_rdma true
assert_export api_port 8002
assert_export dist_port 29600
exported_config_digest="$(
  GLM53_TESTING=1 "${CLI}" \
    --config "${CONFIG}" \
    --lock "${LOCK}" \
    __test-config-export config_digest
)"
case "${exported_config_digest}" in
  *[!0-9a-f]*|"") fail "config digest export is not lowercase hexadecimal" ;;
esac
[ "${#exported_config_digest}" -eq 64 ] ||
  fail "config digest export does not contain 64 characters"

assert_export node.0.id node-a
assert_export node.0.rank 0
assert_export node.0.fabric_ipv4 192.0.2.10
assert_export node.0.hf_cache_root /srv/hf-cache
assert_export node.0.expected_machine_id_sha256 \
  aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
assert_export node.1.ssh_alias glm53-node-b
assert_export node.1.rank 1
assert_export node.2.role worker
assert_export node.2.rank 2
assert_export node.3.remote_root /srv/glm53-package
assert_export node.3.rank 3
pass "dispatcher exports fixed and per-rank scalar config"

set +e
unsupported_export_output="$(cli_export unsupported.field 2>&1)"
unsupported_export_status=$?
set -e
[ "${unsupported_export_status}" -eq 2 ] ||
  fail "unsupported config export exited ${unsupported_export_status}, expected 2"
assert_contains "${unsupported_export_output}" "unsupported config export field" \
  "unsupported config export error missing"
pass "unsupported config exports exit 2"

set +e
unsupported_output="$(
  "${CLI}" \
    --config "${CONFIG}" \
    --lock "${LOCK}" \
    unsupported-command 2>&1
)"
unsupported_status=$?
set -e
[ "${unsupported_status}" -eq 2 ] ||
  fail "unsupported command exited ${unsupported_status}, expected 2"
assert_contains "${unsupported_output}" "unsupported command" "unsupported command error missing"
pass "unsupported commands exit 2"

printf 'CLI contract passed.\n'

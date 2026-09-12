#!/usr/bin/env bash
set -eu

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT_DIR
FIXTURE_CONFIG="${ROOT_DIR}/tests/fixtures/cluster.valid.json"
LOCK_PATH="${ROOT_DIR}/config/reproduction.lock.json"
RUN_ID=20260828T120000.000000Z-00112233445566778899aabbccddeeff

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
. "${ROOT_DIR}/lib/prepare.sh"

first_plan="$(
  prepare_plan "${FIXTURE_CONFIG}" "${LOCK_PATH}" "${RUN_ID}"
)"
second_plan="$(
  prepare_plan "${FIXTURE_CONFIG}" "${LOCK_PATH}" "${RUN_ID}"
)"
[ "${first_plan}" = "${second_plan}" ] ||
  fail "prepare plan is not deterministic"
assert_contains "${first_plan}" "PLAN:"
assert_contains "${first_plan}" "PLAN_SHA256:"
assert_contains "${first_plan}" "glm53-node-a"
assert_not_contains "${first_plan}" "glm53-node-b bash"
assert_not_contains "${first_plan}" "glm53-node-c bash"
assert_not_contains "${first_plan}" "glm53-node-d bash"
assert_contains "${first_plan}" "lmsysorg/sglang@sha256:e88340d6"
assert_contains "${first_plan}" "92831e5ec1e109b1be6d7071281557cd6481f4f5"
assert_contains "${first_plan}" "hf download LibertAIDAI/GLM-5.3-Flash-NVFP4 --revision aa28e1f54130286c95fee10d0705c74ce8743734"
assert_contains "${first_plan}" "hf download incoai/GLM-5.3-Flash-DFlash2 --revision 7d74cdd881ed7e32c31175984a67823127b66cfe"
assert_contains "${first_plan}" "--format quiet"
assert_contains "${first_plan}" "rsync -a --partial --append-verify"
assert_contains "${first_plan}" "rsync -aH --partial --append-verify"
assert_contains "${first_plan}" "StrictHostKeyChecking=yes"
assert_contains "${first_plan}" "GlobalKnownHostsFile=/dev/null"
assert_contains "${first_plan}" "/srv/glm53-operator/fabric_known_hosts"
assert_contains "${first_plan}" "192.0.2.11"
assert_contains "${first_plan}" "docker save"
assert_contains "${first_plan}" "docker load"
assert_contains "${first_plan}" "RootFS"
assert_not_contains "${first_plan}" "TOKEN"
assert_not_contains "${first_plan}" "token="
assert_not_contains "${first_plan}" "accept-new"
assert_not_contains "${first_plan}" "rm -rf"
assert_not_contains "${first_plan}" "sudo"
pass "prepare plan is deterministic, pinned, source-only, and secret-free"

digest_of() {
  shasum -a 256 "$1" | awk '{print $1}'
}

SOURCE_RUN_ROOT="/srv/glm53-package/.runtime/prepare/${RUN_ID}"
WORKER_RUN_ROOT="/srv/glm53-package/.runtime/prepare/${RUN_ID}"
TARGET_CACHE_NAME=models--LibertAIDAI--GLM-5.3-Flash-NVFP4
DRAFT_CACHE_NAME=models--incoai--GLM-5.3-Flash-DFlash2

assert_contains "${first_plan}" "/etc/machine-id"
assert_contains "${first_plan}" "${SOURCE_RUN_ROOT}/image.tar"
assert_contains "${first_plan}" "${SOURCE_RUN_ROOT}/image.tar.sha256"
assert_contains "${first_plan}" "${SOURCE_RUN_ROOT}/bundle"
assert_contains "${first_plan}" "${SOURCE_RUN_ROOT}/bundle.manifest.json"
assert_contains "${first_plan}" "${WORKER_RUN_ROOT}/image.tar.partial"
assert_contains "${first_plan}" "/srv/hf-cache/.glm53-stage-${RUN_ID}-target-model"
assert_contains "${first_plan}" "/srv/hf-cache/.glm53-stage-${RUN_ID}-draft-model"
assert_contains "${first_plan}" "/srv/hf-cache/${TARGET_CACHE_NAME}"
assert_contains "${first_plan}" "/srv/hf-cache/${DRAFT_CACHE_NAME}"
assert_contains "${first_plan}" "worker-bundle-verify"
assert_contains "${first_plan}" "worker-identity"
assert_contains "${first_plan}" "target-model-preflight"
assert_contains "${first_plan}" "target-model-promote"
pass "plan names the exact run, bundle, staging, and promotion paths"

PLAN_PINNED_FILES="glm53-spark
lib/common.sh
lib/config.sh
lib/doctor.sh
lib/prepare.sh
lib/prepare_remote.sh
tools/artifact_manifest.py
tools/config_state.py
tools/fabric_probe.py
tools/node_probe.py
tools/patch_series.py
tools/verify_hf_cache.py"

while IFS= read -r plan_pinned_file; do
  assert_contains \
    "${first_plan}" \
    "${plan_pinned_file} $(digest_of "${ROOT_DIR}/${plan_pinned_file}")"
done <<EOF
${PLAN_PINNED_FILES}
EOF
assert_contains "${first_plan}" "plan-pinned-sha256"
assert_contains "${first_plan}" "lock-pinned-sha256"
assert_contains \
  "${first_plan}" \
  "sglang-glm53-gb10-tilelang.patch $(
    digest_of "${ROOT_DIR}/runtime/patches/sglang-glm53-gb10-tilelang.patch"
  )"
pass "plan pins the bytes of every local file that affects apply"

plan_digest="$(
  printf '%s\n' "${first_plan}" |
    awk -F': ' '/^PLAN_SHA256: / {print $2}'
)"
case "${plan_digest}" in
  [0-9a-f][0-9a-f][0-9a-f][0-9a-f]*)
    [ "${#plan_digest}" -eq 64 ] || fail "plan digest has the wrong length"
    ;;
  *) fail "plan digest is malformed" ;;
esac

temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/glm53-prepare-test.XXXXXX")"
cleanup() {
  rm -r "${temporary_root}"
}
trap cleanup EXIT HUP INT TERM
fake_bin="${temporary_root}/bin"
mkdir "${fake_bin}"
command_log="${temporary_root}/commands.log"
doctor_log="${temporary_root}/doctor.log"

mutation_root="${temporary_root}/tree"
mkdir "${mutation_root}"
(cd "${ROOT_DIR}" && tar -cf - glm53-spark lib tools config runtime manifests \
  tests/fixtures) | (cd "${mutation_root}" && tar -xf -)

plan_digest_of_tree() {
  bash -c '
    set -eu
    tree_root=$1
    tree_run_id=$2
    . "${tree_root}/lib/common.sh"
    . "${tree_root}/lib/config.sh"
    . "${tree_root}/lib/doctor.sh"
    . "${tree_root}/lib/prepare.sh"
    prepare_plan \
      "${tree_root}/tests/fixtures/cluster.valid.json" \
      "${tree_root}/config/reproduction.lock.json" \
      "${tree_run_id}"
  ' bash "$1" "${RUN_ID}" |
    awk -F': ' '/^PLAN_SHA256: / {print $2}'
}

baseline_tree_digest="$(plan_digest_of_tree "${mutation_root}")"
[ "${baseline_tree_digest}" = "${plan_digest}" ] ||
  fail "plan digest is not reproducible from an identical tree copy"
while IFS= read -r plan_pinned_file; do
  printf '\n# glm53 plan digest coverage probe\n' \
    >>"${mutation_root}/${plan_pinned_file}"
  mutated_tree_digest="$(plan_digest_of_tree "${mutation_root}")"
  cp "${ROOT_DIR}/${plan_pinned_file}" "${mutation_root}/${plan_pinned_file}"
  [ "${mutated_tree_digest}" != "${plan_digest}" ] ||
    fail "plan digest ignores the bytes of ${plan_pinned_file}"
done <<EOF
${PLAN_PINNED_FILES}
EOF
pass "changing any apply-affecting local file changes the plan digest"

cat >"${fake_bin}/ssh" <<'EOF'
#!/usr/bin/env bash
printf 'ssh' >>"${GLM53_FAKE_COMMAND_LOG}"
printf ' <%s>' "$@" >>"${GLM53_FAKE_COMMAND_LOG}"
printf '\n' >>"${GLM53_FAKE_COMMAND_LOG}"
seen_separator=0
remote_action=
remote_argc=0
for argument in "$@"; do
  if [ "${seen_separator}" = 1 ]; then
    [ -n "${remote_action}" ] || remote_action=${argument}
    remote_argc=$((remote_argc + 1))
    continue
  fi
  if [ "${argument}" = "--" ]; then
    seen_separator=1
  fi
done
printf 'remote action=%s argc=%s stdin=%s\n' \
  "${remote_action}" \
  "${remote_argc}" \
  "$(shasum -a 256 | awk '{print $1}')" >>"${GLM53_FAKE_COMMAND_LOG}"
exit 0
EOF
cat >"${fake_bin}/docker" <<'EOF'
#!/usr/bin/env bash
printf 'docker <%s>\n' "$*" >>"${GLM53_FAKE_COMMAND_LOG}"
exit 0
EOF
cat >"${fake_bin}/rsync" <<'EOF'
#!/usr/bin/env bash
printf 'rsync <%s>\n' "$*" >>"${GLM53_FAKE_COMMAND_LOG}"
exit 0
EOF
cat >"${fake_bin}/hf" <<'EOF'
#!/usr/bin/env bash
printf 'hf <%s>\n' "$*" >>"${GLM53_FAKE_COMMAND_LOG}"
exit 0
EOF
cat >"${fake_bin}/git" <<'EOF'
#!/usr/bin/env bash
printf 'git <%s>\n' "$*" >>"${GLM53_FAKE_COMMAND_LOG}"
exit 0
EOF
chmod +x "${fake_bin}/ssh" "${fake_bin}/docker" "${fake_bin}/rsync" \
  "${fake_bin}/hf" "${fake_bin}/git"

doctor_run() {
  printf 'doctor\n' >>"${doctor_log}"
  return 0
}

export GLM53_FAKE_COMMAND_LOG="${command_log}"
original_path=${PATH}
PATH="${fake_bin}:${PATH}"

for invalid_run_id in \
  foo \
  ../escape \
  20260828T120000.000000Z-00112233445566778899aabbccddeef \
  20260828T120000.000000Z-00112233445566778899aabbccddeefF \
  20260828T120000Z-00112233445566778899aabbccddeeff; do
  rm -f "${command_log}" "${doctor_log}"
  if prepare_plan \
    "${FIXTURE_CONFIG}" \
    "${LOCK_PATH}" \
    "${invalid_run_id}" >/dev/null 2>&1; then
    fail "invalid prepare plan run ID was accepted: ${invalid_run_id}"
  fi
  if prepare_apply \
    "${FIXTURE_CONFIG}" \
    "${LOCK_PATH}" \
    "${invalid_run_id}" \
    0000000000000000000000000000000000000000000000000000000000000000 \
    CC-BY-NC-ND-4.0 >/dev/null 2>&1; then
    fail "invalid prepare apply run ID was accepted: ${invalid_run_id}"
  fi
  [ ! -e "${command_log}" ] ||
    fail "invalid run ID executed an external command: ${invalid_run_id}"
  [ ! -e "${doctor_log}" ] ||
    fail "invalid run ID reached doctor: ${invalid_run_id}"
done
pass "prepare rejects strict-format run IDs before planning or preflight"

cli_plan="$(
  "${ROOT_DIR}/glm53-spark" \
    --config "${FIXTURE_CONFIG}" \
    --lock "${LOCK_PATH}" \
    prepare \
    --run-id "${RUN_ID}"
)"
assert_contains "${cli_plan}" "PLAN_SHA256: ${plan_digest}"
[ ! -e "${command_log}" ] ||
  fail "plan-by-default CLI contacted an external executable"
pass "CLI prepare defaults to a non-mutating plan"

if prepare_apply \
  "${FIXTURE_CONFIG}" \
  "${LOCK_PATH}" \
  "${RUN_ID}" \
  0000000000000000000000000000000000000000000000000000000000000000 \
  CC-BY-NC-ND-4.0 >/dev/null 2>&1; then
  fail "stale plan digest was accepted"
fi
[ ! -e "${command_log}" ] || fail "stale plan executed an external command"
[ ! -e "${doctor_log}" ] ||
  fail "stale plan reached doctor before local identity validation"
pass "stale plan digest fails closed before mutation"

if prepare_apply \
  "${FIXTURE_CONFIG}" \
  "${LOCK_PATH}" \
  "${RUN_ID}" \
  "${plan_digest}" \
  WRONG-LICENSE >/dev/null 2>&1; then
  fail "wrong draft license acknowledgment was accepted"
fi
[ ! -e "${command_log}" ] ||
  fail "wrong license acknowledgment executed an external command"
pass "apply requires the exact draft license acknowledgment"

prepare_apply \
  "${FIXTURE_CONFIG}" \
  "${LOCK_PATH}" \
  "${RUN_ID}" \
  "${plan_digest}" \
  CC-BY-NC-ND-4.0 >/dev/null
[ "$(wc -l <"${doctor_log}" | tr -d ' ')" -eq 1 ] ||
  fail "apply did not run exactly one fresh doctor"
ssh_lines="$(grep '^ssh' "${command_log}" || true)"
[ -n "${ssh_lines}" ] || fail "apply did not execute source-node SSH actions"
case "${ssh_lines}" in
  *glm53-node-b*|*glm53-node-c*|*glm53-node-d*)
    fail "controller contacted a worker alias instead of the source node"
    ;;
  *) ;;
esac
assert_contains "${ssh_lines}" "glm53-node-a"
pass "apply reruns doctor and executes only source-node records"

observed_sequence="$(
  awk -F'action=| argc=' '/^remote action=/ {print $2}' "${command_log}"
)"
expected_sequence="$(
  printf '%s\n' preflight bootstrap build target-model draft-model distribute
)"
[ "${observed_sequence}" = "${expected_sequence}" ] ||
  fail "apply did not execute exactly the represented action sequence"
remote_argument_counts="$(
  awk -F'argc=| stdin=' '/^remote action=/ {print $2}' "${command_log}" |
    sort -u
)"
[ "${remote_argument_counts}" = "60" ] ||
  fail "remote argument vector drifted from the dispatcher contract"
observed_stdin_digests="$(
  awk -F'stdin=' '/^remote action=/ {print $2}' "${command_log}" | sort -u
)"
[ "${observed_stdin_digests}" = "$(digest_of "${ROOT_DIR}/lib/prepare_remote.sh")" ] ||
  fail "dispatcher bytes did not arrive on the remote standard input"
assert_contains "${ssh_lines}" "/etc/machine-id"
assert_contains "${ssh_lines}" "$(digest_of "${ROOT_DIR}/tools/verify_hf_cache.py")"
assert_contains "${ssh_lines}" "$(digest_of "${ROOT_DIR}/tools/artifact_manifest.py")"
assert_contains "${ssh_lines}" "$(digest_of "${ROOT_DIR}/tools/patch_series.py")"
pass "apply delivers the dispatcher bytes and the pinned tool digests"

partial="${temporary_root}/image.tar.partial"
printf 'partial' >"${partial}"
before_failure="$(wc -c <"${partial}" | tr -d ' ')"
rm -f "${command_log}"
cat >"${fake_bin}/ssh" <<'EOF'
#!/usr/bin/env bash
printf 'ssh <%s>\n' "$*" >>"${GLM53_FAKE_COMMAND_LOG}"
exit 23
EOF
chmod +x "${fake_bin}/ssh"
if prepare_apply \
  "${FIXTURE_CONFIG}" \
  "${LOCK_PATH}" \
  "${RUN_ID}" \
  "${plan_digest}" \
  CC-BY-NC-ND-4.0 >/dev/null 2>&1; then
  fail "interrupted transfer path unexpectedly succeeded"
fi
[ -f "${partial}" ] || fail "interrupted transfer artifact was deleted"
[ "$(wc -c <"${partial}" | tr -d ' ')" = "${before_failure}" ] ||
  fail "interrupted transfer artifact was modified"
failure_log="$(cat "${command_log}")"
assert_not_contains "${failure_log}" "rm -rf"
assert_not_contains "${failure_log}" "rm -f"
pass "interrupted work and failure evidence are preserved"

PATH=${original_path}

assert_contains "${ssh_lines}" "BatchMode=yes"
assert_contains "${ssh_lines}" "StrictHostKeyChecking=yes"
for forbidden in "accept-new" "sudo" "rm -rf" "apt-get"; do
  assert_not_contains "${ssh_lines}" "${forbidden}"
done
pass "controller SSH invocations stay strict, read-only, and cleanup-free"

printf 'Prepare contract passed.\n'

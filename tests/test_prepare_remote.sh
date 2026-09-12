#!/usr/bin/env bash

# Behavioral tests for the remote prepare dispatcher. Every check executes the
# real lib/prepare_remote.sh against a temporary package root, a temporary
# cache root, and fake executables on PATH. No live node, Hub, registry, or
# Docker daemon is contacted.

set -eu

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT_DIR
readonly REMOTE="${ROOT_DIR}/lib/prepare_remote.sh"
readonly RUN_ID=20260828T120000.000000Z-00112233445566778899aabbccddeeff
readonly REVISION=aa28e1f54130286c95fee10d0705c74ce8743734
readonly BASE_IMAGE=lmsysorg/sglang@sha256:e88340d6cd59e7356147d00de4a318f5951698c9c9dae70ba36fe12d2f034714
readonly BASE_ARM64=sha256:73f9294b78e38d8cc297bfed16daec8ac192b126a2d1fb9055e259a632c68f00
readonly SGLANG_COMMIT=92831e5ec1e109b1be6d7071281557cd6481f4f5
readonly IMAGE_REPOSITORY=glm53-dflash2-dgx-spark
readonly IMAGE_OWNER=glm53-spark
readonly CONFIG_DIGEST=1111111111111111111111111111111111111111111111111111111111111111
readonly LOCK_DIGEST=2222222222222222222222222222222222222222222222222222222222222222
readonly WORKER_DIGEST_B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
readonly WORKER_DIGEST_C=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
readonly WORKER_DIGEST_D=dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
readonly SECRET_MARKER=synthetic-remote-secret-marker

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

pass() {
  printf 'PASS: %s\n' "$*"
}

assert_contains() {
  case "$1" in
    *"$2"*) ;;
    *) fail "expected to contain '$2': $1" ;;
  esac
}

assert_not_contains() {
  case "$1" in
    *"$2"*) fail "expected not to contain '$2': $1" ;;
    *) ;;
  esac
}

digest_of() {
  shasum -a 256 "$1" | awk '{print $1}'
}

WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/glm53-remote-test.XXXXXX")"
readonly WORK_ROOT
cleanup() {
  /bin/rm -rf "${WORK_ROOT}"
}
trap cleanup EXIT HUP INT TERM

readonly FAKE_BIN="${WORK_ROOT}/bin"
readonly CACHE_TOOL="${WORK_ROOT}/make_cache.py"
mkdir "${FAKE_BIN}"

cat >"${CACHE_TOOL}" <<'PYTHON'
#!/usr/bin/env python3
"""Materialize a minimal but realistic Hugging Face snapshot cache."""

import hashlib
import json
import pathlib
import sys

WEIGHTS = b"synthetic-weights-payload"
CONFIG = b'{"model_type":"glm"}\n'


def git_blob(payload: bytes) -> str:
    hasher = hashlib.sha1()
    hasher.update(f"blob {len(payload)}\0".encode("ascii"))
    hasher.update(payload)
    return hasher.hexdigest()


def main(argv: list[str]) -> int:
    cache_root = pathlib.Path(argv[1])
    repository = argv[2]
    revision = argv[3]
    manifest_path = pathlib.Path(argv[4]) if len(argv) > 4 else None
    weights = WEIGHTS if len(argv) < 6 else argv[5].encode("utf-8")
    repo_root = cache_root / ("models--" + repository.replace("/", "--"))
    blobs = repo_root / "blobs"
    snapshot = repo_root / "snapshots" / revision
    blobs.mkdir(parents=True, exist_ok=True)
    snapshot.mkdir(parents=True, exist_ok=True)
    weights_digest = hashlib.sha256(weights).hexdigest()
    (blobs / weights_digest).write_bytes(weights)
    config_digest = git_blob(CONFIG)
    (blobs / config_digest).write_bytes(CONFIG)
    for name, digest in (
        ("model.safetensors", weights_digest),
        ("config.json", config_digest),
    ):
        link = snapshot / name
        if not link.exists():
            link.symlink_to(pathlib.Path("..") / ".." / "blobs" / digest)
    if manifest_path is not None:
        manifest_path.parent.mkdir(parents=True, exist_ok=True)
        manifest_path.write_text(
            json.dumps(
                {
                    "revision": revision,
                    "files": {
                        "config.json": config_digest,
                        "model.safetensors": weights_digest,
                    },
                },
                sort_keys=True,
            )
            + "\n",
            encoding="utf-8",
        )
    print(len(weights))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
PYTHON

cat >"${FAKE_BIN}/sha256sum" <<'EOF'
#!/usr/bin/env bash
set -eu
if [ "$#" -eq 0 ]; then
  printf '%s  -\n' "$(/usr/bin/shasum -a 256 | awk '{print $1}')"
  exit 0
fi
for path in "$@"; do
  printf '%s  %s\n' "$(/usr/bin/shasum -a 256 "${path}" | awk '{print $1}')" "${path}"
done
EOF

cat >"${FAKE_BIN}/stat" <<'EOF'
#!/usr/bin/env bash
set -eu
if [ "$#" -eq 3 ] && [ "$1" = "-c" ] && [ "$2" = "%d" ]; then
  python3 - "$3" <<'PY'
import os
import sys

print(os.stat(sys.argv[1]).st_dev)
PY
  exit 0
fi
exec /usr/bin/stat "$@"
EOF

cat >"${FAKE_BIN}/ssh" <<'EOF'
#!/usr/bin/env bash
set -eu
log_dir=${GLM53_FAKE_SSH_DIR}
count_file="${log_dir}/count"
index=$(( $(cat "${count_file}" 2>/dev/null || printf '0') + 1 ))
printf '%s' "${index}" >"${count_file}"
printf '%s\n' "$*" >"${log_dir}/argv.${index}"
cat >"${log_dir}/stdin.${index}"
printf 'ssh <%s>\n' "$*" >>"${GLM53_FAKE_COMMAND_LOG}"
if [ -n "${GLM53_FAKE_SSH_FAIL_MATCH:-}" ] &&
  grep -Fq "${GLM53_FAKE_SSH_FAIL_MATCH}" "${log_dir}/stdin.${index}"; then
  printf 'synthetic-remote-secret-marker\n'
  printf 'synthetic-remote-secret-marker\n' >&2
  exit "${GLM53_FAKE_SSH_FAIL_STATUS:-1}"
fi
if grep -Fq 'glm53-remote-script:target-model-preflight' "${log_dir}/stdin.${index}"; then
  printf '%s\n' "${GLM53_FAKE_TARGET_DECISION:-stage}"
fi
if grep -Fq 'glm53-remote-script:worker-image-load' "${log_dir}/stdin.${index}"; then
  printf '%s\t%s\n' \
    "${GLM53_FAKE_WORKER_IMAGE_ID:-sha256:worker}" \
    "${GLM53_FAKE_IMAGE_LAYERS:-[\"sha256:layer\"]}"
fi
exit 0
EOF

cat >"${FAKE_BIN}/ssh-keygen" <<'EOF'
#!/usr/bin/env bash
set -eu
printf 'ssh-keygen <%s>\n' "$*" >>"${GLM53_FAKE_COMMAND_LOG}"
exit "${GLM53_FAKE_KEYGEN_STATUS:-0}"
EOF

cat >"${FAKE_BIN}/rsync" <<'EOF'
#!/usr/bin/env bash
set -eu
printf 'rsync <%s>\n' "$*" >>"${GLM53_FAKE_COMMAND_LOG}"
exit "${GLM53_FAKE_RSYNC_STATUS:-0}"
EOF

cat >"${FAKE_BIN}/git" <<'EOF'
#!/usr/bin/env bash
set -eu
printf 'git <%s>\n' "$*" >>"${GLM53_FAKE_COMMAND_LOG}"
if [ "$1" = "clone" ]; then
  mkdir -p "${!#}/.git" "${!#}/python/sglang"
  printf 'source\n' >"${!#}/python/sglang/__init__.py"
  exit 0
fi
case "$*" in
  *"rev-parse HEAD"*) printf '%s\n' "${GLM53_FAKE_GIT_HEAD}" ;;
esac
exit 0
EOF

cat >"${FAKE_BIN}/hf" <<'EOF'
#!/usr/bin/env bash
set -eu
printf 'hf <%s>\n' "$*" >>"${GLM53_FAKE_COMMAND_LOG}"
repository=$2
revision=
cache_dir=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --revision) revision=$2; shift 2 ;;
    --cache-dir) cache_dir=$2; shift 2 ;;
    *) shift ;;
  esac
done
python3 "${GLM53_FAKE_CACHE_TOOL}" "${cache_dir}" "${repository}" "${revision}" \
  >/dev/null
exit "${GLM53_FAKE_HF_STATUS:-0}"
EOF

cat >"${FAKE_BIN}/docker" <<'EOF'
#!/usr/bin/env bash
set -eu
printf 'docker <%s>\n' "$*" >>"${GLM53_FAKE_COMMAND_LOG}"
case "$1" in
  "pull")
    exit "${GLM53_FAKE_DOCKER_PULL_STATUS:-0}"
    ;;
  "build")
    status="${GLM53_FAKE_DOCKER_BUILD_STATUS:-0}"
    if [ "${status}" -eq 0 ] && [ -n "${GLM53_FAKE_DOCKER_STATE:-}" ]; then
      : >"${GLM53_FAKE_DOCKER_STATE}/image.present"
    fi
    exit "${status}"
    ;;
  "save")
    output=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --output) output=$2; shift 2 ;;
        *) shift ;;
      esac
    done
    printf 'synthetic-image-tar\n' >"${output}"
    exit "${GLM53_FAKE_DOCKER_SAVE_STATUS:-0}"
    ;;
  "run")
    cat >/dev/null
    exit "${GLM53_FAKE_DOCKER_RUN_STATUS:-0}"
    ;;
  "load")
    status="${GLM53_FAKE_DOCKER_LOAD_STATUS:-0}"
    if [ "${status}" -eq 0 ] && [ -n "${GLM53_FAKE_DOCKER_STATE:-}" ]; then
      : >"${GLM53_FAKE_DOCKER_STATE}/image.present"
    fi
    exit "${status}"
    ;;
  "buildx")
    printf '%s\n' "${GLM53_FAKE_BASE_ARM64}"
    exit 0
    ;;
  "image")
    format=
    image=
    shift 2
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --format) format=$2; shift 2 ;;
        *) image=$1; shift ;;
      esac
    done
    case "${image}" in
      *@sha256:*) ;;
      *)
        if [ -n "${GLM53_FAKE_DOCKER_STATE:-}" ]; then
          [ -f "${GLM53_FAKE_DOCKER_STATE}/image.present" ] || exit 1
        else
          [ "${GLM53_FAKE_IMAGE_PRESENT:-1}" = 1 ] || exit 1
        fi
        ;;
    esac
    case "${format}" in
      '{{.Architecture}}') printf '%s\n' "${GLM53_FAKE_ARCH:-arm64}" ;;
      '{{json .RepoDigests}}') printf '["%s"]\n' "${GLM53_FAKE_BASE_IMAGE}" ;;
      '{{json .RootFS.Layers}}') printf '%s\n' "${GLM53_FAKE_IMAGE_LAYERS:-[\"sha256:layer\"]}" ;;
      '{{.Id}}') printf '%s\n' "${GLM53_FAKE_SOURCE_IMAGE_ID:-sha256:source}" ;;
      *owner*) printf '%s\n' "${GLM53_FAKE_OWNER}" ;;
      *sglang.commit*) printf '%s\n' "${GLM53_FAKE_COMMIT}" ;;
      *patch.sha256*) printf '%s\n' "${GLM53_FAKE_PATCH_DIGEST}" ;;
      *) printf '\n' ;;
    esac
    exit 0
    ;;
esac
exit 0
EOF

cat >"${FAKE_BIN}/rm" <<'EOF'
#!/usr/bin/env bash
printf 'rm <%s>\n' "$*" >>"${GLM53_FAKE_COMMAND_LOG}"
exit 0
EOF

chmod +x "${FAKE_BIN}"/* "${CACHE_TOOL}"

PATH="${FAKE_BIN}:${PATH}"
export PATH
export GLM53_FAKE_CACHE_TOOL="${CACHE_TOOL}"
export GLM53_FAKE_BASE_IMAGE="${BASE_IMAGE}"
export GLM53_FAKE_BASE_ARM64="${BASE_ARM64}"
export GLM53_FAKE_OWNER="${IMAGE_OWNER}"
export GLM53_FAKE_COMMIT="${SGLANG_COMMIT}"
export GLM53_FAKE_GIT_HEAD="${SGLANG_COMMIT}"

case_index=0
PKG=
SOURCE_CACHE=
WORKER_ROOT=/srv/worker-package
WORKER_CACHE=/srv/worker-cache
MACHINE_ID_FILE=
FABRIC_KNOWN_HOSTS=
SOURCE_MACHINE_DIGEST=
CONTAINERFILE_DIGEST=
SERIES_DIGEST=
PATCH_DIGEST=
VERIFIER_DIGEST=
MANIFEST_TOOL_DIGEST=
SERIES_TOOL_DIGEST=
TARGET_MANIFEST_DIGEST=
DRAFT_MANIFEST_DIGEST=
TARGET_BYTES=
DRAFT_BYTES=
COMMAND_LOG=
SSH_DIR=
DOCKER_STATE=

new_case() {
  case_index=$((case_index + 1))
  local case_root="${WORK_ROOT}/case-${case_index}"
  mkdir -p "${case_root}"
  PKG="${case_root}/package"
  SOURCE_CACHE="${case_root}/hf-cache"
  MACHINE_ID_FILE="${case_root}/machine-id"
  FABRIC_KNOWN_HOSTS="${case_root}/fabric_known_hosts"
  COMMAND_LOG="${case_root}/commands.log"
  SSH_DIR="${case_root}/ssh"
  DOCKER_STATE="${case_root}/docker-state"
  mkdir -p "${PKG}/tools" "${PKG}/manifests" "${PKG}/runtime/patches" \
    "${SOURCE_CACHE}" "${SSH_DIR}" "${DOCKER_STATE}"
  cp "${ROOT_DIR}/tools/verify_hf_cache.py" "${PKG}/tools/verify_hf_cache.py"
  cp "${ROOT_DIR}/tools/artifact_manifest.py" "${PKG}/tools/artifact_manifest.py"
  cp "${ROOT_DIR}/tools/patch_series.py" "${PKG}/tools/patch_series.py"
  cp "${ROOT_DIR}/tests/fixtures/patches/alpha.patch" \
    "${PKG}/runtime/patches/alpha.patch"
  cp "${ROOT_DIR}/tests/fixtures/patches/bravo.patch" \
    "${PKG}/runtime/patches/bravo.patch"
  cp "${ROOT_DIR}/tests/fixtures/patches/series.two.json" \
    "${PKG}/runtime/patches/series.json"
  printf 'FROM %s\n' "${BASE_IMAGE}" >"${PKG}/runtime/Containerfile"
  printf 'synthetic-machine-id\n' >"${MACHINE_ID_FILE}"
  printf 'fabric-known-hosts\n' >"${FABRIC_KNOWN_HOSTS}"
  : >"${COMMAND_LOG}"

  TARGET_BYTES="$(
    python3 "${CACHE_TOOL}" "${case_root}/seed" fake/target "${REVISION}" \
      "${PKG}/manifests/target.json"
  )"
  DRAFT_BYTES="$(
    python3 "${CACHE_TOOL}" "${case_root}/seed" fake/draft "${REVISION}" \
      "${PKG}/manifests/draft.json"
  )"
  /bin/rm -rf "${case_root}/seed"

  SOURCE_MACHINE_DIGEST="$(
    tr -d '\n' <"${MACHINE_ID_FILE}" | /usr/bin/shasum -a 256 | awk '{print $1}'
  )"
  CONTAINERFILE_DIGEST="$(digest_of "${PKG}/runtime/Containerfile")"
  SERIES_DIGEST="$(digest_of "${PKG}/runtime/patches/series.json")"
  PATCH_DIGEST="$(digest_of "${PKG}/runtime/patches/bravo.patch")"
  VERIFIER_DIGEST="$(digest_of "${PKG}/tools/verify_hf_cache.py")"
  MANIFEST_TOOL_DIGEST="$(digest_of "${PKG}/tools/artifact_manifest.py")"
  SERIES_TOOL_DIGEST="$(digest_of "${PKG}/tools/patch_series.py")"
  TARGET_MANIFEST_DIGEST="$(digest_of "${PKG}/manifests/target.json")"
  DRAFT_MANIFEST_DIGEST="$(digest_of "${PKG}/manifests/draft.json")"

  export GLM53_FAKE_COMMAND_LOG="${COMMAND_LOG}"
  export GLM53_FAKE_SSH_DIR="${SSH_DIR}"
  export GLM53_FAKE_DOCKER_STATE="${DOCKER_STATE}"
  export GLM53_FAKE_PATCH_DIGEST="${PATCH_DIGEST}"
  unset GLM53_FAKE_SSH_FAIL_MATCH GLM53_FAKE_SSH_FAIL_STATUS
  unset GLM53_FAKE_TARGET_DECISION GLM53_FAKE_KEYGEN_STATUS
  unset GLM53_FAKE_RSYNC_STATUS GLM53_FAKE_HF_STATUS
  unset GLM53_FAKE_DOCKER_BUILD_STATUS GLM53_FAKE_DOCKER_SAVE_STATUS
  unset GLM53_FAKE_DOCKER_PULL_STATUS GLM53_FAKE_DOCKER_RUN_STATUS
  unset GLM53_FAKE_DOCKER_LOAD_STATUS
  unset GLM53_FAKE_IMAGE_PRESENT GLM53_FAKE_ARCH
}

REMOTE_ARGS=()
build_args() {
  local action=$1
  REMOTE_ARGS=(
    "${action}"
    "${RUN_ID}"
    "${PKG}"
    "${SOURCE_CACHE}"
    "${MACHINE_ID_FILE}"
    "${SOURCE_MACHINE_DIGEST}"
    "${CONFIG_DIGEST}"
    "${LOCK_DIGEST}"
    "${FABRIC_KNOWN_HOSTS}"
    "${BASE_IMAGE}"
    "${BASE_ARM64}"
    "${SGLANG_COMMIT}"
    "${IMAGE_REPOSITORY}"
    "${IMAGE_OWNER}"
    runtime/Containerfile
    "${CONTAINERFILE_DIGEST}"
    runtime/patches/series.json
    "${SERIES_DIGEST}"
    runtime/patches/bravo.patch
    "${PATCH_DIGEST}"
    "${VERIFIER_DIGEST}"
    "${MANIFEST_TOOL_DIGEST}"
    "${SERIES_TOOL_DIGEST}"
    fake/target
    "${REVISION}"
    1
    "${TARGET_BYTES}"
    194692696910
    manifests/target.json
    "${TARGET_MANIFEST_DIGEST}"
    fake/draft
    "${REVISION}"
    1
    "${DRAFT_BYTES}"
    manifests/draft.json
    "${DRAFT_MANIFEST_DIGEST}"
    node-a source "${PKG}" 192.0.2.10 "${SOURCE_CACHE}" "${SOURCE_MACHINE_DIGEST}"
    node-b worker "${WORKER_ROOT}" 192.0.2.11 "${WORKER_CACHE}" "${WORKER_DIGEST_B}"
    node-c worker "${WORKER_ROOT}" 192.0.2.12 "${WORKER_CACHE}" "${WORKER_DIGEST_C}"
    node-d worker "${WORKER_ROOT}" 192.0.2.13 "${WORKER_CACHE}" "${WORKER_DIGEST_D}"
  )
}

REMOTE_STATUS=0
REMOTE_OUTPUT=
run_remote() {
  set +e
  REMOTE_OUTPUT="$(bash "${REMOTE}" "$@" 2>&1)"
  REMOTE_STATUS=$?
  set -e
}

run_root_path() {
  printf '%s/.runtime/prepare/%s' "${PKG}" "${RUN_ID}"
}

ssh_stdin_files() {
  local index=1
  local total
  total="$(cat "${SSH_DIR}/count" 2>/dev/null || printf '0')"
  while [ "${index}" -le "${total}" ]; do
    printf '%s\n' "${SSH_DIR}/stdin.${index}"
    index=$((index + 1))
  done
}

# --- argument contract -------------------------------------------------------

new_case
run_remote preflight "${PKG}"
[ "${REMOTE_STATUS}" -ne 0 ] || fail "short argument vector was accepted"
assert_contains "${REMOTE_OUTPUT}" "field count"
[ ! -s "${COMMAND_LOG}" ] ||
  fail "short argument vector executed an external command"

build_args preflight
run_remote "${REMOTE_ARGS[@]}" extra-field
[ "${REMOTE_STATUS}" -ne 0 ] || fail "trailing argument was accepted"
assert_contains "${REMOTE_OUTPUT}" "field count"
pass "remote argument contract fails closed on count drift"

# --- preflight, run contract, and failure evidence ---------------------------

new_case
build_args preflight
run_remote "${REMOTE_ARGS[@]}"
[ "${REMOTE_STATUS}" -eq 0 ] ||
  fail "preflight failed: ${REMOTE_OUTPUT}"
[ -f "$(run_root_path)/contract" ] || fail "preflight did not record the contract"
run_remote "${REMOTE_ARGS[@]}"
[ "${REMOTE_STATUS}" -eq 0 ] ||
  fail "identical preflight rerun failed: ${REMOTE_OUTPUT}"
[ ! -e "$(run_root_path)/failures.log" ] ||
  fail "successful preflight wrote failure evidence"
pass "preflight is idempotent for an unchanged run contract"

build_args preflight
REMOTE_ARGS[6]=3333333333333333333333333333333333333333333333333333333333333333
run_remote "${REMOTE_ARGS[@]}"
[ "${REMOTE_STATUS}" -ne 0 ] || fail "changed run contract was accepted"
assert_contains "${REMOTE_OUTPUT}" "run contract"
[ -f "$(run_root_path)/failures.log" ] ||
  fail "changed run contract did not record failure evidence"
assert_contains "$(cat "$(run_root_path)/failures.log")" "action=preflight"
pass "changed run contract fails closed with recorded evidence"

new_case
build_args preflight
REMOTE_ARGS[5]=4444444444444444444444444444444444444444444444444444444444444444
run_remote "${REMOTE_ARGS[@]}"
[ "${REMOTE_STATUS}" -ne 0 ] || fail "source identity mismatch was accepted"
failure_evidence="$(cat "$(run_root_path)/failures.log")"
assert_contains "${failure_evidence}" "action=preflight"
assert_contains "${failure_evidence}" "status=1"
assert_not_contains "${failure_evidence}" "${SECRET_MARKER}"
assert_not_contains "${failure_evidence}" "${MACHINE_ID_FILE}"
pass "die paths record redacted run-scoped failure evidence"

# --- heredoc delivery and stdin discipline -----------------------------------

new_case
build_args bootstrap
run_remote "${REMOTE_ARGS[@]}"
[ "${REMOTE_STATUS}" -eq 0 ] || fail "bootstrap failed: ${REMOTE_OUTPUT}"
script_deliveries=0
detached_calls=0
for stdin_file in $(ssh_stdin_files); do
  if [ -s "${stdin_file}" ]; then
    script_deliveries=$((script_deliveries + 1))
    assert_contains "$(cat "${stdin_file}")" "glm53-remote-script:"
    assert_contains "$(cat "${stdin_file}")" "set -eu"
  else
    detached_calls=$((detached_calls + 1))
  fi
done
[ "${script_deliveries}" -ge 9 ] ||
  fail "remote script bytes did not reach ssh (${script_deliveries} deliveries)"
[ "${detached_calls}" -ge 3 ] ||
  fail "non-script ssh calls did not detach stdin (${detached_calls} calls)"
grep -Fq 'glm53-remote-script:worker-identity' "${SSH_DIR}"/stdin.* ||
  fail "worker identity script was never delivered"
grep -Fq 'glm53-remote-script:worker-bundle-verify' "${SSH_DIR}"/stdin.* ||
  fail "worker bundle verification script was never delivered"
pass "remote scripts arrive on ssh stdin and other calls detach stdin"

# --- worker verification bundle ---------------------------------------------

bundle_root="$(run_root_path)/bundle"
bundle_files="$(cd "${bundle_root}" && find . -type f | sort | sed 's|^\./||')"
[ "${bundle_files}" = "manifests/draft.json
manifests/target.json
tools/artifact_manifest.py
tools/verify_hf_cache.py" ] ||
  fail "worker bundle content is not the minimal required set: ${bundle_files}"
python3 "${PKG}/tools/artifact_manifest.py" verify \
  "${bundle_root}" "$(run_root_path)/bundle.manifest.json" >/dev/null ||
  fail "worker bundle does not verify against its generated manifest"
bootstrap_commands="$(cat "${COMMAND_LOG}")"
assert_contains "${bootstrap_commands}" "rsync <"
assert_contains "${bootstrap_commands}" "--partial"
assert_contains "${bootstrap_commands}" "--append-verify"
assert_contains "${bootstrap_commands}" "192.0.2.11:${WORKER_ROOT}/.runtime/prepare/${RUN_ID}/bundle/"
assert_not_contains "${bootstrap_commands}" "rm <"
verify_script="$(grep -Fl 'glm53-remote-script:worker-bundle-verify' "${SSH_DIR}"/stdin.* | head -1)"
verify_argv="${verify_script%stdin.*}argv.${verify_script##*stdin.}"
assert_contains "$(cat "${verify_argv}")" "${MANIFEST_TOOL_DIGEST}"
assert_contains "$(cat "${verify_argv}")" "${VERIFIER_DIGEST}"
assert_contains "$(cat "${verify_argv}")" "StrictHostKeyChecking=yes"
assert_contains "$(cat "${verify_argv}")" "UserKnownHostsFile=${FABRIC_KNOWN_HOSTS}"
assert_not_contains "$(cat "${verify_argv}")" "accept-new"
pass "bootstrap ships a digest-verified minimal worker bundle"

new_case
build_args bootstrap
REMOTE_ARGS[20]=5555555555555555555555555555555555555555555555555555555555555555
run_remote "${REMOTE_ARGS[@]}"
[ "${REMOTE_STATUS}" -ne 0 ] || fail "wrong verifier digest was accepted"
assert_not_contains "$(cat "${COMMAND_LOG}")" "rsync <"
pass "bootstrap refuses to ship artifacts whose digests do not match"

new_case
build_args bootstrap
export GLM53_FAKE_SSH_FAIL_MATCH='glm53-remote-script:worker-identity'
export GLM53_FAKE_SSH_FAIL_STATUS=7
run_remote "${REMOTE_ARGS[@]}"
[ "${REMOTE_STATUS}" -eq 7 ] ||
  fail "worker identity failure exited ${REMOTE_STATUS}, expected 7"
assert_not_contains "$(cat "${COMMAND_LOG}")" "rsync <"
identity_failure="$(cat "$(run_root_path)/failures.log")"
assert_contains "${identity_failure}" "status=7"
assert_not_contains "${identity_failure}" "${SECRET_MARKER}"
unset GLM53_FAKE_SSH_FAIL_MATCH GLM53_FAKE_SSH_FAIL_STATUS
pass "worker identity failures propagate with the original exit status"

# --- ordered patch series ----------------------------------------------------

new_case
build_args build
run_remote "${REMOTE_ARGS[@]}"
[ "${REMOTE_STATUS}" -eq 0 ] || fail "build failed: ${REMOTE_OUTPUT}"
patch_order="$(
  grep -F 'git <' "${COMMAND_LOG}" |
    grep -F 'apply' |
    sed 's|.*/runtime/patches/||;s|>$||'
)"
[ "${patch_order}" = "bravo.patch
bravo.patch
alpha.patch
alpha.patch" ] ||
  fail "patch series was not applied in declared order: ${patch_order}"
pass "build applies exactly the declared ordered patch series"

new_case
build_args build
printf 'tampered\n' >"${PKG}/runtime/patches/alpha.patch"
run_remote "${REMOTE_ARGS[@]}"
[ "${REMOTE_STATUS}" -ne 0 ] || fail "tampered patch series member was accepted"
assert_contains "${REMOTE_OUTPUT}" "patch series"
assert_not_contains "$(cat "${COMMAND_LOG}")" "docker <build"
pass "build rejects a patch series member whose bytes changed"

# --- resumable rerun with the same run identifier ---------------------------

new_case
build_args build
export GLM53_FAKE_DOCKER_BUILD_STATUS=1
export GLM53_FAKE_IMAGE_PRESENT=0
run_remote "${REMOTE_ARGS[@]}"
[ "${REMOTE_STATUS}" -ne 0 ] || fail "failed image build was reported as success"
[ -f "$(run_root_path)/failures.log" ] ||
  fail "failed image build did not record evidence"
[ -d "$(run_root_path)/stage/source" ] ||
  fail "failed image build removed its staged source tree"
assert_not_contains "$(cat "${COMMAND_LOG}")" "rm <"

unset GLM53_FAKE_DOCKER_BUILD_STATUS
export GLM53_FAKE_IMAGE_PRESENT=1
: >"${COMMAND_LOG}"
run_remote "${REMOTE_ARGS[@]}"
[ "${REMOTE_STATUS}" -eq 0 ] ||
  fail "same-run-id rerun after failure did not resume: ${REMOTE_OUTPUT}"
resume_commands="$(cat "${COMMAND_LOG}")"
assert_not_contains "${resume_commands}" "git <clone"
assert_contains "${resume_commands}" "docker <save"
[ -f "$(run_root_path)/image.tar" ] || fail "resumed rerun produced no image export"

: >"${COMMAND_LOG}"
run_remote "${REMOTE_ARGS[@]}"
[ "${REMOTE_STATUS}" -eq 0 ] ||
  fail "verified rerun failed: ${REMOTE_OUTPUT}"
verified_commands="$(cat "${COMMAND_LOG}")"
assert_not_contains "${verified_commands}" "docker <save"
assert_not_contains "${verified_commands}" "docker <build"
assert_not_contains "${verified_commands}" "git <clone"
assert_not_contains "${verified_commands}" "rm <"
pass "image build resumes for the same run ID without redoing verified work"

new_case
build_args build
run_remote "${REMOTE_ARGS[@]}"
[ "${REMOTE_STATUS}" -eq 0 ] || fail "baseline build failed: ${REMOTE_OUTPUT}"
/bin/rm -f "${DOCKER_STATE}/image.present"
: >"${COMMAND_LOG}"
run_remote "${REMOTE_ARGS[@]}"
[ "${REMOTE_STATUS}" -eq 0 ] ||
  fail "verified export did not restore its source image: ${REMOTE_OUTPUT}"
restored_commands="$(cat "${COMMAND_LOG}")"
assert_contains "${restored_commands}" "docker <load --input $(run_root_path)/image.tar"
assert_not_contains "${restored_commands}" "docker <build"
pass "verified export restores a pruned source image before distribution"

export GLM53_FAKE_SOURCE_IMAGE_ID=sha256:conflicting-source
: >"${COMMAND_LOG}"
run_remote "${REMOTE_ARGS[@]}"
[ "${REMOTE_STATUS}" -ne 0 ] || fail "conflicting restored image identity was accepted"
assert_contains "${REMOTE_OUTPUT}" "runtime image identifier mismatch"
assert_not_contains "$(cat "${COMMAND_LOG}")" "docker <build"
assert_not_contains "$(cat "${COMMAND_LOG}")" "docker <load"
unset GLM53_FAKE_SOURCE_IMAGE_ID

export GLM53_FAKE_OWNER=conflicting-owner
: >"${COMMAND_LOG}"
run_remote "${REMOTE_ARGS[@]}"
[ "${REMOTE_STATUS}" -ne 0 ] || fail "conflicting restored image owner was accepted"
assert_contains "${REMOTE_OUTPUT}" "runtime image owner label mismatch"
assert_not_contains "$(cat "${COMMAND_LOG}")" "docker <load"
export GLM53_FAKE_OWNER="${IMAGE_OWNER}"

export GLM53_FAKE_IMAGE_LAYERS='["sha256:conflicting-layer"]'
: >"${COMMAND_LOG}"
run_remote "${REMOTE_ARGS[@]}"
[ "${REMOTE_STATUS}" -ne 0 ] || fail "conflicting restored image layers were accepted"
assert_contains "${REMOTE_OUTPUT}" "runtime image RootFS layers mismatch"
assert_not_contains "$(cat "${COMMAND_LOG}")" "docker <load"
unset GLM53_FAKE_IMAGE_LAYERS
pass "verified export rejects conflicting source image identity, labels, and layers"

new_case
build_args build
run_remote "${REMOTE_ARGS[@]}"
[ "${REMOTE_STATUS}" -eq 0 ] || fail "baseline build failed: ${REMOTE_OUTPUT}"
printf 'corrupt\n' >"$(run_root_path)/image.tar"
: >"${COMMAND_LOG}"
run_remote "${REMOTE_ARGS[@]}"
[ "${REMOTE_STATUS}" -ne 0 ] || fail "corrupt completed image export was accepted"
[ -f "$(run_root_path)/image.tar" ] ||
  fail "corrupt completed image export was deleted"
[ "$(cat "$(run_root_path)/image.tar")" = corrupt ] ||
  fail "corrupt completed image export was overwritten"
assert_not_contains "$(cat "${COMMAND_LOG}")" "rm <"
pass "corrupt completed artifacts are rejected without deletion"

# --- model verification, reuse, and promotion -------------------------------

new_case
build_args target-model
python3 "${CACHE_TOOL}" "${SOURCE_CACHE}" fake/target "${REVISION}" >/dev/null
run_remote "${REMOTE_ARGS[@]}"
[ "${REMOTE_STATUS}" -eq 0 ] ||
  fail "verified final cache was not reused: ${REMOTE_OUTPUT}"
assert_not_contains "$(cat "${COMMAND_LOG}")" "hf <"
pass "a fully verified final model cache is reused without downloading"

new_case
build_args target-model
python3 "${CACHE_TOOL}" "${SOURCE_CACHE}" fake/target "${REVISION}" >/dev/null
tampered_blob="${SOURCE_CACHE}/models--fake--target/snapshots/${REVISION}/model.safetensors"
printf 'tampered' >"$(cd "$(dirname "${tampered_blob}")" && readlink "${tampered_blob}" | sed "s|^|$(dirname "${tampered_blob}")/|")"
run_remote "${REMOTE_ARGS[@]}"
[ "${REMOTE_STATUS}" -ne 0 ] || fail "invalid final model cache was accepted"
assert_contains "${REMOTE_OUTPUT}" "will not be overwritten"
[ -d "${SOURCE_CACHE}/models--fake--target" ] ||
  fail "invalid final model cache was deleted"
assert_not_contains "$(cat "${COMMAND_LOG}")" "rm <"
pass "an invalid final model cache is never overwritten or deleted"

new_case
build_args target-model
run_remote "${REMOTE_ARGS[@]}"
[ "${REMOTE_STATUS}" -eq 0 ] || fail "model preparation failed: ${REMOTE_OUTPUT}"
assert_contains "$(cat "${COMMAND_LOG}")" "hf <download fake/target"
[ -d "${SOURCE_CACHE}/models--fake--target/snapshots/${REVISION}" ] ||
  fail "verified staging cache was not promoted"
[ ! -e "${SOURCE_CACHE}/.glm53-stage-${RUN_ID}-target-model/models--fake--target" ] ||
  fail "promotion left the staged repository in place"
assert_not_contains "$(cat "${COMMAND_LOG}")" "rm <"
pass "model staging is verified then atomically promoted"

new_case
build_args target-model
export GLM53_FAKE_HF_STATUS=1
staging_root="${SOURCE_CACHE}/.glm53-stage-${RUN_ID}-target-model"
mkdir -p "${staging_root}"
printf 'partial-download' >"${staging_root}/partial.bin"
partial_size="$(wc -c <"${staging_root}/partial.bin" | tr -d ' ')"
run_remote "${REMOTE_ARGS[@]}"
[ "${REMOTE_STATUS}" -ne 0 ] || fail "failed download was reported as success"
[ -f "${staging_root}/partial.bin" ] ||
  fail "interrupted download partial was deleted"
[ "$(wc -c <"${staging_root}/partial.bin" | tr -d ' ')" = "${partial_size}" ] ||
  fail "interrupted download partial was modified"
assert_not_contains "$(cat "${COMMAND_LOG}")" "rm <"
[ -f "$(run_root_path)/failures.log" ] ||
  fail "failed download did not record evidence"
unset GLM53_FAKE_HF_STATUS
pass "interrupted transfers and their evidence are preserved"

# --- distribution promotion failures ----------------------------------------

new_case
build_args distribute
run_remote bootstrap "${REMOTE_ARGS[@]:1}"
[ "${REMOTE_STATUS}" -eq 0 ] || fail "bootstrap failed: ${REMOTE_OUTPUT}"
run_remote build "${REMOTE_ARGS[@]:1}"
[ "${REMOTE_STATUS}" -eq 0 ] || fail "build failed: ${REMOTE_OUTPUT}"
run_remote target-model "${REMOTE_ARGS[@]:1}"
[ "${REMOTE_STATUS}" -eq 0 ] || fail "target model failed: ${REMOTE_OUTPUT}"
run_remote draft-model "${REMOTE_ARGS[@]:1}"
[ "${REMOTE_STATUS}" -eq 0 ] || fail "draft model failed: ${REMOTE_OUTPUT}"
: >"${COMMAND_LOG}"
run_remote "${REMOTE_ARGS[@]}"
[ "${REMOTE_STATUS}" -eq 0 ] || fail "distribute failed: ${REMOTE_OUTPUT}"
distribute_commands="$(cat "${COMMAND_LOG}")"
assert_contains "${distribute_commands}" "192.0.2.11:${WORKER_ROOT}/.runtime/prepare/${RUN_ID}/image.tar.partial"
assert_contains "${distribute_commands}" "192.0.2.13:${WORKER_CACHE}/.glm53-stage-${RUN_ID}-draft-model/models--fake--draft/"
grep -Fq 'glm53-remote-script:target-model-promote' "${SSH_DIR}"/stdin.* ||
  fail "target model promotion script was never delivered"
promote_script="$(grep -Fl 'glm53-remote-script:target-model-promote' "${SSH_DIR}"/stdin.* | head -1)"
assert_contains "$(cat "${promote_script}")" "artifact bundle"
pass "distribution transfers and promotion scripts use exact worker paths"

new_case
build_args distribute
run_remote bootstrap "${REMOTE_ARGS[@]:1}"
[ "${REMOTE_STATUS}" -eq 0 ] || fail "bootstrap failed: ${REMOTE_OUTPUT}"
run_remote build "${REMOTE_ARGS[@]:1}"
[ "${REMOTE_STATUS}" -eq 0 ] || fail "build failed: ${REMOTE_OUTPUT}"
run_remote target-model "${REMOTE_ARGS[@]:1}"
[ "${REMOTE_STATUS}" -eq 0 ] || fail "target model failed: ${REMOTE_OUTPUT}"
run_remote draft-model "${REMOTE_ARGS[@]:1}"
[ "${REMOTE_STATUS}" -eq 0 ] || fail "draft model failed: ${REMOTE_OUTPUT}"
: >"${COMMAND_LOG}"
export GLM53_FAKE_SSH_FAIL_MATCH='glm53-remote-script:target-model-promote'
export GLM53_FAKE_SSH_FAIL_STATUS=23
run_remote "${REMOTE_ARGS[@]}"
[ "${REMOTE_STATUS}" -eq 23 ] ||
  fail "promotion failure exited ${REMOTE_STATUS}, expected 23"
promotion_failure="$(cat "$(run_root_path)/failures.log")"
assert_contains "${promotion_failure}" "status=23"
assert_not_contains "${promotion_failure}" "${SECRET_MARKER}"
assert_not_contains "$(cat "${COMMAND_LOG}")" "rm <"
[ -f "$(run_root_path)/image.tar" ] ||
  fail "promotion failure discarded the verified image export"
unset GLM53_FAKE_SSH_FAIL_MATCH GLM53_FAKE_SSH_FAIL_STATUS
pass "worker promotion failures propagate and preserve verified artifacts"

printf 'Remote prepare contract passed.\n'

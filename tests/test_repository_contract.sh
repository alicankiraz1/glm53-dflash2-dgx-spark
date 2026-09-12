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

required_files="
.gitignore
.gitattributes
LICENSE
NOTICE
THIRD_PARTY_NOTICES.md
README.md
SECURITY.md
CONTRIBUTING.md
CODE_OF_CONDUCT.md
docs/design.md
docs/superpowers/plans/2026-08-28-glm53-dflash2-dgx-spark-package.md
tools/node_probe.py
tests/test_node_probe.py
tools/artifact_manifest.py
tools/verify_hf_cache.py
lib/prepare.sh
lib/prepare_remote.sh
lib/validate.sh
tools/api_validation.py
tools/benchmark.py
runtime/Containerfile
runtime/patches/series.json
runtime/patches/sglang-glm53-gb10-tilelang.patch
manifests/glm53-target-aa28e1f5.json
manifests/glm53-draft-7d74cdd8.json
tests/test_artifact_manifest.py
tests/test_verify_hf_cache.py
tests/test_prepare.sh
tests/test_repository_contract.sh
tests/test_api_validation.py
tests/test_benchmark.py
tests/test_validate.sh
tests/fixtures/api/chat.needle.ok.json
tests/fixtures/api/metrics.ok.txt
tests/fixtures/benchmark/c1-samples.json
tests/fixtures/benchmark/c4-samples.json
"

for required_file in ${required_files}; do
  [ -f "${required_file}" ] || fail "required file is missing: ${required_file}"
done
pass "all required files exist"

ignored_paths="
.state/run.json
.runtime/cluster.env
config/cluster.json
artifacts/model.tar
artifacts/model.tar.gz
artifacts/model.tgz
artifacts/model.zip
artifacts/model.sqsh
artifacts/model.sif
artifacts/model.safetensors
artifacts/model.gguf
artifacts/model.bin
artifacts/model.pt
artifacts/model.pth
logs/launch.log
tools/__pycache__/validator.pyc
.env
.env.local
secrets/deploy.key
secrets/api.token
results/validation/latest.json
"

for ignored_path in ${ignored_paths}; do
  git check-ignore -q "${ignored_path}" ||
    fail ".gitignore does not ignore required path: ${ignored_path}"
done

if git check-ignore -q "results/reference/validated-profile.json"; then
  fail ".gitignore must allow curated results/reference/ artifacts"
fi
pass ".gitignore enforces the repository artifact boundary"

forbidden_pattern='fixture-''private-node|gh''[opusr]_|github''_pat_|hf''_[A-Za-z0-9]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY-----'

scan_forbidden_file() {
  grep -IiqE "${forbidden_pattern}" "$1"
}

scanner_seed_file="$(mktemp "${TMPDIR:-/tmp}/repository-contract-seed.XXXXXX")"
candidate_file_list="$(mktemp "${TMPDIR:-/tmp}/repository-contract-candidates.XXXXXX")"
cleanup_scanner_files() {
  rm -f "${scanner_seed_file}" "${candidate_file_list}"
}
trap cleanup_scanner_files EXIT HUP INT TERM

printf '%s%s\n' 'fixture-' 'private-node' >"${scanner_seed_file}"
if scan_forbidden_file "${scanner_seed_file}"; then
  :
else
  scanner_status=$?
  [ "${scanner_status}" -eq 1 ] ||
    fail "redaction scanner failed while checking its seeded fixture"
  fail "redaction scanner did not detect its seeded forbidden value"
fi

set +e
scan_forbidden_file "${scanner_seed_file}.missing" 2>/dev/null
scanner_error_status=$?
set -e
[ "${scanner_error_status}" -gt 1 ] ||
  fail "redaction scanner swallowed an actual grep error"
pass "redaction scanner detects forbidden content and preserves errors"

git ls-files --cached --others --exclude-standard >"${candidate_file_list}" ||
  fail "could not enumerate repository candidates"
while IFS= read -r candidate_file; do
  [ -f "${candidate_file}" ] || continue
  if scan_forbidden_file "${candidate_file}"; then
    fail "blocked fixture or credential marker found in repository candidate: ${candidate_file}"
  else
    scanner_status=$?
    [ "${scanner_status}" -eq 1 ] ||
      fail "redaction scanner failed for repository candidate: ${candidate_file}"
  fi
done <"${candidate_file_list}"
pass "repository candidates contain no blocked fixture or credential markers"

for documentation_file in README.md THIRD_PARTY_NOTICES.md; do
  grep -Fq 'LibertAIDAI/GLM-5.3-Flash-NVFP4' "${documentation_file}" ||
    fail "${documentation_file} is missing the target model repository ID"
  grep -Fq 'incoai/GLM-5.3-Flash-DFlash2' "${documentation_file}" ||
    fail "${documentation_file} is missing the draft model repository ID"
  grep -Fq 'MIT License' "${documentation_file}" ||
    fail "${documentation_file} is missing the exact target license name"
  grep -Fq 'Creative Commons Attribution-NonCommercial-NoDerivatives 4.0 International' "${documentation_file}" ||
    fail "${documentation_file} is missing the exact draft license name"
done
pass "model repository IDs and exact license names are documented"

for sglang_notice_file in NOTICE README.md THIRD_PARTY_NOTICES.md; do
  grep -Fq 'SGLang' "${sglang_notice_file}" ||
    fail "${sglang_notice_file} is missing SGLang attribution"
  grep -Fq 'Apache License 2.0' "${sglang_notice_file}" ||
    fail "${sglang_notice_file} is missing the SGLang license boundary"
done
if ! grep -Fiq 'container image contents are not' THIRD_PARTY_NOTICES.md ||
  ! grep -Fiq 'exhaustively licensed by this notice' THIRD_PARTY_NOTICES.md; then
  fail "THIRD_PARTY_NOTICES.md overstates the container image license review"
fi
grep -Fq 'Contributor Covenant, version 2.1' CODE_OF_CONDUCT.md ||
  fail "CODE_OF_CONDUCT.md is missing Contributor Covenant version attribution"
grep -Fq 'Creative Commons Attribution 4.0 International Public License' CODE_OF_CONDUCT.md ||
  fail "CODE_OF_CONDUCT.md is missing the Contributor Covenant license"
pass "SGLang and Contributor Covenant attribution boundaries are documented"

implementation_plan='docs/superpowers/plans/2026-08-28-glm53-dflash2-dgx-spark-package.md'
grep -Fq "initializes \`APPLY=0\` at process start" "${implementation_plan}" ||
  fail "implementation plan does not initialize apply consent internally"
grep -Fq "unsets any inherited \`APPLY\`" "${implementation_plan}" ||
  fail "implementation plan does not discard environment-derived apply consent"
grep -Fq "only an explicit command-line \`--apply\` sets \`APPLY=1\`" "${implementation_plan}" ||
  fail "implementation plan does not require command-line apply consent"
pass "later CLI contract rejects environment-derived apply consent"

grep -Fq -- "- Create: \`tools/node_probe.py\`" "${implementation_plan}" ||
  fail "Task 2 plan does not list the extracted node probe module"
grep -Fq -- "\`run_ssh(argv, timeout_seconds) -> SSHExecution\`" \
  "${implementation_plan}" ||
  fail "Task 2 plan does not define the standard-library SSH runner interface"
pass "Task 2 plan lists extracted probe and SSH runner interfaces"

for task_three_path in \
  "tools/verify_hf_cache.py" \
  "lib/prepare_remote.sh" \
  "manifests/glm53-target-aa28e1f5.json" \
  "manifests/glm53-draft-7d74cdd8.json"; do
  grep -Fq -- "- Create: \`${task_three_path}\`" "${implementation_plan}" ||
    fail "Task 3 plan does not list ${task_three_path}"
done
grep -Fq "source-side dedicated fabric known-hosts" "${implementation_plan}" ||
  fail "Task 3 plan does not define the strict direct-fabric SSH contract"
grep -Fq "exact printed plan digest" "${implementation_plan}" ||
  fail "Task 3 plan does not define the stale-plan apply gate"
pass "Task 3 plan lists the complete prepare contract"

grep -Fq 'exactly four NVIDIA DGX Spark nodes' README.md ||
  fail "README.md does not state the exact four-node scope"
grep -Fq 'exactly four NVIDIA DGX Spark nodes' docs/design.md ||
  fail "docs/design.md does not state the exact four-node scope"
grep -Fq '131072 is the validated context ceiling' README.md ||
  fail "README.md does not state the validated context ceiling"
grep -Fq '131072 is the validated context ceiling' docs/design.md ||
  fail "docs/design.md does not state the validated context ceiling"
pass "hardware scope and validated context ceiling are explicit"

oversized_files="$(find . -path './.git' -prune -o -type f -size +5120k -print)"
[ -z "${oversized_files}" ] ||
  fail "files larger than 5 MiB found:
${oversized_files}"
pass "working tree contains no files larger than 5 MiB"

printf 'Repository contract passed.\n'

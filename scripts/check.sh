#!/usr/bin/env bash

# Offline software checks only. Shell tests provide their own fake runtimes.
set -eu

CHECK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly CHECK_ROOT
cd "${CHECK_ROOT}"

command -v python3 >/dev/null 2>&1 || { printf 'python3 is required\n' >&2; exit 1; }
command -v shellcheck >/dev/null 2>&1 || { printf 'shellcheck is required\n' >&2; exit 1; }
export PYTHONDONTWRITEBYTECODE=1

python3 -m unittest discover -s tests -v
for check_test in tests/test_*.sh; do
  /bin/bash "${check_test}"
done

check_shell_files=(glm53-spark lib/*.sh scripts/*.sh tests/*.sh)
for check_file in "${check_shell_files[@]}"; do
  /bin/bash -n "${check_file}"
done
shellcheck --shell=bash --external-sources "${check_shell_files[@]}"
git diff --check
printf 'Offline software checks passed. GPU runtime was not exercised.\n'

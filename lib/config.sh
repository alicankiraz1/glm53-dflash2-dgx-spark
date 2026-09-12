#!/usr/bin/env bash

_GLM53_CONFIG_LIB_DIR="$(
  cd "$(dirname "${BASH_SOURCE[0]}")" && pwd
)"
readonly _GLM53_CONFIG_LIB_DIR
readonly _GLM53_CONFIG_TOOL="${_GLM53_CONFIG_LIB_DIR}/../tools/config_state.py"

config_validate() {
  local config_path=${1:-${_GLM53_CONFIG_PATH}}
  local lock_path=${2:-${_GLM53_LOCK_PATH}}
  python3 "${_GLM53_CONFIG_TOOL}" validate \
    --config "${config_path}" \
    --lock "${lock_path}"
}

config_export() {
  local config_field=$1
  local config_path=${2:-${_GLM53_CONFIG_PATH}}
  python3 "${_GLM53_CONFIG_TOOL}" export \
    --config "${config_path}" \
    --field "${config_field}"
}

config_export_doctor() {
  local config_path=$1
  python3 "${_GLM53_CONFIG_TOOL}" doctor-export \
    --config "${config_path}"
}

config_export_prepare() {
  local config_path=$1
  local lock_path=$2
  python3 "${_GLM53_CONFIG_TOOL}" prepare-export \
    --config "${config_path}" \
    --lock "${lock_path}"
}

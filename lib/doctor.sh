#!/usr/bin/env bash

_GLM53_DOCTOR_LIB_DIR="$(
  cd "$(dirname "${BASH_SOURCE[0]}")" && pwd
)"
readonly _GLM53_DOCTOR_LIB_DIR
readonly _GLM53_FABRIC_TOOL="${_GLM53_DOCTOR_LIB_DIR}/../tools/fabric_probe.py"
readonly _GLM53_NODE_PROBE_TOOL="${_GLM53_DOCTOR_LIB_DIR}/../tools/node_probe.py"

_DOCTOR_CONNECT_TIMEOUT_SECONDS=10
_DOCTOR_COMMAND_TIMEOUT_SECONDS=60
_DOCTOR_FINDING_ENTRIES=
_DOCTOR_FIRST_FINDING=1

# Callers that own a different validated connect timeout, such as the
# lifecycle module, pass it explicitly so the strict option set stays single
# sourced instead of being duplicated per caller.
doctor_ssh_options() {
  local doctor_known_hosts_path=$1
  local doctor_connect_timeout=${2:-${_DOCTOR_CONNECT_TIMEOUT_SECONDS}}
  printf '%s\n' \
    -o \
    BatchMode=yes \
    -o \
    StrictHostKeyChecking=yes \
    -o \
    "UserKnownHostsFile=${doctor_known_hosts_path}" \
    -o \
    GlobalKnownHostsFile=/dev/null \
    -o \
    "ConnectTimeout=${doctor_connect_timeout}" \
    -o \
    ConnectionAttempts=1 \
    -o \
    LogLevel=ERROR
}

_doctor_add_finding() {
  local doctor_finding_id=$1
  local doctor_finding_ok=$2
  local doctor_finding_summary=$3
  local doctor_separator=
  if [ "${_DOCTOR_FIRST_FINDING}" -eq 0 ]; then
    doctor_separator=,
  fi
  _DOCTOR_FINDING_ENTRIES="${_DOCTOR_FINDING_ENTRIES}${doctor_separator}{\"id\":\"${doctor_finding_id}\",\"ok\":${doctor_finding_ok},\"summary\":\"${doctor_finding_summary}\"}"
  _DOCTOR_FIRST_FINDING=0
}

_doctor_append_json_entry() {
  local doctor_current_entries=$1
  local doctor_new_entry=$2
  if [ -n "${doctor_current_entries}" ]; then
    printf '%s,%s' "${doctor_current_entries}" "${doctor_new_entry}"
  else
    printf '%s' "${doctor_new_entry}"
  fi
}

_doctor_build_remote_command() {
  local doctor_mode=$1
  shift
  python3 "${_GLM53_NODE_PROBE_TOOL}" \
    encode \
    --mode "${doctor_mode}" \
    -- \
    "$@"
}

_doctor_run_ssh() {
  local doctor_alias=$1
  local doctor_remote_command=$2
  shift 2
  python3 "${_GLM53_NODE_PROBE_TOOL}" \
    run-ssh \
    --timeout-seconds "${_DOCTOR_COMMAND_TIMEOUT_SECONDS}" \
    -- \
    ssh "$@" "${doctor_alias}" "${doctor_remote_command}" </dev/null 2>/dev/null
}

doctor_run() {
  local doctor_config_path=$1
  local doctor_lock_path=$2
  local doctor_output_format=${DOCTOR_OUTPUT_FORMAT:-text}
  local doctor_tool
  local doctor_tool_ready=1
  local doctor_probe_ready=1
  local doctor_known_hosts_raw
  local doctor_known_hosts_path=
  local doctor_known_hosts_state=false
  local doctor_index
  local doctor_node_id
  local doctor_alias
  local doctor_remote_root
  local doctor_role
  local doctor_remote_command
  local doctor_remote_output
  local doctor_normalized
  local doctor_base_entries=
  local doctor_reachability_entries=
  local doctor_base_json
  local doctor_reachability_json
  local doctor_merged_nodes
  local doctor_remote_findings
  local doctor_remote_inner
  local doctor_all_findings
  local doctor_probe_count=0
  local doctor_status
  local doctor_target
  local doctor_targets_output
  local doctor_fabric_cidr
  local doctor_api_port
  local doctor_distributed_port
  local doctor_value
  local doctor_value_index
  local -a doctor_node_ids
  local -a doctor_aliases
  local -a doctor_roles
  local -a doctor_remote_roots
  local -a doctor_ssh_options_array
  local -a doctor_fabric_targets
  local -a doctor_config_values

  _DOCTOR_FINDING_ENTRIES=
  _DOCTOR_FIRST_FINDING=1

  if [ "${DOCTOR_CONFIG_VALIDATED:-0}" != "1" ] &&
    ! config_validate "${doctor_config_path}" "${doctor_lock_path}"; then
    return 2
  fi

  for doctor_tool in bash python3 ssh ssh-keygen; do
    if command -v "${doctor_tool}" >/dev/null 2>&1; then
      _doctor_add_finding \
        "local.tool.${doctor_tool}" \
        true \
        "${doctor_tool} is available"
    else
      _doctor_add_finding \
        "local.tool.${doctor_tool}" \
        false \
        "${doctor_tool} is unavailable"
      doctor_tool_ready=0
    fi
  done

  doctor_config_values=()
  while IFS= read -r -d '' doctor_value; do
    doctor_config_values[${#doctor_config_values[@]}]="${doctor_value}"
  done < <(config_export_doctor "${doctor_config_path}")
  [ "${#doctor_config_values[@]}" -eq 22 ] || return 2
  doctor_known_hosts_raw=${doctor_config_values[0]}
  _DOCTOR_CONNECT_TIMEOUT_SECONDS=${doctor_config_values[1]}
  _DOCTOR_COMMAND_TIMEOUT_SECONDS=${doctor_config_values[2]}
  doctor_fabric_cidr=${doctor_config_values[3]}
  doctor_api_port=${doctor_config_values[4]}
  doctor_distributed_port=${doctor_config_values[5]}

  if doctor_known_hosts_path="$(
    python3 "${_GLM53_FABRIC_TOOL}" \
      expand-known-hosts \
      --path "${doctor_known_hosts_raw}" 2>/dev/null
  )"; then
    if python3 "${_GLM53_FABRIC_TOOL}" \
      known-hosts-state \
      --path "${doctor_known_hosts_path}" >/dev/null 2>&1; then
      doctor_known_hosts_state=true
      _doctor_add_finding \
        local.known_hosts.state \
        true \
        "known-hosts file is a protected regular file"
    else
      _doctor_add_finding \
        local.known_hosts.state \
        false \
        "known-hosts file is missing or unsafe"
      doctor_probe_ready=0
    fi
  else
    _doctor_add_finding \
      local.known_hosts.state \
      false \
      "known-hosts path cannot be expanded"
    doctor_probe_ready=0
  fi

  doctor_index=0
  while [ "${doctor_index}" -lt 4 ]; do
    doctor_value_index=$((6 + doctor_index * 4))
    doctor_node_id=${doctor_config_values[doctor_value_index]}
    doctor_alias=${doctor_config_values[doctor_value_index + 1]}
    doctor_role=${doctor_config_values[doctor_value_index + 2]}
    doctor_remote_root=${doctor_config_values[doctor_value_index + 3]}
    doctor_node_ids[doctor_index]="${doctor_node_id}"
    doctor_aliases[doctor_index]="${doctor_alias}"
    doctor_roles[doctor_index]="${doctor_role}"
    doctor_remote_roots[doctor_index]="${doctor_remote_root}"
    if [ "${doctor_known_hosts_state}" = true ] &&
      command -v ssh-keygen >/dev/null 2>&1 &&
      ssh-keygen \
        -F "${doctor_alias}" \
        -f "${doctor_known_hosts_path}" >/dev/null 2>&1; then
      _doctor_add_finding \
        "local.known_hosts.alias.${doctor_node_id}" \
        true \
        "SSH alias has a pinned host key"
    else
      _doctor_add_finding \
        "local.known_hosts.alias.${doctor_node_id}" \
        false \
        "SSH alias lacks a pinned host key"
      doctor_probe_ready=0
    fi
    doctor_index=$((doctor_index + 1))
  done

  doctor_ssh_options_array=()
  while IFS= read -r doctor_target; do
    doctor_ssh_options_array[${#doctor_ssh_options_array[@]}]="${doctor_target}"
  done < <(doctor_ssh_options "${doctor_known_hosts_path}")

  if [ "${doctor_tool_ready}" -eq 0 ]; then
    doctor_probe_ready=0
  fi
  if [ "${doctor_probe_ready}" -eq 1 ]; then
    doctor_index=0
    while [ "${doctor_index}" -lt 4 ]; do
      if doctor_remote_command="$(
        _doctor_build_remote_command \
          node \
          "${doctor_node_ids[${doctor_index}]}" \
          "${doctor_roles[${doctor_index}]}" \
          "${doctor_remote_roots[${doctor_index}]}" \
          "${doctor_fabric_cidr}" \
          "${doctor_api_port}" \
          "${doctor_distributed_port}" 2>/dev/null
      )" &&
        doctor_remote_output="$(
        _doctor_run_ssh \
          "${doctor_aliases[${doctor_index}]}" \
          "${doctor_remote_command}" \
          "${doctor_ssh_options_array[@]}"
      )" &&
        doctor_normalized="$(
          printf '%s' "${doctor_remote_output}" |
            python3 "${_GLM53_FABRIC_TOOL}" \
              normalize-node \
              --expected-node-id "${doctor_node_ids[${doctor_index}]}" \
              2>/dev/null
        )"; then
        doctor_base_entries="$(
          _doctor_append_json_entry \
            "${doctor_base_entries}" \
            "${doctor_normalized}"
        )"
        doctor_probe_count=$((doctor_probe_count + 1))
      fi
      doctor_index=$((doctor_index + 1))
    done
  fi

  doctor_base_json="[${doctor_base_entries}]"
  if [ "${doctor_probe_count}" -eq 4 ]; then
    if doctor_targets_output="$(
      printf '%s' "${doctor_base_json}" |
        python3 "${_GLM53_FABRIC_TOOL}" extract-addresses 2>/dev/null
    )"; then
      doctor_fabric_targets=()
      while IFS= read -r doctor_target; do
        [ -n "${doctor_target}" ] || continue
        doctor_fabric_targets[${#doctor_fabric_targets[@]}]="${doctor_target}"
      done <<EOF
${doctor_targets_output}
EOF

      doctor_index=0
      while [ "${doctor_index}" -lt 4 ]; do
        if doctor_remote_command="$(
          _doctor_build_remote_command \
            reachability \
            "${doctor_node_ids[${doctor_index}]}" \
            "${doctor_fabric_targets[@]}" 2>/dev/null
        )" &&
          doctor_remote_output="$(
            _doctor_run_ssh \
              "${doctor_aliases[${doctor_index}]}" \
              "${doctor_remote_command}" \
              "${doctor_ssh_options_array[@]}"
          )" &&
          doctor_normalized="$(
            printf '%s' "${doctor_remote_output}" |
              python3 "${_GLM53_FABRIC_TOOL}" \
                normalize-reachability \
                --expected-node-id "${doctor_node_ids[${doctor_index}]}" \
                2>/dev/null
          )"; then
          doctor_reachability_entries="$(
            _doctor_append_json_entry \
              "${doctor_reachability_entries}" \
              "${doctor_normalized}"
          )"
        fi
        doctor_index=$((doctor_index + 1))
      done
    else
      _doctor_add_finding \
        doctor.pipeline.extract_addresses \
        false \
        "fabric address extraction failed"
    fi
  fi

  doctor_reachability_json="[${doctor_reachability_entries}]"
  if doctor_merged_nodes="$(
    printf '{"nodes":%s,"reachability":%s}' \
      "${doctor_base_json}" \
      "${doctor_reachability_json}" |
      python3 "${_GLM53_FABRIC_TOOL}" merge-reachability 2>/dev/null
  )"; then
    :
  else
    _doctor_add_finding \
      doctor.pipeline.merge_reachability \
      false \
      "fabric reachability merge failed"
    doctor_merged_nodes=${doctor_base_json}
  fi
  if doctor_remote_findings="$(
    printf '%s' "${doctor_merged_nodes}" |
      python3 "${_GLM53_FABRIC_TOOL}" \
        evaluate \
        --config "${doctor_config_path}" \
        --lock "${doctor_lock_path}" 2>/dev/null
  )"; then
    :
  else
    _doctor_add_finding \
      doctor.pipeline.evaluate \
      false \
      "fabric evaluation failed"
    doctor_remote_findings='[]'
  fi
  doctor_remote_inner=${doctor_remote_findings#\[}
  doctor_remote_inner=${doctor_remote_inner%\]}
  if [ -n "${_DOCTOR_FINDING_ENTRIES}" ] &&
    [ -n "${doctor_remote_inner}" ]; then
    doctor_all_findings="[${_DOCTOR_FINDING_ENTRIES},${doctor_remote_inner}]"
  else
    doctor_all_findings="[${_DOCTOR_FINDING_ENTRIES}${doctor_remote_inner}]"
  fi

  if printf '%s' "${doctor_all_findings}" |
    python3 "${_GLM53_FABRIC_TOOL}" \
      render \
      --format "${doctor_output_format}"; then
    return 0
  else
    doctor_status=$?
    return "${doctor_status}"
  fi
}

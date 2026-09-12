#!/usr/bin/env bash

common_die() {
  local common_message=$1
  local common_status=${2:-1}
  printf 'glm53-spark: error: %s\n' "${common_message}" >&2
  return "${common_status}"
}

# Run IDs identify immutable prepare and lifecycle artifacts, so every caller
# must accept exactly one timestamp-and-entropy representation.
common_validate_run_id() {
  local common_run_id=$1
  local common_suffix
  case "${common_run_id}" in
    [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9].[0-9][0-9][0-9][0-9][0-9][0-9]Z-*) ;;
    *) return 2 ;;
  esac
  common_suffix=${common_run_id#*-}
  case "${common_suffix}" in
    *[!0-9a-f]*) return 2 ;;
  esac
  [ "${#common_suffix}" -eq 32 ] || return 2
}

common_print_action() {
  local common_argument
  printf 'PLAN:'
  for common_argument in "$@"; do
    printf ' %q' "${common_argument}"
  done
  printf '\n'
}

common_plan_or_apply() {
  local common_apply_allowed=$1
  local common_preflight_passed=$2
  shift 2

  [ "$#" -gt 0 ] || {
    common_die "an action command is required"
    return 1
  }

  if [ "${common_apply_allowed}" != "1" ]; then
    common_print_action "$@"
    return 0
  fi
  if [ "${common_preflight_passed}" != "1" ]; then
    common_die "preflight gate did not pass"
    return 1
  fi

  printf 'APPLY: preflight passed\n'
  "$@"
}

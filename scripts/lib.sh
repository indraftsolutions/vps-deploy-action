#!/usr/bin/env bash

set -Eeuo pipefail

die() {
  echo "$*" >&2
  exit 1
}

require_var() {
  local variable_name="$1"
  [[ -n "${!variable_name:-}" ]] || die "Required variable is not set: ${variable_name}"
}

require_file() {
  local file_path="$1"
  [[ -f "${file_path}" ]] || die "File not found: ${file_path}"
}

require_nonempty_file() {
  local file_path="$1"
  require_file "${file_path}"
  [[ -s "${file_path}" ]] || die "File is empty: ${file_path}"
}

git_short_sha() {
  local sha="${GITHUB_SHA:-unknown000000000000}"
  printf '%s\n' "${sha:0:12}"
}

normalize_bool() {
  case "${1:-}" in
    true|TRUE|True|1|yes|YES|on|ON)
      printf 'true\n'
      ;;
    false|FALSE|False|0|no|NO|off|OFF)
      printf 'false\n'
      ;;
    '')
      printf '\n'
      ;;
    *)
      printf '%s\n' "${1}"
      ;;
  esac
}

write_output() {
  local key="$1"
  local value="$2"
  printf '%s=%s\n' "${key}" "${value}" >>"${GITHUB_OUTPUT}"
}

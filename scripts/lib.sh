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

validate_runtime_env_mode() {
  case "${1:-}" in
    spring|django)
      ;;
    *)
      die "Unsupported app_runtime_env_mode: ${1:-<empty>}"
      ;;
  esac
}

quote_env_value() {
  local raw_value="$1"
  printf "'%s'" "$(printf '%s' "${raw_value}" | sed "s/'/'\\\\''/g")"
}

render_runtime_env_template() {
  local template_path="$1"
  local output_path="$2"
  local line=""

  require_nonempty_file "${template_path}"
  : >"${output_path}"

  while IFS= read -r line || [[ -n "${line}" ]]; do
    if [[ "${line}" =~ ^[[:space:]]*$ || "${line}" =~ ^[[:space:]]*# ]]; then
      printf '%s\n' "${line}" >>"${output_path}"
      continue
    fi

    if [[ "${line}" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      local key="${BASH_REMATCH[1]}"
      local value="${BASH_REMATCH[2]}"

      if [[ "${value}" =~ ^\$\{secret:([A-Za-z_][A-Za-z0-9_]*)\}$ ]]; then
        local secret_name="${BASH_REMATCH[1]}"
        [[ "${!secret_name+x}" == "x" ]] || die "Runtime env template references missing secret: ${secret_name}"
        printf '%s=%s\n' "${key}" "$(quote_env_value "${!secret_name}")" >>"${output_path}"
        continue
      fi

      if [[ "${value}" == *'${secret:'* ]]; then
        die "Secret placeholders must occupy the full value for ${key}"
      fi

      if [[ "${value}" == *'${file:'* ]]; then
        if [[ "${value}" =~ ^\$\{file:/[^}]+\}$ ]]; then
          printf '%s\n' "${line}" >>"${output_path}"
          continue
        fi
        die "File placeholders must occupy the full value for ${key}"
      fi
    fi

    printf '%s\n' "${line}" >>"${output_path}"
  done <"${template_path}"
}

write_output() {
  local key="$1"
  local value="$2"
  printf '%s=%s\n' "${key}" "${value}" >>"${GITHUB_OUTPUT}"
}

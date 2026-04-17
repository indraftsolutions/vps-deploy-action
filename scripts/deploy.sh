#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh disable=SC1091
source "${SCRIPT_DIR}/lib.sh"

prepare() {
  require_var INPUT_ARTIFACT_EXTENSION
  require_var INPUT_ARTIFACT_PREFIX
  require_var INPUT_DEPLOY_CONFIG_PATH
  require_var INPUT_DEPLOY_SCRIPT_PATH
  require_var INPUT_REMOTE_SERVICE_NAME

  local artifact_path="${INPUT_ARTIFACT_PATH:-}"
  if [[ -n "${artifact_path}" ]]; then
    info "Using caller-provided local artifact path: ${artifact_path}"
  else
    require_var INPUT_ARTIFACT_FILE_NAME
    require_var INPUT_ARTIFACT_NAME
    artifact_path="downloaded-artifact/${INPUT_ARTIFACT_FILE_NAME}"
    info "Using downloaded GitHub artifact ${INPUT_ARTIFACT_NAME}: ${artifact_path}"
  fi
  require_nonempty_file "${artifact_path}"

  [[ "${INPUT_ARTIFACT_EXTENSION}" == .* ]] || die "artifact_extension must start with a dot: ${INPUT_ARTIFACT_EXTENSION}"

  local resolved_ssh_port resolved_deploy_config_path resolved_deploy_script_path resolved_deploy_environment
  local resolved_health_path_override resolved_force_switch resolved_rollback_on_post_switch_failure resolved_migration_mode_override
  local resolved_deploy_incoming_dir

  resolved_ssh_port="${INPUT_SSH_PORT:-22}"
  resolved_deploy_config_path="${INPUT_DEPLOY_CONFIG_PATH}"
  resolved_deploy_script_path="${INPUT_DEPLOY_SCRIPT_PATH}"
  resolved_deploy_environment="${INPUT_DEPLOY_ENVIRONMENT:-${INPUT_REMOTE_SERVICE_NAME}}"
  resolved_deploy_incoming_dir="${INPUT_DEPLOY_INCOMING_DIR:-}"
  local resolved_app_runtime_env_template_path="${INPUT_APP_RUNTIME_ENV_TEMPLATE_PATH:-}"
  local resolved_app_runtime_env_mode="${INPUT_APP_RUNTIME_ENV_MODE:-}"
  local resolved_health_path_override="${INPUT_HEALTH_PATH_OVERRIDE:-}"
  local resolved_migration_mode_override="${INPUT_MIGRATION_MODE_OVERRIDE:-}"
  local resolved_sync_runtime_env="${INPUT_SYNC_RUNTIME_ENV:-true}"

  resolved_sync_runtime_env="$(normalize_bool "${resolved_sync_runtime_env}")"
  [[ -n "${resolved_sync_runtime_env}" ]] || resolved_sync_runtime_env="true"

  if [[ -n "${resolved_app_runtime_env_template_path}" ]]; then
    require_nonempty_file "${resolved_app_runtime_env_template_path}"
    [[ -n "${resolved_app_runtime_env_mode}" ]] || die "app_runtime_env_mode is required when app_runtime_env_template_path is set"
    validate_runtime_env_mode "${resolved_app_runtime_env_mode}"
    [[ "${resolved_app_runtime_env_mode}" == "${INPUT_REMOTE_SERVICE_NAME}" ]] || {
      die "app_runtime_env_mode (${resolved_app_runtime_env_mode}) must match remote_service_name (${INPUT_REMOTE_SERVICE_NAME})"
    }
  elif [[ -n "${resolved_app_runtime_env_mode}" ]]; then
    die "app_runtime_env_mode cannot be set without app_runtime_env_template_path"
  fi

  if [[ -n "${INPUT_FORCE_SWITCH:-}" ]]; then
    resolved_force_switch="$(normalize_bool "${INPUT_FORCE_SWITCH}")"
  else
    resolved_force_switch="false"
  fi

  if [[ -n "${INPUT_ROLLBACK_ON_POST_SWITCH_FAILURE:-}" ]]; then
    resolved_rollback_on_post_switch_failure="$(normalize_bool "${INPUT_ROLLBACK_ON_POST_SWITCH_FAILURE}")"
  else
    resolved_rollback_on_post_switch_failure="true"
  fi

  local release_id build_timestamp remote_artifact_path
  release_id="$(date -u '+%Y%m%d%H%M%S')_$(git_short_sha)"
  build_timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  write_output "artifact_file" "${artifact_path}"
  write_output "release_id" "${release_id}"
  write_output "build_timestamp" "${build_timestamp}"
  write_output "ssh_port" "${resolved_ssh_port}"
  write_output "deploy_config_path" "${resolved_deploy_config_path}"
  write_output "deploy_script_path" "${resolved_deploy_script_path}"
  write_output "deploy_environment" "${resolved_deploy_environment}"
  write_output "deploy_incoming_dir" "${resolved_deploy_incoming_dir}"
  write_output "app_runtime_env_template_path" "${resolved_app_runtime_env_template_path}"
  write_output "app_runtime_env_mode" "${resolved_app_runtime_env_mode}"
  write_output "sync_runtime_env" "${resolved_sync_runtime_env}"
  write_output "health_path_override" "${resolved_health_path_override}"
  write_output "force_switch" "${resolved_force_switch}"
  write_output "rollback_on_post_switch_failure" "${resolved_rollback_on_post_switch_failure}"
  write_output "migration_mode_override" "${resolved_migration_mode_override}"
}

deploy() {
  info "Starting remote deploy transport for service ${REMOTE_SERVICE_NAME:-<unset>}"
  require_var ARTIFACT_FILE
  require_var BUILD_TIMESTAMP
  require_var DEPLOY_CONFIG_PATH
  require_var DEPLOY_SCRIPT_PATH
  require_var RELEASE_ID
  require_var ARTIFACT_EXTENSION
  require_var ARTIFACT_PREFIX
  require_var REMOTE_ARTIFACT_ARG
  require_var REMOTE_SERVICE_NAME
  require_var ROLLBACK_ON_POST_SWITCH_FAILURE
  require_var SSH_CONNECT_TIMEOUT_SECONDS
  require_var SSH_HOST
  require_var SSH_PORT
  require_var SSH_PRIVATE_KEY
  require_var SSH_USER

  require_nonempty_file "${ARTIFACT_FILE}"
  info "Local artifact resolved at ${ARTIFACT_FILE}"
  info "SSH target ${SSH_USER}@${SSH_HOST}:${SSH_PORT} with timeout ${SSH_CONNECT_TIMEOUT_SECONDS}s"
  if [[ -n "${SSH_KNOWN_HOSTS:-}" ]]; then
    info "Using provided SSH known_hosts secret"
  else
    warn "SSH known_hosts secret is empty; falling back to ssh-keyscan"
  fi
  if [[ -n "${APP_RUNTIME_ENV_TEMPLATE_PATH:-}" ]]; then
    info "Runtime env sync enabled for mode ${APP_RUNTIME_ENV_MODE:-<unset>} using template ${APP_RUNTIME_ENV_TEMPLATE_PATH}"
  else
    info "Runtime env sync disabled"
  fi

  umask 077
  mkdir -p "${HOME}/.ssh"
  info "Writing deploy SSH key"
  printf '%s\n' "${SSH_PRIVATE_KEY}" >"${HOME}/.ssh/deploy_key"

  local host_key_source="provided-secret"
  if [[ -n "${SSH_KNOWN_HOSTS:-}" ]]; then
    info "Writing provided known_hosts entries"
    printf '%s\n' "${SSH_KNOWN_HOSTS}" >"${HOME}/.ssh/known_hosts"
  else
    info "Discovering SSH host key with ssh-keyscan"
    timeout "${SSH_CONNECT_TIMEOUT_SECONDS}" \
      ssh-keyscan -p "${SSH_PORT}" -H "${SSH_HOST}" >"${HOME}/.ssh/known_hosts"
    [[ -s "${HOME}/.ssh/known_hosts" ]] || die "Failed to discover SSH host key for ${SSH_HOST}:${SSH_PORT}"
    host_key_source="ssh-keyscan"
  fi

  chmod 0600 "${HOME}/.ssh/deploy_key" "${HOME}/.ssh/known_hosts"
  printf 'host_key_source=%s\n' "${host_key_source}" >>"${GITHUB_ENV}"
  info "SSH host key source: ${host_key_source}"

  local ssh_opts=(
    -i "${HOME}/.ssh/deploy_key"
    -p "${SSH_PORT}"
    -o BatchMode=yes
    -o ConnectionAttempts=1
    -o ConnectTimeout="${SSH_CONNECT_TIMEOUT_SECONDS}"
    -o IdentitiesOnly=yes
    -o StrictHostKeyChecking=yes
  )
  local scp_opts=(
    -i "${HOME}/.ssh/deploy_key"
    -P "${SSH_PORT}"
    -o BatchMode=yes
    -o ConnectionAttempts=1
    -o ConnectTimeout="${SSH_CONNECT_TIMEOUT_SECONDS}"
    -o IdentitiesOnly=yes
    -o StrictHostKeyChecking=yes
  )

  local deploy_incoming_dir="${DEPLOY_INCOMING_DIR:-}"
  if [[ -z "${deploy_incoming_dir}" ]]; then
    info "Resolving remote incoming directory"
    local resolve_cmd=(
      sudo
      -n
      "${DEPLOY_SCRIPT_PATH}"
      --service "${REMOTE_SERVICE_NAME}"
      --config "${DEPLOY_CONFIG_PATH}"
      --print-incoming-dir
    )
    local resolve_cmd_string
    printf -v resolve_cmd_string '%q ' "${resolve_cmd[@]}"
    # shellcheck disable=SC2029
    deploy_incoming_dir="$(ssh "${ssh_opts[@]}" "${SSH_USER}@${SSH_HOST}" "${resolve_cmd_string% }")"
  fi
  [[ -n "${deploy_incoming_dir}" ]] || die "Resolved deploy incoming directory is empty for service ${REMOTE_SERVICE_NAME}"
  info "Resolved remote incoming directory: ${deploy_incoming_dir}"

  # shellcheck disable=SC2153
  local artifact_prefix="${ARTIFACT_PREFIX}"
  # shellcheck disable=SC2153
  local artifact_extension="${ARTIFACT_EXTENSION}"
  # shellcheck disable=SC2153
  local release_id="${RELEASE_ID}"
  local remote_artifact_path="${deploy_incoming_dir}/${artifact_prefix}-${release_id}${artifact_extension}"
  write_output "remote_artifact_path" "${remote_artifact_path}"
  info "Remote artifact path: ${remote_artifact_path}"

  # shellcheck disable=SC2029
  info "Ensuring remote incoming directory exists"
  ssh "${ssh_opts[@]}" "${SSH_USER}@${SSH_HOST}" "mkdir -p '${deploy_incoming_dir}'"
  info "Uploading artifact to remote host"
  scp "${scp_opts[@]}" "${ARTIFACT_FILE}" "${SSH_USER}@${SSH_HOST}:${remote_artifact_path}"

  if [[ "${SYNC_RUNTIME_ENV:-true}" == "true" && -n "${APP_RUNTIME_ENV_TEMPLATE_PATH:-}" ]]; then
    require_var APP_RUNTIME_ENV_MODE
    validate_runtime_env_mode "${APP_RUNTIME_ENV_MODE}"
    info "Rendering runtime env template locally"

    local rendered_runtime_env_file
    rendered_runtime_env_file="$(mktemp)"
    render_runtime_env_template "${APP_RUNTIME_ENV_TEMPLATE_PATH}" "${rendered_runtime_env_file}"

    local remote_runtime_env_template_path="${deploy_incoming_dir}/runtime-env-${REMOTE_SERVICE_NAME}-${release_id}.env"
    info "Uploading rendered runtime env template to ${remote_runtime_env_template_path}"
    scp "${scp_opts[@]}" "${rendered_runtime_env_file}" "${SSH_USER}@${SSH_HOST}:${remote_runtime_env_template_path}"
    rm -f "${rendered_runtime_env_file}"

    local remote_render_cmd=(
      sudo
      -n
      "${DEPLOY_SCRIPT_PATH}"
      --config "${DEPLOY_CONFIG_PATH}"
      --render-runtime-env
      --mode "${APP_RUNTIME_ENV_MODE}"
      --template "${remote_runtime_env_template_path}"
    )
    local remote_render_cmd_string
    printf -v remote_render_cmd_string '%q ' "${remote_render_cmd[@]}"
    # shellcheck disable=SC2029
    info "Rendering runtime env on remote host"
    ssh "${ssh_opts[@]}" "${SSH_USER}@${SSH_HOST}" "${remote_render_cmd_string% }; render_status=\$?; rm -f '${remote_runtime_env_template_path}'; exit \${render_status}"
  fi

  local remote_cmd=(
    sudo
    -n
    "${DEPLOY_SCRIPT_PATH}"
    --service "${REMOTE_SERVICE_NAME}"
    --config "${DEPLOY_CONFIG_PATH}"
    "${REMOTE_ARTIFACT_ARG}" "${remote_artifact_path}"
    --release-id "${RELEASE_ID}"
    --git-sha "${GITHUB_SHA}"
    --git-branch "${GITHUB_REF_NAME}"
    --actor "${GITHUB_ACTOR}"
    --build-timestamp "${BUILD_TIMESTAMP}"
    --rollback-on-post-switch-failure "${ROLLBACK_ON_POST_SWITCH_FAILURE}"
  )

  if [[ -n "${HEALTH_PATH_OVERRIDE:-}" ]]; then
    remote_cmd+=(--health-path-override "${HEALTH_PATH_OVERRIDE}")
  fi

  if [[ -n "${MIGRATION_MODE_OVERRIDE:-}" ]]; then
    remote_cmd+=(--migration-mode "${MIGRATION_MODE_OVERRIDE}")
  fi

  if [[ "${FORCE_SWITCH:-false}" == "true" ]]; then
    remote_cmd+=(--force-switch)
  fi

  local remote_cmd_string
  printf -v remote_cmd_string '%q ' "${remote_cmd[@]}"
  # shellcheck disable=SC2029
  info "Invoking remote deploy command"
  ssh "${ssh_opts[@]}" "${SSH_USER}@${SSH_HOST}" "${remote_cmd_string% }"
  info "Remote deploy command completed"
}

summary() {
  require_var ARTIFACT_FILE
  require_var BUILD_TIMESTAMP
  require_var COMMIT_SIGNATURE_POLICY
  require_var DEPLOY_ENVIRONMENT
  require_var DEPLOY_SCRIPT_PATH
  require_var FORCE_SWITCH
  require_var RELEASE_ID
  require_var REMOTE_ARTIFACT_ARG
  require_var REMOTE_DEPLOY_OUTCOME
  require_var REMOTE_SERVICE_NAME
  require_var ROLLBACK_ON_POST_SWITCH_FAILURE
  require_var SSH_CONNECT_TIMEOUT_SECONDS

  {
    echo "## ${DEPLOY_ENVIRONMENT} Deployment"
    echo ""
    echo "- Environment: \`${DEPLOY_ENVIRONMENT}\`"
    echo "- Release ID: \`${RELEASE_ID}\`"
    echo "- Git SHA: \`${GITHUB_SHA}\`"
    echo "- Branch: \`${GITHUB_REF_NAME}\`"
    echo "- Actor: \`${GITHUB_ACTOR}\`"
    echo "- Build timestamp: \`${BUILD_TIMESTAMP}\`"
    echo "- Commit signature policy: \`${COMMIT_SIGNATURE_POLICY}\`"
    echo "- Commit signature status: \`${COMMIT_SIGNATURE_STATUS:-<unreported>}\`"
    echo "- Commit signature verified: \`${COMMIT_SIGNATURE_VERIFIED:-<unreported>}\`"
    echo "- Commit signature reason: \`${COMMIT_SIGNATURE_REASON:-<unreported>}\`"
    echo "- Commit signature verified at: \`${COMMIT_SIGNATURE_VERIFIED_AT:-<unreported>}\`"
    echo "- Local artifact file: \`${ARTIFACT_FILE}\`"
    echo "- Remote artifact path: \`${REMOTE_ARTIFACT_PATH:-<unavailable>}\`"
    echo "- Remote deploy script: \`${DEPLOY_SCRIPT_PATH}\`"
    echo "- Remote service: \`${REMOTE_SERVICE_NAME}\`"
    echo "- Runtime env sync: \`${SYNC_RUNTIME_ENV}\`"
    echo "- Runtime env template path: \`${APP_RUNTIME_ENV_TEMPLATE_PATH:-<disabled>}\`"
    echo "- Runtime env mode: \`${APP_RUNTIME_ENV_MODE:-<disabled>}\`"
    echo "- Remote artifact arg: \`${REMOTE_ARTIFACT_ARG}\`"
    echo "- SSH host key source: \`${HOST_KEY_SOURCE:-unknown}\`"
    echo "- SSH connect timeout (seconds): \`${SSH_CONNECT_TIMEOUT_SECONDS}\`"
    echo "- Force switch: \`${FORCE_SWITCH}\`"
    echo "- Rollback on post-switch failure: \`${ROLLBACK_ON_POST_SWITCH_FAILURE}\`"
    echo "- Migration mode override: \`${MIGRATION_MODE_OVERRIDE:-<default>}\`"
    echo "- Health override: \`${HEALTH_PATH_OVERRIDE:-<default>}\`"
    echo "- Remote deploy step outcome: \`${REMOTE_DEPLOY_OUTCOME}\`"
  } >>"${GITHUB_STEP_SUMMARY}"
}

main() {
  local command="${1:-}"
  case "${command}" in
    prepare)
      prepare
      ;;
    deploy)
      deploy
      ;;
    summary)
      summary
      ;;
    *)
      die "Unknown command: ${command}"
      ;;
  esac
}

main "$@"

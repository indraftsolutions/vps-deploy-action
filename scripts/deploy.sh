#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "${SCRIPT_DIR}/lib.sh"

prepare() {
  require_var INPUT_ARTIFACT_FILE_NAME
  require_var INPUT_ARTIFACT_EXTENSION
  require_var INPUT_ARTIFACT_PREFIX
  require_var INPUT_SERVER_NAME
  require_var INPUT_REMOTE_SERVICE_NAME
  require_var INVENTORY_REPO_ROOT

  local artifact_path="downloaded-artifact/${INPUT_ARTIFACT_FILE_NAME}"
  require_nonempty_file "${artifact_path}"

  [[ "${INPUT_ARTIFACT_EXTENSION}" == .* ]] || die "artifact_extension must start with a dot: ${INPUT_ARTIFACT_EXTENSION}"

  [[ "${INPUT_SERVER_NAME}" =~ ^[A-Za-z0-9._-]+$ ]] || die "server_name contains invalid characters: ${INPUT_SERVER_NAME}"

  local inventory_path="${INVENTORY_REPO_ROOT}/ops/inventory/${INPUT_SERVER_NAME}.env"
  require_nonempty_file "${inventory_path}"

  set -a
  # shellcheck disable=SC1090
  source "${inventory_path}"
  set +a

  require_var SERVER_NAME
  require_var GITHUB_ENVIRONMENT
  require_var SERVER_ENV_FILE

  local server_env_path="${INVENTORY_REPO_ROOT}/${SERVER_ENV_FILE}"
  require_nonempty_file "${server_env_path}"

  set -a
  # shellcheck disable=SC1090
  source "${server_env_path}"
  set +a

  require_var ENABLE_SPRING_SERVICE
  require_var ENABLE_DJANGO_SERVICE
  require_var DEPLOY_CONFIG_PATH
  require_var DEPLOY_TOOLKIT_DIR

  local service_name="${INPUT_REMOTE_SERVICE_NAME}"
  local resolved_deploy_incoming_dir=""
  local inventory_health_path_override=""
  local inventory_force_switch="false"
  local inventory_rollback_on_post_switch_failure="true"
  local inventory_migration_mode_override=""

  case "${service_name}" in
    spring)
      [[ "$(normalize_bool "${ENABLE_SPRING_SERVICE}")" == "true" ]] || die "Inventory ${SERVER_NAME} does not enable Spring"
      resolved_deploy_incoming_dir="${DEPLOY_INCOMING_DIR:-}"
      inventory_health_path_override="${SPRING_HEALTH_PATH_OVERRIDE:-}"
      inventory_force_switch="$(normalize_bool "${SPRING_FORCE_SWITCH_DEFAULT:-false}")"
      inventory_rollback_on_post_switch_failure="$(normalize_bool "${SPRING_ROLLBACK_ON_POST_SWITCH_FAILURE_DEFAULT:-true}")"
      ;;
    django)
      [[ "$(normalize_bool "${ENABLE_DJANGO_SERVICE}")" == "true" ]] || die "Inventory ${SERVER_NAME} does not enable Django"
      resolved_deploy_incoming_dir="${DJANGO_DEPLOY_INCOMING_DIR:-}"
      inventory_health_path_override="${DJANGO_HEALTH_PATH_OVERRIDE:-}"
      inventory_force_switch="$(normalize_bool "${DJANGO_FORCE_SWITCH_DEFAULT:-false}")"
      inventory_rollback_on_post_switch_failure="$(normalize_bool "${DJANGO_ROLLBACK_ON_POST_SWITCH_FAILURE_DEFAULT:-true}")"
      inventory_migration_mode_override="${DJANGO_MIGRATION_MODE_OVERRIDE_DEFAULT:-}"
      ;;
    *)
      die "Unsupported remote service name: ${service_name}"
      ;;
  esac

  [[ -n "${resolved_deploy_incoming_dir}" ]] || die "Resolved deploy incoming directory is empty for service ${service_name}"

  local resolved_ssh_port resolved_deploy_config_path resolved_deploy_script_path resolved_deploy_environment
  local resolved_health_path_override resolved_force_switch resolved_rollback_on_post_switch_failure resolved_migration_mode_override

  resolved_ssh_port="${INPUT_SSH_PORT:-${SSH_PORT:-22}}"
  resolved_deploy_config_path="${INPUT_DEPLOY_CONFIG_PATH:-${DEPLOY_CONFIG_PATH}}"
  resolved_deploy_script_path="${INPUT_DEPLOY_SCRIPT_PATH:-${DEPLOY_TOOLKIT_DIR}/scripts/deploy.sh}"
  resolved_deploy_environment="${INPUT_DEPLOY_ENVIRONMENT:-${GITHUB_ENVIRONMENT}}"
  resolved_deploy_incoming_dir="${INPUT_DEPLOY_INCOMING_DIR:-${resolved_deploy_incoming_dir}}"
  resolved_health_path_override="${INPUT_HEALTH_PATH_OVERRIDE:-${inventory_health_path_override}}"
  resolved_migration_mode_override="${INPUT_MIGRATION_MODE_OVERRIDE:-${inventory_migration_mode_override}}"

  if [[ -n "${INPUT_FORCE_SWITCH:-}" ]]; then
    resolved_force_switch="$(normalize_bool "${INPUT_FORCE_SWITCH}")"
  else
    resolved_force_switch="${inventory_force_switch}"
  fi

  if [[ -n "${INPUT_ROLLBACK_ON_POST_SWITCH_FAILURE:-}" ]]; then
    resolved_rollback_on_post_switch_failure="$(normalize_bool "${INPUT_ROLLBACK_ON_POST_SWITCH_FAILURE}")"
  else
    resolved_rollback_on_post_switch_failure="${inventory_rollback_on_post_switch_failure}"
  fi

  local release_id build_timestamp remote_artifact_path
  release_id="$(date -u '+%Y%m%d%H%M%S')_$(git_short_sha)"
  build_timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  remote_artifact_path="${resolved_deploy_incoming_dir}/${INPUT_ARTIFACT_PREFIX}-${release_id}${INPUT_ARTIFACT_EXTENSION}"

  write_output "artifact_file" "${artifact_path}"
  write_output "release_id" "${release_id}"
  write_output "build_timestamp" "${build_timestamp}"
  write_output "remote_artifact_path" "${remote_artifact_path}"
  write_output "ssh_port" "${resolved_ssh_port}"
  write_output "deploy_config_path" "${resolved_deploy_config_path}"
  write_output "deploy_script_path" "${resolved_deploy_script_path}"
  write_output "deploy_environment" "${resolved_deploy_environment}"
  write_output "deploy_incoming_dir" "${resolved_deploy_incoming_dir}"
  write_output "health_path_override" "${resolved_health_path_override}"
  write_output "force_switch" "${resolved_force_switch}"
  write_output "rollback_on_post_switch_failure" "${resolved_rollback_on_post_switch_failure}"
  write_output "migration_mode_override" "${resolved_migration_mode_override}"
}

deploy() {
  require_var ARTIFACT_FILE
  require_var BUILD_TIMESTAMP
  require_var DEPLOY_CONFIG_PATH
  require_var DEPLOY_INCOMING_DIR
  require_var DEPLOY_SCRIPT_PATH
  require_var RELEASE_ID
  require_var REMOTE_ARTIFACT_ARG
  require_var REMOTE_ARTIFACT_PATH
  require_var REMOTE_SERVICE_NAME
  require_var ROLLBACK_ON_POST_SWITCH_FAILURE
  require_var SSH_CONNECT_TIMEOUT_SECONDS
  require_var SSH_HOST
  require_var SSH_PORT
  require_var SSH_PRIVATE_KEY
  require_var SSH_USER

  require_nonempty_file "${ARTIFACT_FILE}"

  umask 077
  mkdir -p "${HOME}/.ssh"
  printf '%s\n' "${SSH_PRIVATE_KEY}" >"${HOME}/.ssh/deploy_key"

  local host_key_source="provided-secret"
  if [[ -n "${SSH_KNOWN_HOSTS:-}" ]]; then
    printf '%s\n' "${SSH_KNOWN_HOSTS}" >"${HOME}/.ssh/known_hosts"
  else
    timeout "${SSH_CONNECT_TIMEOUT_SECONDS}" \
      ssh-keyscan -p "${SSH_PORT}" -H "${SSH_HOST}" >"${HOME}/.ssh/known_hosts"
    [[ -s "${HOME}/.ssh/known_hosts" ]] || die "Failed to discover SSH host key for ${SSH_HOST}:${SSH_PORT}"
    host_key_source="ssh-keyscan"
  fi

  chmod 0600 "${HOME}/.ssh/deploy_key" "${HOME}/.ssh/known_hosts"
  printf 'host_key_source=%s\n' "${host_key_source}" >>"${GITHUB_ENV}"

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

  ssh "${ssh_opts[@]}" "${SSH_USER}@${SSH_HOST}" "mkdir -p '${DEPLOY_INCOMING_DIR}'"
  scp "${scp_opts[@]}" "${ARTIFACT_FILE}" "${SSH_USER}@${SSH_HOST}:${REMOTE_ARTIFACT_PATH}"

  local remote_cmd=(
    sudo
    "${DEPLOY_SCRIPT_PATH}"
    --service "${REMOTE_SERVICE_NAME}"
    --config "${DEPLOY_CONFIG_PATH}"
    "${REMOTE_ARTIFACT_ARG}" "${REMOTE_ARTIFACT_PATH}"
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
  ssh "${ssh_opts[@]}" "${SSH_USER}@${SSH_HOST}" "${remote_cmd_string% }"
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
  require_var REMOTE_ARTIFACT_PATH
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
    echo "- Remote artifact path: \`${REMOTE_ARTIFACT_PATH}\`"
    echo "- Remote deploy script: \`${DEPLOY_SCRIPT_PATH}\`"
    echo "- Remote service: \`${REMOTE_SERVICE_NAME}\`"
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

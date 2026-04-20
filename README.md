# indraft-deploy-action

Public root-level GitHub Action for uploading a prepared deployment artifact to a VPS and invoking a remote deployment script.

This action is intended to be consumed by multiple application repositories, including repositories outside the `indraftsolutions` GitHub org. It is transport-only:

- it validates a local build artifact from the caller workspace
- it can still download a previously uploaded GitHub Actions artifact as a legacy fallback
- optionally renders a caller-owned runtime env template
- prepares SSH configuration
- uses the fixed bootstrap-installed deploy config and deploy script paths by default
- uploads the artifact and rendered runtime env template to a per-run remote transfer directory owned by the SSH user
- finalizes the rendered runtime env template into the canonical runtime env file
- invokes the remote deploy dispatcher
- cleans up the remote transfer directory
- writes a deployment summary

It does not own:

- GitHub Environment selection
- app build/package steps
- server bootstrap or maintenance

GitHub Environment selection must stay in the caller workflow because custom actions cannot set the job `environment`.

## Usage

```yaml
jobs:
  deploy:
    runs-on: ubuntu-latest
    environment:
      name: spring-production
    steps:
      - name: Checkout repository
        uses: actions/checkout@v4

      - name: Build artifact
        run: ./gradlew clean bootWar -Pprod -Pwar -Pprometheus --no-daemon

      - name: Locate artifact
        id: artifact
        shell: bash
        run: |
          set -Eeuo pipefail
          war_file="$(find build/libs -maxdepth 1 -type f -name '*.war' ! -name '*.war.original' | sort | head -n 1)"
          echo "path=${war_file}" >>"${GITHUB_OUTPUT}"

      - name: Deploy artifact
        uses: indraftsolutions/vps-deploy-action@v1
        env:
          INDRAFT_BASE64_SECRET: ${{ secrets.INDRAFT_BASE64_SECRET }}
          INDRAFT_MAIL_PASSWORD: ${{ secrets.INDRAFT_MAIL_PASSWORD }}
        with:
          artifact_path: ${{ steps.artifact.outputs.path }}
          artifact_extension: .war
          artifact_prefix: staging-war
          remote_artifact_arg: --war
          remote_service_name: spring
          deploy_environment: spring-production
          app_runtime_env_template_path: deploy/env/prod.spring.env
          app_runtime_env_mode: spring
          ssh_host: ${{ secrets.SERVER_SSH_HOST }}
          ssh_port: '22'
          ssh_user: ${{ secrets.SERVER_SSH_USER }}
          ssh_private_key: ${{ secrets.SERVER_SSH_PRIVATE_KEY }}
          ssh_known_hosts: ${{ secrets.SERVER_SSH_KNOWN_HOSTS }}
          force_switch: false
          rollback_on_post_switch_failure: true
```

## Required Inputs

- `artifact_path`
- `artifact_extension`
- `artifact_prefix`
- `remote_artifact_arg`
- `remote_service_name`
- `ssh_host`
- `ssh_user`
- `ssh_private_key`

## Optional Inputs

- `artifact_name`
- `artifact_file_name`
- `deploy_environment`
- `ssh_port`
- `ssh_known_hosts`
- `ssh_connect_timeout_seconds`
- `app_runtime_env_template_path`
- `app_runtime_env_mode`
- `sync_runtime_env`
- `deploy_incoming_dir` (deprecated; uploads now use a per-run remote transfer directory)
- `health_path_override`
- `force_switch`
- `rollback_on_post_switch_failure`
- `migration_mode_override`
- `deploy_config_path`
- `deploy_script_path`
- commit signature metadata inputs

## Contract

The caller workflow is expected to:

1. select the GitHub Environment before invoking this action
2. build or package the deployable artifact in the same job
3. pass the local artifact path via `artifact_path`
4. checkout the repository in the deploy job before using `app_runtime_env_template_path`
5. pass the environment-specific SSH secrets to this action
6. explicitly map any `${secret:NAME}` placeholders from the runtime env template into the action `env:` block
7. pass the remote SSH port when it differs from `22`

Legacy artifact download is still supported by omitting `artifact_path` and passing `artifact_name` plus `artifact_file_name`, but caller-owned local artifacts are preferred to avoid GitHub Actions artifact storage quota failures.

The target server is expected to:

- expose the canonical deploy config at `/etc/indraft/indraft.env`, unless the caller overrides `deploy_config_path`
- expose the canonical deploy script at `/opt/indraft/deploy/scripts/deploy.sh`, unless the caller overrides `deploy_script_path`
- support `sudo <deploy_script> --config <path> --render-runtime-env --mode <spring|django> --template <path>`
- accept the `remote_artifact_arg` flag, such as `--war` or `--artifact`
- handle the `--service`, `--config`, release metadata, and optional override flags

## Runtime Env Templates

Caller-owned runtime env templates are standard dotenv-style files committed in the app repo.

Supported placeholders:

- `${secret:NAME}`: resolved locally from the action environment
- `${file:/absolute/path}`: preserved during local rendering and resolved on the server into the final runtime env file

Rules:

- placeholders must occupy the full value
- `${secret:NAME}` fails before deploy if `NAME` is not mapped into the action environment
- `${file:/absolute/path}` fails on the server if the referenced file is missing or unreadable
- comments and blank lines are preserved

## Outputs

- `release_id`
- `build_timestamp`
- `artifact_file`
- `remote_artifact_path`

## Validation

This repo includes a lightweight CI workflow that validates:

- YAML parsing
- Bash syntax
- `git diff --check`

ShellCheck is run when available on the runner.

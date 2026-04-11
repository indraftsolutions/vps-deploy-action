# indraft-deploy-action

Public root-level GitHub Action for downloading a prepared deployment artifact, uploading it to a VPS, and invoking a remote deployment script without re-uploading it as a duplicate workflow artifact.

This action is intended to be consumed by multiple application repositories, including repositories outside the `indraftsolutions` GitHub org. It is transport-only:

- it downloads a previously uploaded GitHub Actions artifact
- validates it
- optionally renders a caller-owned runtime env template
- prepares SSH configuration
- uses the fixed bootstrap-installed deploy config and deploy script paths by default
- resolves the service-specific incoming upload directory on the server
- uploads the rendered runtime env template to the server and finalizes it into the canonical runtime env file
- uploads the artifact to the remote server
- invokes the remote deploy dispatcher
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

      - name: Deploy artifact
        uses: indraftsolutions/vps-deploy-action@v1
        env:
          INDRAFT_BASE64_SECRET: ${{ secrets.INDRAFT_BASE64_SECRET }}
          INDRAFT_MAIL_PASSWORD: ${{ secrets.INDRAFT_MAIL_PASSWORD }}
        with:
          artifact_name: spring-staging-war
          artifact_file_name: myapp.war
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

- `artifact_name`
- `artifact_file_name`
- `artifact_extension`
- `artifact_prefix`
- `remote_artifact_arg`
- `remote_service_name`
- `ssh_host`
- `ssh_user`
- `ssh_private_key`

## Optional Inputs

- `deploy_environment`
- `ssh_port`
- `ssh_known_hosts`
- `ssh_connect_timeout_seconds`
- `app_runtime_env_template_path`
- `app_runtime_env_mode`
- `sync_runtime_env`
- `deploy_incoming_dir`
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
2. upload the deployable artifact with `actions/upload-artifact`
3. checkout the repository in the deploy job before using `app_runtime_env_template_path`
4. pass the environment-specific SSH secrets to this action
5. explicitly map any `${secret:NAME}` placeholders from the runtime env template into the action `env:` block
6. pass the remote SSH port when it differs from `22`

The target server is expected to:

- expose the canonical deploy config at `/etc/indraft/indraft.env`, unless the caller overrides `deploy_config_path`
- expose the canonical deploy script at `/opt/indraft/deploy/scripts/deploy.sh`, unless the caller overrides `deploy_script_path`
- support `sudo <deploy_script> --service <service> --config <path> --print-incoming-dir`
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

# indraft-deploy-action

Public root-level GitHub Action for downloading a prepared deployment artifact, resolving deploy settings from the shared inventory repo, uploading the artifact to a VPS, and invoking the remote deployment script.

This action is intended to be consumed by multiple application repositories, including repositories outside the `indraftsolutions` GitHub org. It is transport-only:

- it downloads a previously uploaded GitHub Actions artifact
- it checks out the shared inventory repository
- it loads the target inventory file and its canonical server env
- it resolves deploy paths and service-specific defaults from inventory
- validates it
- prepares SSH configuration
- uploads the artifact to the remote server
- invokes the remote deploy dispatcher
- writes a deployment summary

It does not own:

- GitHub Environment selection
- app build/package steps
- server bootstrap or maintenance

GitHub Environment selection must stay in the caller workflow because custom actions cannot set the job `environment`. Inventory ownership stays in `indraft-infra`.

## Usage

```yaml
jobs:
  deploy:
    runs-on: ubuntu-latest
    environment:
      name: spring-production
    steps:
      - name: Deploy artifact
        uses: indraftsolutions/indraft-deploy-action@v1
        with:
          server_name: spring-prod
          artifact_name: spring-staging-war
          artifact_file_name: myapp.war
          artifact_extension: .war
          artifact_prefix: staging-war
          remote_artifact_arg: --war
          remote_service_name: spring
          ssh_host: ${{ secrets.SERVER_SSH_HOST }}
          ssh_user: ${{ secrets.SERVER_SSH_USER }}
          ssh_private_key: ${{ secrets.SERVER_SSH_PRIVATE_KEY }}
          ssh_known_hosts: ${{ secrets.SERVER_SSH_KNOWN_HOSTS }}
          force_switch: false
          rollback_on_post_switch_failure: true
```

## Required Inputs

- `server_name`
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

- `inventory_repository`
- `inventory_ref`
- `deploy_environment`
- `ssh_port`
- `ssh_known_hosts`
- `ssh_connect_timeout_seconds`
- `deploy_incoming_dir`
- `deploy_config_path`
- `deploy_script_path`
- `health_path_override`
- `force_switch`
- `rollback_on_post_switch_failure`
- `migration_mode_override`
- commit signature metadata inputs

## Contract

The caller workflow is expected to:

1. select the GitHub Environment before invoking this action
2. upload the deployable artifact with `actions/upload-artifact`
3. pass the environment-specific SSH secrets to this action

The action is expected to:

1. check out `indraft-infra` or another configured inventory repo
2. map `server_name` to `ops/inventory/<server_name>.env`
3. load the canonical shared server env referenced by that inventory
4. resolve service-specific deploy paths and defaults

The target server is expected to:

- expose the remote deploy script path resolved from inventory or supplied explicitly
- accept the `remote_artifact_arg` flag, such as `--war` or `--artifact`
- handle the `--service`, `--config`, release metadata, and optional override flags

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

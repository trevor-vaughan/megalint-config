# GitLab CI integration

Reusable GitLab CI job template for running the shared MegaLinter config
in any GitLab project.

## Quick start

Add to your project's `.gitlab-ci.yml`:

```yaml
include:
  - remote: 'https://raw.githubusercontent.com/trevor-vaughan/megalint-config/v1/ci/gitlab/megalint.yml'

megalint:
  extends: .megalint
  variables:
    MEGALINT_REF: 'v1'
    # Optional: cache via GitLab Dependency Proxy
    MEGALINTER_IMAGE: '${CI_DEPENDENCY_PROXY_GROUP_IMAGE_PREFIX}/trevor-vaughan/megalinter-custom-flavor:latest'
  rules:
    # Full-tree lint on default branch
    - if: '$CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH'
      variables:
        MEGALINT_VALIDATE_ALL_CODEBASE: 'true'
    # PR-diff lint everywhere else
    - when: on_success
```

`MEGALINT_REF` must match the ref in the `include:` URL — GitLab does not
expose to the running job which ref the included file came from.

## Available variables

| Variable                         | Default                                                  | Description                                       |
|----------------------------------|----------------------------------------------------------|---------------------------------------------------|
| `MEGALINT_WORKING_DIRECTORY`     | `$CI_PROJECT_DIR`                                        | Directory to lint.                                |
| `MEGALINT_VALIDATE_ALL_CODEBASE` | `'false'`                                                | Lint full tree (vs. PR diff).                     |
| `MEGALINTER_IMAGE`               | `ghcr.io/trevor-vaughan/megalinter-custom-flavor:latest` | Container image to run.                           |
| `MEGALINT_REPORTS_DIR`           | `$CI_PROJECT_DIR/megalinter-reports`                     | Where reports land on host.                       |
| `MEGALINT_PULL_POLICY`           | `missing`                                                | Engine `--pull=` policy.                          |
| `MEGALINT_REF`                   | `v1`                                                     | Ref of trevor-vaughan/megalint-config to clone.   |
| `MEGALINT_VERIFY`                | `''`                                                     | Set to `skip` to bypass attestation verification. |

## Manual verification

This repo isn't hosted on GitLab, so the template can't be CI-tested in
this repo. To verify changes:

1. Push the branch to a GitHub fork, note the branch name (e.g., `feature/x`).
2. In a sandbox GitLab project, set `.gitlab-ci.yml`:

   ```yaml
   include:
     - remote: 'https://raw.githubusercontent.com/<your-fork>/megalint-config/feature/x/ci/gitlab/megalint.yml'

   megalint:
     extends: .megalint
     variables:
       MEGALINT_REF: 'feature/x'
   ```

3. Push and observe the job run in the sandbox project's pipeline view.
4. Confirm:
   - `before_script` clones the runner without auth errors.
   - `script` produces `megalinter-reports/megalinter-report.sarif`.
   - `artifacts:` block uploads the reports and SARIF.
   - SARIF appears in the project's Security widget.

## Customization

- **Override `image:` / `services:`** in the caller if your runner doesn't
  support Docker-in-Docker (e.g., shell executor with `/var/run/docker.sock`
  bind-mounted). You then own installing `bash`, `git`, `curl` in
  `before_script`.
- **Add `variables: MEGALINT_REPORTS_DIR: 'reports'`** to land reports
  under a custom path (e.g., for matching another tool's expectations).

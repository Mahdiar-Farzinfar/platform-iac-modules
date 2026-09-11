# Pull Request

<!--
Thank you for contributing to platform-iac-modules.

Before opening this PR:
- PR title MUST follow Conventional Commits, e.g.:
  feat(kms): add multi-region key support
  fix(cloudtrail): correct bucket policy condition
  docs(scp): clarify deny-list examples
- Keep PRs small and focused on a single release domain when possible.
- This PR will feed release automation; commit messages and affected paths must be accurate.
-->

## Summary

<!-- What does this PR change, and why? Include the user/operational context. -->

## Release Impact

<!-- This section should align with release.yml domain detection and versioning. -->

### Affected Release Domain(s)

- [ ] `module/backend-bootstrap`
- [ ] `module/github-oidc`
- [ ] `module/kms`
- [ ] `module/log-archive-bucket`
- [ ] `module/cloudtrail`
- [ ] `module/guardduty`
- [ ] `module/scp`
- [ ] `root` / repository tooling / docs
- [ ] `image/devcontainer`

### Expected Version Bump

- [ ] `major`
- [ ] `minor`
- [ ] `patch`
- [ ] `none` / docs-only

### Breaking Changes

- [ ] No
- [ ] Yes

If yes, describe the migration path:

Include renamed/removed variables or outputs, resource replacement, provider version bump, state moves,
and any `moved` blocks or `terraform state mv` guidance.

## Related Issues

- Closes #
- Relates to #

## Type of Change

- [ ] `feat` — new feature / new module
- [ ] `fix` — bug fix
- [ ] `docs` — documentation only
- [ ] `refactor` — no functional change
- [ ] `test` — tests only
- [ ] `ci` / `chore` — pipeline, tooling, dependencies
- [ ] `BREAKING CHANGE` — requires a major version bump

## Plan / Test Evidence

<!-- Paste relevant, redacted evidence. Never include secrets, account IDs, ARNs with sensitive info, or state file contents. -->

<details>
<summary>terraform plan (relevant excerpt)</summary>

```text
(plan output)
```

</details>

<details>
<summary>terraform test / integration test output</summary>

```text
(test output)
```

</details>

## Checklist

### Release Alignment

- [ ] PR title follows [Conventional Commits](https://www.conventionalcommits.org/)
- [ ] Commit messages in this PR follow Conventional Commits and reflect the intended bump
- [ ] Affected path(s) map cleanly to one release domain
- [ ] No unintended cross-domain changes

### General

- [ ] Self-review completed; no leftover debug code or commented-out blocks
- [ ] No secrets, credentials, or sensitive identifiers in code, examples, or PR description

### Terraform Quality

- [ ] `terraform fmt -check -recursive` passes
- [ ] `terraform validate` passes for all affected modules
- [ ] `tflint` passes (see `tooling/.tflint.hcl`)
- [ ] Pre-commit hooks pass locally (`pre-commit run --all-files`)
- [ ] Variables and outputs have `description`; types are explicit; `sensitive = true` where appropriate
- [ ] Provider/Terraform version constraints in `versions.tf` are intentional and minimal

### Security & Compliance

- [ ] `checkov` / `trivy` scans pass, or findings are suppressed with inline justification
- [ ] Change complies with `docs/security-baseline.md` (encryption, least privilege, logging)
- [ ] IAM policies follow least privilege; no wildcard `*` actions/resources without justification

### Tests & Examples

- [ ] `tests/tftest.hcl` updated or added for changed behavior
- [ ] Integration tests updated (if the module has `integration-test.go`)
- [ ] `examples/basic` still works and reflects the new behavior
- [ ] Smoke tests pass locally (`tests/smoke/`) on at least one platform

### Documentation

- [ ] Module `README.md` regenerated via terraform-docs (`.terraform-docs.yml`)
- [ ] `catalog/modules.yaml` updated (if module metadata changed)
- [ ] Relevant docs under `docs/` updated (versioning, cross-platform, security baseline)

## Reviewer Notes

<!-- Anything reviewers should focus on: risky areas, decisions needing validation, follow-ups planned. -->

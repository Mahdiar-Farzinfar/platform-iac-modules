# Versioning and Release Policy

This document describes how `platform-iac-modules` versions its reusable
Terraform modules, repository automation, and development-container image. The
release workflow is the executable source of truth; this document explains its
behavior and the compatibility expectations for contributors and consumers.

## Repository model

`platform-iac-modules` is a library of stateless Terraform modules. It is not a
deployable root module, and consumers should not run environment
`terraform apply` operations from this repository.

The repository uses independent release domains rather than one repository-wide
version. A change can affect more than one domain, and each affected domain is
versioned independently.

## Release domains and tags

| Domain | Files that select the domain | Tag format |
| --- | --- | --- |
| Terraform module | `modules/<module-name>/**` | `module/<module-name>/v<MAJOR>.<MINOR>.<PATCH>` |
| Repository/root | `modules/README.md`, `.github/**`, `docs/**`, `scripts/**`, `tooling/**`, `catalog/**`, `tests/**`, root metadata, and related automation files | `root/v<MAJOR>.<MINOR>.<PATCH>` |
| Development container image | `.devcontainer/**` or `docker-compose.dev.yml` | `image/devcontainer/v<MAJOR>.<MINOR>.<PATCH>` |

The module domain applies to every file below an individual module, including
its Terraform source, README, examples, tests, and integration tests. The
top-level `modules/README.md` is a repository-level document and selects the
`root` domain.

Examples:

```text
module/backend-bootstrap/v0.1.0
module/github-oidc/v1.2.0
module/cloudtrail/v1.2.0
root/v0.4.0
image/devcontainer/v0.3.1
```

Production consumers must reference the complete module-scoped tag:

```hcl
source = "git::https://github.com/Mahdiar-Farzinfar/platform-iac-modules.git//modules/cloudtrail?ref=module/cloudtrail/v1.2.0"
```

Do not use `main`, an unpinned branch, or a repository-wide root tag as a
production module reference.

## Support policy

Per [`SECURITY.md`](https://github.com/Mahdiar-Farzinfar/platform-iac-modules/blob/main/SECURITY.md), security fixes are guaranteed only for the
latest released version of the affected release domain:

- the latest `module/<module-name>/vX.Y.Z` for a module;
- the latest `root/vX.Y.Z` for repository-level automation and metadata;
- the latest `image/devcontainer/vX.Y.Z` for the development container.

Older releases may remain usable, but they are not guaranteed to receive
security or bug fixes. Pre-1.0 releases may include breaking changes; the
latest release in each domain is still the supported security target.

## Release workflow

`.github/workflows/release.yml` runs only for the `main` branch, on pushes or
manual `workflow_dispatch`. It:

1. Computes the changed-file range.
2. Maps changed files to one or more release domains.
3. Finds the latest existing tag for each domain.
4. Calculates the next SemVer version from relevant Conventional Commit
   messages.
5. Publishes the domain tag and a GitHub Release at the current commit.
6. Verifies that the published tag points to that commit.
7. Opens a pull request to update `CHANGELOG.md` after successful non-image
   releases.

The workflow refuses to reuse an existing next tag. Published tags are policy
artifacts and must be treated as immutable; publish a new version if a release
needs correction.

For a normal push, the workflow examines the push event's `before..head`
range. For manual dispatch, it examines the previous commit and the current
`HEAD`, as implemented in the workflow. A change outside the recognized domain
patterns produces no release.

## Version calculation

Each domain uses Semantic Versioning:

```text
<MAJOR>.<MINOR>.<PATCH>
```

The workflow considers commit subjects and bodies relevant to the affected
domain. The highest bump requested by those messages wins:

| Commit signal | Bump | Example |
| --- | --- | --- |
| `BREAKING CHANGE:` in a message body/footer | Major | `BREAKING CHANGE: remove an input` |
| `!` before the colon in the type/scope | Major | `feat(cloudtrail)!: change trail ownership` |
| `feat` with an optional scope | Minor | `feat(kms): add grant support` |
| `fix`, `perf`, `refactor`, `revert`, or `security` with an optional scope | Patch | `security(log-archive-bucket): tighten policy` |

The implementation recognizes the commit type and optional scope; it does not
enforce that the scope matches a directory. Contributors should still use a
module name or `root` scope so release impact is clear.

Commit types such as `docs`, `chore`, `ci`, `test`, `build`, and `style` do not
request a release bump in the current workflow. A changed domain with no
recognized release-worthy message is skipped.

If a domain has no previous tag, version calculation starts at `0.0.0`:

- first `feat` release: `0.1.0`;
- first patch-level release: `0.0.1`;
- first breaking release: `1.0.0`.

This behavior is per domain. A feature in `module/kms` does not increment
`module/cloudtrail` or `root`.

## Release artifacts and changelog behavior

For every released domain, the workflow publishes a tag and GitHub Release.
Non-image releases use generated notes based on commits since the previous tag.
Image releases currently receive a generic automated note because the workflow
does not render the normal release-notes file for image entries.

When an `image/devcontainer/vX.Y.Z` tag is pushed, the
`.github/workflows/devcontainer-image.yml` workflow builds and publishes the
multi-architecture image to GHCR, adds the matching SemVer image tag, signs the
image by digest with keyless Cosign, verifies the signature, and scans the
immutable digest with Trivy.

`CHANGELOG.md` is maintained separately from tagging:

- image releases are excluded from changelog sections;
- non-image releases append generated sections;
- if `CHANGELOG.md` does not exist, the workflow creates it;
- the workflow pushes a branch named
  `automation/changelog-<workflow-run-id>` and opens a pull request;
- the changelog is not committed directly to `main`.

Contributors normally should not edit `CHANGELOG.md` for ordinary changes.
Write an accurate Conventional Commit message instead. Manual edits are
appropriate for correcting generated history or intentionally migrating the
release process.

## Module compatibility contracts

Each module declares its minimum supported Terraform and provider versions in
its own `versions.tf`. The current constraints are:

| Module | Terraform | AWS provider |
| --- | --- | --- |
| `backend-bootstrap` | `>= 1.6.0, < 2.0.0` | `>= 5.70.0, < 7.0.0` |
| `cloudtrail` | `>= 1.3.0` | `~> 5.0` |
| `github-oidc` | `>= 1.6.0` | `>= 5.81.0` |
| `guardduty` | `>= 1.5.0, < 2.0.0` | `>= 5.40.0, < 7.0.0` |
| `kms` | `>= 1.3.0` | `>= 5.0` |
| `log-archive-bucket` | `>= 1.5.0, < 2.0.0` | `>= 5.0.0, < 7.0.0` |
| `scp` | `>= 1.5` | `>= 5.0, < 6.0` |

These ranges are module contracts, not exact dependency pins. The consuming
root module owns provider configuration and should commit its
`.terraform.lock.hcl`. Provider upgrades must satisfy every composed module's
constraint and should be tested before promotion.

When a constraint changes, update the relevant `versions.tf`, module README,
tests, and release notes. A provider-major migration that changes module
behavior or compatibility is a breaking change for the affected module.

## Toolchain and dependency updates

Use these files as the authoritative toolchain sources:

- [`tooling/.terraform-version`](https://github.com/Mahdiar-Farzinfar/platform-iac-modules/blob/main/tooling/.terraform-version) for Terraform;
- [`tooling/.tool-versions`](https://github.com/Mahdiar-Farzinfar/platform-iac-modules/blob/main/tooling/.tool-versions) for shared tools;
- [`go.mod`](https://github.com/Mahdiar-Farzinfar/platform-iac-modules/blob/main/go.mod) for Go;
- [`tooling/cross-platform/asdf-tool-versions`](https://github.com/Mahdiar-Farzinfar/platform-iac-modules/blob/main/tooling/cross-platform/asdf-tool-versions)
  for the cross-platform mirror.

Run `task verify:toolchain` when changing version sources or mirrors. The
machine-readable catalog is an inventory and automation aid; it is not the
authoritative source for module constraints or release tags.

Renovate manages dependency update proposals using
[`.github/renovate.json`](https://github.com/Mahdiar-Farzinfar/platform-iac-modules/blob/main/.github/renovate.json). Security updates receive
priority, while major Terraform/provider and toolchain updates require
deliberate compatibility review. Keep action references, scanner versions,
provider constraints, and toolchain pins aligned with the checks run by CI.

## Compatibility and breaking changes

Treat the following as potentially breaking for a module:

- removing or renaming an input or output;
- changing a type, requiredness, default, validation, or security default;
- changing resource names, addresses, `for_each` keys, or ownership;
- changing retention, deletion, replacement, or policy scope;
- changing Terraform/provider constraints so an existing consumer no longer
  satisfies them.

For a breaking change:

1. Use a major-bump Conventional Commit signal.
2. Document the impact in the module README and release notes.
3. Explain state migration, imports, `moved` blocks, replacements, and rollback
   limitations.
4. Provide a lower-risk upgrade path where practical.

Deprecate inputs, outputs, or behavior explicitly in the module README and
changelog. Keep deprecated interfaces for at least one minor release where
practical, and remove them only in a major module release. Security-default
changes require especially clear migration and consumer-impact notes.

## Consumer upgrade procedure

For every module upgrade:

1. Change the consumer's source to an immutable
   `module/<name>/vX.Y.Z` tag.
2. Read the module README, release notes, and `versions.tf`.
3. Confirm the consumer's Terraform and provider constraints intersect the
   module's requirements.
4. Run `terraform init` with the consumer's lockfile policy, then
   `terraform validate`.
5. Review `terraform plan` for replacements, policy changes, retention changes,
   permission changes, and state-address movement.
6. Test security-sensitive or stateful changes in a lower-risk account or
   environment.
7. Promote through the consuming repository's approval workflow.

Do not assume that reverting the module tag reverses a state migration,
resource replacement, key deletion schedule, policy change, or retention
change. Restore or migrate state deliberately and follow the affected module's
rollback guidance.

## Maintainer checklist

Before merging a release-relevant change:

- [ ] The affected release domain(s) are clear from the changed paths.
- [ ] The commit type and optional scope produce the intended bump.
- [ ] Breaking changes have migration and rollback guidance.
- [ ] Module interfaces, examples, tests, and generated README sections are
      synchronized.
- [ ] `versions.tf` changes are reflected in documentation and compatibility
      testing.
- [ ] `catalog/modules.yaml` is updated for module inventory or metadata
      changes; do not add invented version fields.
- [ ] Relevant `task` validation, security, test, and documentation checks pass.
- [ ] The intended next tag does not already exist.
- [ ] Release workflow changes are reflected in this document and in the root
      release-domain documentation.

## Sources of truth

Use these files for current behavior:

- [`README.md`](https://github.com/Mahdiar-Farzinfar/platform-iac-modules/blob/main/README.md), especially its Versioning and Releases section;
- [`CONTRIBUTING.md`](https://github.com/Mahdiar-Farzinfar/platform-iac-modules/blob/main/CONTRIBUTING.md), for commit and compatibility policy;
- [`SECURITY.md`](https://github.com/Mahdiar-Farzinfar/platform-iac-modules/blob/main/SECURITY.md), for supported release-domain versions;
- [`.github/workflows/release.yml`](https://github.com/Mahdiar-Farzinfar/platform-iac-modules/blob/main/.github/workflows/release.yml), for
  domain detection, bump calculation, tag creation, and changelog automation;
- [`.github/renovate.json`](https://github.com/Mahdiar-Farzinfar/platform-iac-modules/blob/main/.github/renovate.json), for dependency-update
  policy;
- each module's `versions.tf` file under
  [`modules/`](https://github.com/Mahdiar-Farzinfar/platform-iac-modules/tree/main/modules),
  for executable compatibility constraints;
- [`.terraform-docs.yml`](https://github.com/Mahdiar-Farzinfar/platform-iac-modules/blob/main/.terraform-docs.yml), for generated module
  documentation;
- [`catalog/modules.yaml`](https://github.com/Mahdiar-Farzinfar/platform-iac-modules/blob/main/catalog/modules.yaml), for module inventory and
  metadata;
- [`Taskfile.yml`](https://github.com/Mahdiar-Farzinfar/platform-iac-modules/blob/main/Taskfile.yml), for local validation and release checks.

If implementation and documentation diverge, follow the enforced workflow and
module files first, then update this document in the same change.

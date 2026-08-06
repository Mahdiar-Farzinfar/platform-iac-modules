# Contributing to platform-iac-modules

Thank you for your interest in contributing to **platform-iac-modules**.

This repository welcomes enhancements, bug fixes, documentation improvements, and tests.

This guide describes the contribution workflow, standards, and best practices for a solo-maintained project with enterprise-grade quality, clarity, and consistency.

## Table of Contents

- [Code of Conduct](#code-of-conduct)  
- [How to File an Issue or Request a Feature](#how-to-file-an-issue-or-request-a-feature)  
- [Label Taxonomy](#label-taxonomy)  
- [Out of Scope Contributions](#out-of-scope-contributions)  
- [Getting Started](#getting-started)  
- [Environment Variables and Credentials](#environment-variables-and-credentials)  
- [Command Map](#command-map)  
- [Local Validation Expectations](#local-validation-expectations)  
- [Developer Experience and Cross-Platform Expectations](#developer-experience-and-cross-platform-expectations)  
- [Repository Layout](#repository-layout)  
- [Branching Strategy](#branching-strategy)  
- [Governance & Maintainer Model](#governance--maintainer-model)  
- [Commit Message Conventions](#commit-message-conventions)  
- [Scope Discipline for PRs and Commits](#scope-discipline-for-prs-and-commits)  
- [Developer Certificate of Origin (DCO) & Sign-off](#developer-certificate-of-origin-dco--sign-off)  
- [Issue Triage SLA](#issue-triage-sla)  
- [Toolchain Compatibility](#toolchain-compatibility)  
- [Backward Compatibility Policy](#backward-compatibility-policy)  
- [Module Interface Compatibility Policy](#module-interface-compatibility-policy)  
- [Pull Request Process](#pull-request-process)  
- [PR Template Expectations](#pr-template-expectations)  
- [PR Size Guidelines](#pr-size-guidelines)  
- [Proposing Large or Breaking Changes](#proposing-large-or-breaking-changes)  
- [Reviewer Checklist](#reviewer-checklist)  
- [Definition of Done (PR Gate)](#definition-of-done-pr-gate)  
- [Module Contribution Checklist](#module-contribution-checklist)  
- [Terraform / IaC Style Conventions](#terraform--iac-style-conventions)  
- [Terraform Naming Conventions](#terraform-naming-conventions)  
- [Comments and Abstractions Policy](#comments-and-abstractions-policy)  
- [Auto-Fix and Canonical Formatting Path](#auto-fix-and-canonical-formatting-path)  
- [State, Resource Addressing, and Safety Policy](#state-resource-addressing-and-safety-policy)  
- [State Migration and Rollback Guidance](#state-migration-and-rollback-guidance)  
- [Testing](#testing)  
- [Documentation](#documentation)  
- [Language Policy](#language-policy)  
- [Versioning and Release](#versioning-and-release)  
- [Release Ownership](#release-ownership)  
- [Deprecation Policy](#deprecation-policy)  
- [Security](#security)  
- [Cost & Performance Considerations](#cost--performance-considerations)  
- [Dependency Approval Policy](#dependency-approval-policy)  
- [Contact & Support](#contact--support)  
- [Troubleshooting and FAQ](#troubleshooting-and-faq)  
- [Communication Channel Routing](#communication-channel-routing)  
- [CONTRIBUTING.md Ownership and Drift Policy](#contributingmd-ownership-and-drift-policy)  
- [Final Contributor Checklist](#final-contributor-checklist)  

---

## Code of Conduct

This project follows the [Contributor Covenant v2.1](https://www.contributor-covenant.org/version/2/1/code_of_conduct/). By participating, you agree to follow its principles for respectful and constructive collaboration.  

Reports of harassment, abuse, or other unacceptable behavior should be sent through a private maintainer contact path, not filed as a public issue.  

No dedicated security reporting email address is currently available for this repository. Sensitive security issues should be reported through the repository's private vulnerability disclosure channel. This section will be updated if a dedicated security reporting email address is introduced.

Public issues and pull requests must not be used to disclose sensitive personal, conduct, or security-report details.

---

## How to File an Issue or Request a Feature

1. Check existing issues to avoid duplicates.  
2. For **bugs**, open an issue with:
   - A clear title (e.g., “bug: module `kms` fails when `enable_key_rotation=true`”).  
   - Steps to reproduce, Terraform version, provider versions, and error logs.  
3. For **feature requests**, open an issue with:
   - Motivation and use case.  
   - Proposed interface or Terraform configuration example.  

If you have permission, apply an appropriate label such as `bug`, `enhancement`, or `documentation`. Otherwise, a maintainer will triage and label the issue.

---

## Label Taxonomy

Labels are used to make triage status and contribution intent easier to understand.

Common labels include:

- `bug` for verified defects
- `enhancement` for feature or capability improvements
- `documentation` for doc-only changes
- `breaking-change` for proposals or PRs that alter compatibility
- `security` for non-sensitive security-related work that can be discussed publicly
- `good first issue` for well-bounded starter tasks
- `help wanted` for contributions that are welcome but not currently scheduled
- `needs reproduction` for reports that require a minimal reproducer
- `blocked` for work waiting on an external dependency or maintainer decision

Labels are descriptive aids, not guarantees of acceptance, priority, or scheduling.

---

## Out of Scope Contributions

To keep review cycles focused and repository behavior predictable, some changes are normally considered out of scope unless they are discussed and approved in advance.

The following contributions are generally not accepted without prior alignment through an issue or design discussion:

- broad refactors that are not tied to a specific bug, feature, or maintainability problem
- repository-wide renames, style rewrites, or formatting churn with no functional value
- opinionated naming or structure changes made only for personal preference
- new abstractions, shared modules, or helper layers introduced before there is a demonstrated recurring need
- breaking interface changes without a documented compatibility and migration plan
- drive-by changes to CI, release flow, governance, or contributor workflow without a clear repository need

If a change affects multiple modules, alters contributor workflow, changes release behavior, or introduces a new architectural pattern, open an issue first and align on scope before implementation.

---

## Getting Started

### Prerequisites

- Git >= 2.30
- Docker, used to run the development container

The required Terraform version is defined in `./tooling/terraform-version`. Versions for the remaining development tools are defined in `./tooling/tool-versions`, with `./tooling/cross-platform/asdf-tool-versions` maintained as a mirror for `asdf` and cross-platform environments.  
The Go language version is defined in `./go.mod`.  

The project bootstrap flow installs the following toolchain:

- `terraform`
- `tflint`
- `terraform-docs`
- `trivy`
- `gitleaks`
- `checkov`
- `python`
- `nodejs`
- `golangci-lint`
- `pre-commit`
- `markdownlint`
- `yamllint`
- `actionlint`
- `task`
- `just`
- `shfmt`
- `docker-cli`
- `docker-compose`

Contributions should pass the same validation, formatting, linting, and security checks locally and in CI. Hook behavior is defined in `.pre-commit-config.yaml`, documentation generation behavior is defined in `.terraform-docs.yml`, and tool-specific configuration is sourced from the `tooling/` directory where applicable.

`./tooling/terraform-version`, `./tooling/tool-versions`, and `./go.mod` are the authoritative version sources. `./tooling/cross-platform/asdf-tool-versions` is a mirror and should remain synchronized with the relevant tooling version files.

### Local Setup

```bash
# 1. Clone the repo
git clone https://github.com/Mahdiar-Farzinfar/platform-iac-modules.git
cd platform-iac-modules

# 2. (Optional) Inspect available tasks
task --list

# 3. (Optional) Confirm detected OS/arch
task os:detect

# 4. Bootstrap local tooling
task bootstrap

# 5. Enable Git hooks
pre-commit install

# 6. Verify local environment and required tools (strict)
task preflight

# 7. Run a fast sanity workflow
task quick
```

Preferred interface: `task`  
Compatibility wrappers: `make` and `just`

---

## Environment Variables and Credentials

Most formatting, static analysis, and documentation commands can run without cloud credentials. Some validation flows, integration checks, or smoke tests may require access to a real AWS account or sandbox environment.

Contributors should assume the following:

- local formatting, linting, documentation generation, and most policy checks should work without cloud access
- commands that interact with live providers may require valid AWS credentials and a permitted target account
- no secrets, credentials, or account-specific values may be committed to the repository

When cloud-backed validation is required, the following environment variables are commonly used:

- `AWS_PROFILE`
- `AWS_REGION`
- `AWS_ACCOUNT_ID`
- `TF_VAR_*`

Use environment variables or your local credential manager rather than hardcoding values in code, examples, tests, or documentation.  

If a contribution requires non-default credentials, regions, or account assumptions, document that clearly in the PR description and in the affected module or test documentation.  

---

## Command Map

`Taskfile.yml` is the source of truth for local developer workflows. `Makefile` and `justfile` are thin wrappers for contributor convenience and should remain behaviorally aligned with the corresponding task targets.

Use `task` as the canonical interface when documenting commands in issues, PRs, and internal docs.

| Workflow | Canonical (`task`) | Wrapper (`make`) | Wrapper (`just`) |
| --- | --- | --- | --- |
| Show available tasks | `task` / `task default` | `make help` | `just` / `just default` |
| Verify local environment | `task preflight` | `make preflight` | `just preflight` |
| Verify toolchain version sources and mirrors | `task verify:toolchain` | `make verify-toolchain` | `just verify-toolchain` |
| Validate output sanitization patterns | `task verify:outputs` | `make verify-outputs` | `just verify-outputs` |
| Bootstrap local environment (tool installer) | `task bootstrap` | `make bootstrap` | `just bootstrap` |
| Bootstrap on Linux/macOS | `task bootstrap:posix` | `make bootstrap-posix` | `just bootstrap-posix` |
| Bootstrap on Windows | `task bootstrap:windows` | `make bootstrap-windows` | `just bootstrap-windows` |
| Initialize Terraform modules | `task init` | `make init` | `just init` |
| Detect OS/arch | `task os:detect` | `make os-detect` | `just os-detect` |
| Detect changed files/modules | `task ci:changed` | `make ci-changed` | `just ci-changed` |
| Format code (all) | `task fmt` | `make fmt` | `just fmt` |
| Format Terraform only | `task fmt:terraform` | `make fmt-terraform` | `just fmt-terraform` |
| Format Go only | `task fmt:go` | `make fmt-go` | `just fmt-go` |
| Format shell scripts (POSIX) | `task fmt:shell` | `make fmt-shell` | `just fmt-shell` |
| Format shell scripts (Windows stub) | `task fmt:shell:windows` | `make fmt-shell-windows` | `just fmt-shell-windows` |
| Run linters + validations | `task lint` | `make lint` | `just lint` |
| Validate Terraform only | `task validate:terraform` | `make validate-terraform` | `just validate-terraform` |
| Validate Go (`go vet`) | `task validate:go` | `make validate-go` | `just validate-go` |
| Run TFLint | `task lint:tflint` | `make lint-tflint` | `just lint-tflint` |
| Lint YAML | `task lint:yaml` | `make lint-yaml` | `just lint-yaml` |
| Lint Markdown | `task lint:md` | `make lint-md` | `just lint-md` |
| Lint GitHub Actions workflows | `task lint:actions` | `make lint-actions` | `just lint-actions` |
| Lint Go (`golangci-lint`) | `task lint:go` | `make lint-go` | `just lint-go` |
| Run tests (all) | `task test` | `make test` | `just test` |
| Run Terraform tests | `task test:terraform` | `make test-terraform` | `just test-terraform` |
| Run Go tests (integration) | `task test:go` | `make test-go` | `just test-go` |
| Run smoke tests | `task test:smoke` | `make test-smoke` | `just test-smoke` |
| Run cross-platform tests | `task test:cross-platform` | `make test-cross-platform` | `just test-cross-platform` |
| Run cross-platform tests (Linux) | `task test:cross-platform:linux` | `make test-cross-platform-linux` | `just test-cross-platform-linux` |
| Run cross-platform tests (macOS) | `task test:cross-platform:macos` | `make test-cross-platform-macos` | `just test-cross-platform-macos` |
| Run cross-platform tests (Windows) | `task test:cross-platform:windows` | `make test-cross-platform-windows` | `just test-cross-platform-windows` |
| Run security checks (Checkov + Trivy) | `task security` | `make security` | `just security` |
| Run Gitleaks scan | `task security:gitleaks` | `make security-gitleaks` | `just security-gitleaks` |
| Run security scans (all) | `task security:all` | `make security-all` | `just security-all` |
| Generate documentation | `task docs` | `make docs` | `just docs` |
| Verify docs are up-to-date | `task docs:check` | `make docs-check` | `just docs-check` |
| Fast local loop | `task quick` | `make quick` | `just quick` |
| CI checks without security scanners | `task ci:non-security` | `make ci-non-security` | `just ci-non-security` |
| CI-equivalent checks | `task ci` | `make ci` | `just ci` |
| Full local pipeline | `task full` | `make full` | `just full` |
| Release gate checks | `task release-check` | `make release-check` | `just release-check` |

---

## Local Validation Expectations

A local setup is considered healthy when the repository toolchain installs successfully and the standard validation entry points complete without unexpected errors.

As a baseline expectation:

- `task preflight` should confirm that required local tooling is installed and callable
- `task quick` should complete the fast feedback path intended for day-to-day contributor validation
- `task fmt`, `task lint`, and other relevant checks for the changed scope should pass before a PR is opened

If `task preflight` fails, verify tool versions, shell availability, Docker availability where required, and any expected cloud credentials for commands that depend on live validation.

If local behavior differs from the documented workflow, treat that as documentation drift and open a corrective issue or PR.

---

## Developer Experience and Cross-Platform Expectations

Contributor workflows should remain predictable, well-documented, and reasonably portable across supported development environments.

When changing scripts, commands, or contributor tooling:

- prefer the existing canonical command surface over introducing parallel workflows
- keep wrapper behavior aligned with the underlying `Taskfile.yml`
- make command output and failure modes actionable
- avoid changes that unnecessarily reduce portability across common contributor setups
- document any platform-specific assumptions or limitations introduced by the change

If a workflow changes, update contributor-facing documentation in the same PR.

---

## Repository Layout

```text
platform-iac-modules/
├── .devcontainer/           # VSCode Dev Container configs
├── .vscode/                 # Editor settings & recommended extensions
├── modules/                 # Reusable Terraform modules with examples & tests
├── scripts/                 # Bootstrap, CI helpers, and environment tooling
├── tooling/                 # Shared tool configs, version pins, and scanner policies
├── docs/                    # High-level and process documentation
├── tests/                   # Smoke and cross-platform validation suites
├── .github/                 # GitHub templates, workflows, renovate config
├── Taskfile.yml, Makefile, justfile   # Task runners & shortcuts
├── catalog/                 # modules.yaml catalog of published modules
└── CONTRIBUTING.md          # ← You are here
```

Refer to:

- [`docs/module-development.md`](docs/module-development.md) for module structure and development guidance
- [`tests/README.md`](tests/README.md) for test-suite details
- [`modules/README.md`](modules/README.md) for module inventory and conventions

---

## Branching Strategy

This repository uses a **main-only** workflow with feature branches:

- `main`: always deployable, protected by branch rules and CI checks.  
- `feature/<short-description>`: for new features or fixes.  
- `hotfix/<short-description>`: for quick patches against `main`.

Branch protection rules on `main` should require pull-request based changes, linear history, and passing required CI checks. The exact set of required checks is defined in repository branch protection settings and should remain aligned with active workflows under `.github/workflows/`.

Typical required checks include:

- `validate`
- `devcontainer-image`
- `security-scan`
- `cross-platform-test`
- `release`
- `docs` (when documentation generation or validation is applicable)

Before merging into `main`:

1. Ensure all required CI checks pass.  
2. Rebase or update the branch from the latest `main` if checks are stale or merge conflicts exist.
3. Complete PR review requirements according to repository settings.

Additional merge policy:

- Use pull requests for all non-trivial changes.
- Keep PR branches focused and reasonably up to date with `main`.
- Force-push is acceptable on contributor branches when cleaning up history; never force-push `main`.
- Prefer squash merge unless repository policy explicitly requires another strategy.

---

## Governance & Maintainer Model

This repository is currently maintained by a single maintainer.

- PR-based review is the default workflow for changes to `main`.
- The maintainer has final decision authority on architecture, releases, and breaking changes.
- External maintainers may be invited based on sustained, high-quality contributions.

For substantial architectural changes, open an issue for discussion before implementation.

---

## Commit Message Conventions

This repository uses **Conventional Commits** to automate CHANGELOG generation and versioning. Scope must match the module folder name (e.g., `cloudtrail`, `guardduty`, `scp`, `root`).

Format:  
`<type>(<scope>): <description>`

[optional body]

[optional footer(s)]

- **type**: feat, fix, docs, style, refactor, test, chore, ci, perf, build.  
- **scope**: module name or root (e.g., `kms`, `github-oidc`, `root`).  
- **description**: short summary (< 72 chars).  

Examples:  

- `feat(kms): add support for key rotation`  
- `fix(log-archive-bucket): correct S3 bucket policy ARN`  
- `docs(root): update contributing guidelines`  
- `test(cloudtrail): add integration test for multi-region`

Avoid vague commit messages such as:

- `update stuff`
- `fix bugs`
- `misc changes`
- `feat: improvements`
- `refactor: cleanup`

A reviewer should be able to understand the intent and affected area from the commit subject alone.  

Commit messages must be in English.  

---

## Scope Discipline for PRs and Commits

Keep commits and pull requests narrowly scoped.

Contributors are expected to follow these rules:

- each commit should represent one logical change
- formatting-only changes should be separated from behavior changes whenever practical
- refactors should be separated from fixes or features unless separation would make the change harder to review
- unrelated cleanup must not be bundled into a focused bug fix or feature PR
- large multi-module changes should begin with prior issue-based alignment

As a practical guideline, a change is usually small if it affects a limited surface area, has a clear single purpose, and does not alter contributor workflow, shared contracts, or multiple modules at once. A change should be treated as large if it changes shared patterns, repository workflow, release behavior, module interfaces, or multiple modules in one proposal.

---

## Developer Certificate of Origin (DCO) & Sign-off

This repository enforces Developer Certificate of Origin (DCO) sign-off for all commits. Every commit submitted to this repository must include a valid `Signed-off-by` line.

By signing off a commit, you certify that you have the right to submit the contribution under the repository’s license and agree to the Developer Certificate of Origin.

Add sign-off to every commit:

```bash
git commit -s -m "feat(kms): add support for key rotation"
```

The commit message footer must include a valid sign-off line:

```text
Signed-off-by: Your Name <your.email@example.com>
```

The name and email address in the sign-off should match the contributor identity used for the commit whenever possible.

Notes:

- Unsigned commits will fail DCO checks.
- Every commit in a pull request must be signed off, not only the latest commit.
- For squash merges, ensure the final squashed commit also contains a valid sign-off.
- If you need to add sign-off to an existing commit, amend it with:

```bash
git commit --amend --signoff
```

- If multiple commits need sign-off, rebase and sign each commit before pushing:

```bash
git rebase --signoff HEAD~N
```

Replace `N` with the number of commits that need to be updated.

---

## Issue Triage SLA

Target response times are best-effort and may vary based on maintainer availability.

Typical goals are:

- **Initial triage** within **2-5 business days**
- label assignment (`bug`, `enhancement`, `documentation`, `question`)
- severity/priority assessment
- request for missing reproduction details (if needed)
- **follow-up status update** within **5–10 business days**
- Security issues follow `SECURITY.md` and are handled out-of-band.

---

## Toolchain Compatibility

This repository does not maintain a separate compatibility matrix in documentation. Toolchain versions are defined by the repository version files and are treated as the source of truth.

- Terraform version: `./tooling/terraform-version`
- Development tool versions: `./tooling/tool-versions`
- Cross-platform/asdf mirror: `./tooling/cross-platform/asdf-tool-versions`
- Go language version: `./go.mod`

Contributions must remain compatible with the toolchain defined in those files and must pass the same checks locally and in CI.

If a contribution changes minimum or pinned tool versions, the PR must:

- include the rationale and expected impact;
- update the relevant version source files;
- update CI, bootstrap, documentation, and mirror files where applicable;
- clearly mark backward-incompatible changes with `BREAKING CHANGE:`.

---

## Backward Compatibility Policy

- Patch and minor releases MUST remain backward compatible.
- Breaking changes are only permitted in major releases.
- Deprecations should be announced at least one minor version before removal.
- Any breaking change must include a `BREAKING CHANGE:` footer in the commit message.

Contributors must clearly document compatibility impact in the PR description.

---

## Module Interface Compatibility Policy

For Terraform modules, inputs, outputs, expected resource behavior, and documented defaults are part of the module contract.

Contributors must treat the following as compatibility-sensitive changes:

- removing or renaming input variables
- removing or renaming outputs
- changing the meaning of an existing variable or output
- changing a default value in a way that alters behavior for existing consumers
- changing resource addressing patterns in a way that can force replacement or state migration

If a contract change is intentional, it must be documented clearly in the PR, changelog, module documentation, and any required migration notes.

---

## Pull Request Process

### 1. Create a branch off `main`  

```bash
   git checkout -b feature/add-new-module
```

### 2. Develop your change, running local validation and tests  

```bash
task fmt
task lint
task validate:terraform
task validate:go
task test
task docs
```

For changes affecting tooling, scripts, or execution behavior, also run the additional test flows described in [Testing](#testing):

```bash
task test:smoke
task test:cross-platform
```

### 3. Push your branch and open a PR against `main`  

### 4. Automated checks will run

Pull requests are validated by a broader CI suite, not only Terraform checks. Depending on the files changed, automated checks may include:

- Terraform formatting, validation, and linting (terraform fmt, terraform validate, tflint)
- Repository and workflow linting (actionlint, yamllint, markdownlint)
- Go validation and linting (go test, go vet, golangci-lint or equivalent)
- Security scanning (checkov, trivy, gitleaks)
- Dev Container image build and validation
- Smoke and integration-oriented test flows
- Cross-platform tests where applicable (Linux, macOS, Windows)
- Documentation generation and consistency checks

### 5. Review

Before merge, reviewers should verify that:

- Code quality, naming, structure, and maintainability are consistent.
- Terraform variables, outputs, locals, and module interfaces are clear and stable.
- CI workflows, scripts, and developer tooling changes are intentional and tested.
- Documentation, examples, and generated files are updated where required.

---

## PR Template Expectations

Pull requests should fully complete the repository PR template in `.github/PULL_REQUEST_TEMPLATE.md`.

At minimum, every PR should clearly document:

- Summary of the change
- Change type (`feat`, `fix`, `docs`, `refactor`, `test`, `chore`, etc.)
- Affected modules, scripts, or workflows
- Local validation and test evidence
- Backward compatibility impact
- Security impact
- Cost or operational impact, if relevant
- Rollback or recovery considerations for risky changes

PRs missing sufficient context, validation details, or impact analysis may be returned for completion before review.

### Example PR Description

```text
Summary
- add optional encryption controls to module X
- preserve existing default behavior for current consumers

Why
- consumers need explicit control over encryption settings for compliance use cases

Validation
- task fmt
- task lint
- task test
- module documentation regenerated

Compatibility Impact
- backward compatible
- no input removals or output renames

Migration / Rollback
- no state migration required
- rollback is safe by reverting the module change before apply
```

---

## PR Size Guidelines

Prefer:

- Small, focused pull requests
- One logical change per PR
- Separate refactor and feature work

Avoid:

- Mixing formatting, refactor, and feature changes in a single PR
- Large, multi-module modifications without prior discussion

Smaller PRs improve review quality and reduce regression risk.

---

## Proposing Large or Breaking Changes

For the following change types, open an issue before submitting a PR:

- New modules
- Major refactors
- Security baseline changes
- Compatibility matrix updates
- Breaking changes

The issue should describe:

- Problem statement
- Proposed design
- Backward compatibility impact
- Migration strategy (if applicable)

Large PRs without prior discussion may be deferred for architectural clarification.

Breaking-change proposals must also include:

- Explicit migration guidance
- Before/after usage examples
- Expected consumer impact
- Upgrade sequencing notes, if applicable
- Rollback considerations for failed adoption

---

## Reviewer Checklist

Reviewers should evaluate pull requests for:

- Correctness and clarity of the proposed change
- Backward compatibility of inputs, outputs, naming, and behavior
- Security posture and least-privilege defaults
- State safety, resource lifecycle impact, and replacement risk
- Terraform module interface quality and composability
- Test coverage appropriate to the change scope
- Documentation and example parity
- Cost, scaling, and operational implications
- Consistency with repository conventions and CI expectations

---

## Definition of Done (PR Gate)

A PR is considered ready to merge only when all items below are satisfied:

### 1. Quality & Validation

- Formatting and linting pass.
- Terraform validation passes for affected modules.
- CI checks are green (`validate`, `security-scan`, `cross-platform-test`, and docs workflow if applicable).

### 2. Testing

- Relevant automated tests are updated and executed according to the guidance in [Testing](#testing).
- Behavior changes include updated or added `tftest.hcl` coverage.
- Modules with integration coverage include updated Go integration tests when impacted.
- Tooling or execution-path changes include smoke and cross-platform test execution.

### 3. Documentation

- Module README updated (inputs/outputs/examples).
- `docs/` updated for process or architecture changes.
- Any user-facing behavior change is documented.

### 4. Release Hygiene

- Commit messages follow Conventional Commits so version bumps, release notes, and changelog entries can be generated automatically.
- Manual `CHANGELOG.md` updates are only needed for corrections, clarifications, or intentional historical/structural changelog changes.
- Catalog entries updated when adding or versioning modules (`catalog/modules.yaml`).

### 5. Security & Compliance

- No secrets committed.
- Security scans pass (`checkov`, `trivy`, `gitleaks`, and other configured checks where applicable).
- IAM/KMS/S3 policy changes include least-privilege rationale in PR notes.

---

## Module Contribution Checklist

When adding or modifying a module under `modules/<name>/`, ensure:

- [ ] `main.tf`, `variables.tf`, `outputs.tf`, `versions.tf`, `locals.tf` are consistent.
- [ ] `README.md` reflects real inputs/outputs and contains a working example.
- [ ] `examples/basic/main.tf` is updated and runnable.
- [ ] `tests/tftest.hcl` exists and covers critical paths.
- [ ] `tests/integration-test.go` is updated (if module has integration tests).
- [ ] Naming, tagging, and output contracts are backward-compatible (or explicitly marked breaking).
- [ ] `terraform fmt` / lint / security checks pass locally.
- [ ] `catalog/modules.yaml` updated for new module or version changes.
- [ ] Commit messages follow Conventional Commits so the release workflow can determine the version bump and generate release notes/changelog entries.

Tip: Keep modules composable, least-privilege by default, and explicit in outputs.

---

## Terraform / IaC Style Conventions

Contributions to Terraform modules should follow these conventions:

- Prefer explicit variable types and validations over loosely typed inputs.
- Keep module interfaces stable, predictable, and intentionally scoped.
- Use secure defaults wherever practical.
- Favor composable module design over highly implicit behavior.
- Avoid unnecessary dynamic constructs when static configuration is clearer.
- Keep naming, tagging, and output contracts consistent across modules.
- Use explicit resource references and avoid broad permissions by default.
- Ensure examples are minimal, realistic, and runnable.
- Prefer readability and maintainability over compact but opaque expressions.

If a contribution intentionally deviates from these conventions, document the rationale in the PR.

---

## Terraform Naming Conventions

Contributors must prefer clear, predictable naming over clever or abbreviated naming. Names should be stable, descriptive, and consistent with existing module patterns.

Unless an established module pattern requires otherwise:

- module directory names should use lowercase kebab-case
- example directory names should be short, descriptive, and scenario-based
- input variable names should use lowercase snake_case
- output names should use lowercase snake_case and describe the returned value, not the implementation detail
- local values should use lowercase snake_case and remain narrowly scoped
- resource names should favor descriptive logical intent over provider-specific noise
- tags and labels should follow the repository's existing conventions and remain consistent across examples and modules

Avoid unnecessary abbreviations, ambiguous names such as `data`, `config`, or `value`, and names that encode temporary implementation details likely to change later.

---

## Comments and Abstractions Policy

Comments should explain intent, constraints, tradeoffs, or non-obvious rationale. Do not add comments that simply restate what the code already says.

Useful comments typically explain:

- why a resource, dependency, lifecycle rule, or exception exists
- why a security, compatibility, or cost tradeoff was chosen
- why a workaround is necessary and under what condition it can be removed

Avoid stale, obvious, or narrative comments that add review noise without improving maintainability.

New abstractions should be introduced conservatively. Do not add helper layers, shared modules, or generalized patterns unless they remove real duplication or simplify a repeated maintenance burden. Prefer repository-local consistency over premature generalization.

---

## Auto-Fix and Canonical Formatting Path

Before opening a PR, contributors should run the repository's canonical formatting and auto-fix commands for the files they changed.

Preferred entry points are:

- `task fmt`
- `pre-commit run --all-files`

Use the repository-defined commands rather than ad hoc local alternatives so that local results stay aligned with CI behavior.

Formatting-only changes should be kept separate from behavioral changes whenever practical. Avoid mixing mechanical rewrites, refactors, and functional edits in the same commit when they can be reviewed independently.

---

## State, Resource Addressing, and Safety Policy

Terraform changes must be evaluated not only for syntax correctness, but also for state and lifecycle safety.

Contributors must call out any change that may:

- Force resource replacement
- Change resource addresses or `for_each` / `count` keys
- Rename resources, outputs, or important locals in a way that affects consumers
- Break import workflows or state continuity
- Alter generated IAM, KMS, S3, or organization policy scope

Avoid introducing unnecessary state churn. Changes with replacement risk or address instability must include impact notes and migration guidance in the PR.

---

## State Migration and Rollback Guidance

Changes that can affect resource addressing, state layout, replacement behavior, or consumer upgrade safety require explicit migration guidance.

When a contribution may trigger stateful impact, document:

- what changes in the resource graph or addressing model
- whether existing users may see replacement, drift, or import requirements
- whether a `moved` block or equivalent transition mechanism is required
- whether manual migration steps are necessary
- how a consumer can roll back safely if adoption fails

Do not leave migration or rollback assumptions implicit when changing state-sensitive behavior.

---

## Testing

This section is the single source of truth for local test taxonomy and execution.

### Terraform Module Tests

- Unit-style module tests live in `modules/*/tests/*.tftest.hcl` and run via Terraform's native `terraform test` framework.

### Go Integration Tests

- Go integration tests use [Terratest](https://github.com/gruntwork-io/terratest) and typically live in `integration-test.go` within the relevant module or test path.

### Smoke Tests

- Smoke tests live under `tests/smoke/`.
- `run-smoke-tests.py` is the canonical implementation and source of truth.
- `run-smoke-tests.sh` and `run-smoke-tests.ps1` are thin platform-specific wrappers around the Python runner.

This keeps the test logic centralized while preserving native entry points for Linux/macOS and Windows.

### Cross-Platform Tests

- Cross-platform validation lives under `tests/cross-platform/` and covers Linux, macOS, and Windows execution paths.

### When to Run What

- For module behavior changes, update and run affected `tftest.hcl` tests.
- For modules with Go integration coverage, update and run integration tests when behavior changes affect those paths.
- For tooling, bootstrap, CI, shell, or execution-flow changes, run smoke and cross-platform tests.
- Before opening a PR, run the full relevant local validation flow for the scope of your change.

### Canonical Commands

```bash
task test
task test:terraform
task test:go
task test:smoke
task test:cross-platform
```

Use `task` as the canonical interface. Equivalent `make` and `just` wrappers are listed in the [Command Map](#command-map).

### Cloud-Backed Test Expectations

Some validation paths may require access to a real AWS account, sandbox subscription, or provider-backed environment.

Unless explicitly documented otherwise:

- static validation should be runnable without live cloud access
- integration or smoke validation that touches real providers should be treated as cloud-backed validation
- contributors must not assume that maintainers can safely run unreviewed infrastructure changes against production environments

If your change requires live validation, document:

- the required account or environment type
- the minimum permissions required
- the expected cost and cleanup behavior
- whether the validation is safe for repeat execution

### Test Expectations and Exceptions

Tests should scale with the risk and blast radius of the change.

Contributors are expected to follow these rules:

- bug fixes should include a regression test when a practical and stable test can be added
- changes to module behavior, interfaces, or generated artifacts should include validation proportional to the risk
- if a relevant test is not added, the PR description should explain why

Test additions may not be necessary for clearly non-behavioral changes such as:

- documentation-only edits
- comment-only edits
- typo fixes with no behavioral effect
- metadata-only changes with no runtime or contract impact

Flaky tests must not be silently rerun and ignored. If a test is unstable, call that out in the PR and document whether it requires quarantine, repair, or maintainer follow-up before merge.

---

## Documentation

- **Module READMEs**: ensure `main.tf`, `variables.tf`, `outputs.tf` docs are in sync:

Use the repository documentation workflow instead of manually overwriting README files:

```bash
task docs
task docs:check
```

Documentation generation behavior is defined in `.terraform-docs.yml`. If manual regeneration is required for a specific module, follow the repository configuration and update workflow rather than redirecting raw command output directly into `README.md`.

- **High-level docs** under `docs/`:
  - `module-development.md`  
  - `security-baseline.md`  
  - `versioning.md`  
  - `cross-platform.md`  

Always update examples in `modules/*/examples/basic/main.tf` when adding a new feature.

---

## Language Policy

This repository does not currently maintain localization-specific contribution requirements.

Contributor-facing documentation, commit messages, pull request descriptions, and issue reports should be written in English so that review history and maintenance context remain searchable and consistent over time.

---

## Versioning and Release

This repository follows **Semantic Versioning** (SemVer 2.0.0) for automated releases. Releases are created per detected release domain by the `release` workflow.

The release workflow runs on:

- push to `main`;
- manual `workflow_dispatch`.

The workflow is restricted to the default branch, currently `main`.

Release and versioning model:

- The repository is treated as a **monorepo with domain-level releases**.
- Changed files are mapped to one or more release domains.
- Each changed domain is versioned independently.
- Tags are created as annotated Git tags.
- GitHub Releases are created for non-image release domains.
- Container/image domains are tagged, but do not receive GitHub Release notes or `CHANGELOG.md` entries.

Release domains:

- Root-level changes are released as the `root` domain.
- Module changes under `modules/<name>/...` are released as `module/<name>`.
- Development container changes are released as `image/devcontainer`.

Tag format:

- Root release tags use: `root/v<version>`
- Module release tags use: `module/<name>/v<version>`
- Development container image release tags use: `image/devcontainer/v<version>`

Examples:

- `root/v1.2.0`
- `module/network/v0.4.1`
- `image/devcontainer/v0.3.0`

Version bump guidance:

- `feat` commits trigger a **minor** bump:
  - `1.2.0` → `1.3.0`
- `fix`, `perf`, `refactor`, `revert`, and `security` commits trigger a **patch** bump:
  - `1.2.0` → `1.2.1`
- Breaking changes trigger a **major** bump:
  - `1.2.0` → `2.0.0`

Breaking changes are detected from either:

- a Conventional Commit breaking marker in the subject:
  - `feat!: ...`
  - `feat(module)!: ...`
- a commit body/footer containing:
  - `BREAKING CHANGE:`

If multiple commits affect the same release domain, the highest required bump wins:

1. `major`
2. `minor`
3. `patch`

If no relevant Conventional Commit bump is detected for a changed domain, no release is created for that domain.

`CHANGELOG.md` behavior:

- Release notes are generated from commit subjects for released non-image domains.
- After successful releases, the workflow opens an automated PR that updates `CHANGELOG.md`.
- `CHANGELOG.md` is not updated directly on `main` by the release workflow.
- Image-only releases do not create `CHANGELOG.md` entries.

Module-specific changes must update module documentation and `catalog/modules.yaml` where applicable.

If release automation changes its domain mapping, tag format, bump rules, or changelog behavior, this document must be updated in the same change.

### Updating the Catalog

When adding a new module or bumping versions:

1. Update `catalog/modules.yaml` with the new module entry or version where applicable.
2. Ensure the YAML follows existing naming, version, and description conventions.
3. Include the catalog update in your PR so CI validates it.
4. Keep module documentation synchronized with catalog metadata.

---

## Release Ownership

The repository maintainer is the final authority for release timing, version selection, tag creation, and release note publication.

Contributors may propose changelog entries, release notes, or version bumps, but final release packaging and publication remain a maintainer responsibility.

---

## Deprecation Policy

When deprecating variables, outputs, or module behavior:

- Mark them as deprecated in the module README.
- Add a deprecation note in `CHANGELOG.md`.
- Maintain backward compatibility until the next major release.
- Provide a clear migration path in documentation.

Deprecated elements should not be silently removed.

---

## Changelog Policy

`CHANGELOG.md` is updated by the automated release workflow after successful non-image releases.

Contributors generally should not edit `CHANGELOG.md` manually for normal feature, fix, or breaking-change PRs. Instead, write clear Conventional Commit messages because release notes and changelog entries are generated from commit subjects.

Changes that are user-visible or operationally meaningful should use commit messages that clearly describe the impact, including:

- New features
- Bug fixes
- Breaking changes
- Security-relevant behavior changes
- New modules
- Deprecations
- Important documentation updates tied to behavior or usage

The release workflow:

- detects changed release domains;
- determines the SemVer bump from Conventional Commit messages;
- creates annotated release tags;
- creates GitHub Releases for non-image domains;
- opens an automated PR to update `CHANGELOG.md` after successful releases.

`CHANGELOG.md` entries are not generated for image-only releases.

Manual `CHANGELOG.md` edits are typically only appropriate when:

- correcting a previous changelog entry;
- improving generated release notes for clarity;
- documenting a release-process migration;
- making an intentional historical or structural changelog update.

Changelog-impacting commit messages are typically not required for:

- Internal-only refactors with no user-facing impact
- CI-only maintenance with no workflow impact on contributors or consumers
- Formatting-only changes
- Typo fixes with no behavioral or documentation significance

When in doubt, prefer writing a concise, user-facing commit subject rather than manually editing `CHANGELOG.md`.

Examples:

- `feat(module/network): add private subnet support`
- `fix(root): correct provider version constraint`
- `security(module/storage): harden default bucket policy`
- `feat(module/compute)!: remove deprecated instance profile input`

---

## Security

Refer to [SECURITY.md](SECURITY.md) for vulnerability reporting. Secrets must never be committed. Use secure CI variables and secret stores for credentials and sensitive values.

The CI security baseline includes `checkov`, `trivy`, and `gitleaks`, and contributions are expected to pass the same scanners locally where applicable.

### Secure Coding Guidelines

Contributors must follow these infrastructure security principles:

- Apply least-privilege IAM policies by default.
- Avoid wildcard permissions (`*`) unless strictly required and justified in PR notes.
- Use explicit resource ARNs instead of broad patterns whenever possible.
- Ensure encryption at rest and in transit where applicable.
- Do not weaken security defaults without documented rationale.

Security trade-offs must be explicitly explained in the pull request.

---

## Cost & Performance Considerations

This repository does not apply live infrastructure directly. However, reusable module design choices can have financial and operational impact for downstream consumers.

Contributors should consider:

- AWS cost implications introduced by module defaults, examples, or optional features
- Log retention, replication, encryption, backup, and data-transfer behavior
- Resource count growth and scaling behavior as inputs grow
- Cross-region or multi-account complexity exposed by the module
- Default configuration cost footprint
- Whether cost-impacting features should be disabled by default or explicitly opt-in
- Performance or operational trade-offs that consumers must understand

Significant cost-impacting or performance-impacting module changes must be documented in the PR description and reflected in module documentation where applicable.

Examples and defaults should avoid unexpectedly expensive behavior unless the cost and rationale are clearly documented.

---

## Dependency Approval Policy

New dependencies must have a clear repository-level justification.

Before introducing a new tool, library, action, hook, or external integration, consider:

- whether the problem can already be solved with the existing toolchain
- maintenance health and update cadence
- licensing compatibility
- security posture and supply-chain risk
- installation footprint and CI cost
- cross-platform portability for contributors

Dependencies added only for minor convenience are unlikely to be accepted if they increase repository complexity, onboarding burden, or maintenance overhead.

---

## Contact & Support

- For security-related reports, please open a private security advisory if supported by the platform, or open an issue if appropriate.
- For general questions, please open an issue.

Thank you for helping make **platform-iac-modules** robust, secure, and production-ready!  
Contributions are valued and help keep the repository robust, secure, and maintainable.

---

## Troubleshooting and FAQ

### `task preflight` fails locally

Verify that the required toolchain is installed, on your `PATH`, and matches the repository's documented version expectations.

### `terraform init` or provider installation fails

Check your Terraform version, network access, provider registry access, and whether a lockfile or provider constraint changed in your branch.

### `pre-commit` passes in CI but fails locally, or the reverse

Reinstall hooks, verify tool versions, and rerun the repository's canonical commands. Local environment drift is a common cause of inconsistent results.

### Docker-based checks fail

Confirm that Docker is installed, running, and available to your current shell session. Also verify that any required image pulls or bind mounts are permitted in your environment.

### Optional cloud-backed integration tests fail with authentication or authorization errors

Most repository validation should not require applying live infrastructure. If you are explicitly running module integration tests or another cloud-backed validation path, check `AWS_PROFILE`, `AWS_REGION`, account selection, and the minimum permissions required for that specific test path.

Do not use production accounts for ad hoc validation. Prefer isolated test accounts, least-privilege credentials, and short-lived authentication where available.

### My branch is behind `main`

Rebase or merge from `main` as required by the repository workflow, then rerun the relevant validation commands before requesting review.

### My PR conflicts with generated docs or repository metadata

Regenerate the affected artifacts using the canonical repository commands and include those updates in the same PR.

### A documented command does not match repository behavior

Treat that as documentation drift. Open an issue or PR so the documentation and implementation are corrected together.

---

## Communication Channel Routing

Use the following routing model unless a section of this document says otherwise:

- bug reports: open an issue with reproduction details
- feature requests: open an issue describing the use case and expected outcome
- architecture or breaking-change proposals: open an issue with design context before implementation
- security concerns: use the private reporting path described in the Security section
- routine contributor workflow questions: use the repository's Discussions channel for standard support and contributor communication

Using the right channel improves review quality and reduces turnaround time.

---

## CONTRIBUTING.md Ownership and Drift Policy

This document is maintained by the repository maintainer and should evolve with the actual repository workflow.

When a pull request changes contributor-facing commands, workflow, tooling expectations, validation steps, or review requirements, the relevant documentation should be updated in the same PR.

If documented behavior and repository reality diverge, follow the repository's actual enforced behavior first, then open an issue or PR to bring the documentation back into sync.

---

## Final Contributor Checklist

Before requesting review, confirm that:

- [ ] the change is narrowly scoped and aligned with an accepted repository need
- [ ] formatting, linting, and relevant validation commands pass locally
- [ ] tests were added or updated when appropriate, or the omission is explained
- [ ] documentation was updated where behavior, workflow, or module usage changed
- [ ] compatibility, migration, and rollback impact were assessed where relevant
- [ ] no secrets, credentials, or sensitive data were introduced
- [ ] changelog or release-facing notes were updated if required
- [ ] the PR description clearly explains intent, validation, and any reviewer attention areas

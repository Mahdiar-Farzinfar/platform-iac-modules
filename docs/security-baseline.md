# Security Baseline

This document defines the security expectations for
`platform-iac-modules`. It is an engineering baseline for module authors,
reviewers, and consumers; it does not replace the vulnerability-reporting
process in [`SECURITY.md](https://github.com/Mahdiar-Farzinfar/platform-iac-modules/blob/main/SECURITY.md).

## Scope and repository boundaries

The baseline applies to:

- Terraform modules under [`modules/`](https://github.com/Mahdiar-Farzinfar/platform-iac-modules/tree/main/modules/), including their examples,
  native tests, and integration tests.
- Repository automation under [`scripts/`](https://github.com/Mahdiar-Farzinfar/platform-iac-modules/tree/main/scripts/),
[`tests/`](https://github.com/Mahdiar-Farzinfar/platform-iac-modules/tree/main/tests/),
[`Taskfile.yml`](https://github.com/Mahdiar-Farzinfar/platform-iac-modules/blob/main/Taskfile.yml),
and the wrapper task files.
- GitHub Actions workflows, dependency configuration, tool configuration, and
  documentation.

This repository is a reusable module source repository. It does not define a
deployable environment, configure providers or credentials, own a Terraform
backend for consumers, or perform production applies. Provider configuration,
backend and state isolation, account and Region targeting, approvals, and
runtime operations belong in the consuming live-infrastructure repository.

The module catalog currently contains:

| Module | Security-relevant capability |
| --- | --- |
| `backend-bootstrap` | Encrypted, private Terraform state storage and locking prerequisites |
| `github-oidc` | Short-lived GitHub Actions to AWS federation with repository-scoped trust |
| `kms` | Customer-managed KMS keys, policies, aliases, and grants |
| `log-archive-bucket` | Private, encrypted, versioned S3 log retention |
| `cloudtrail` | Account-level audit logging and secure log delivery |
| `guardduty` | Regional threat detection and optional organization settings |
| `scp` | AWS Organizations preventive guardrails |

The authoritative inventory is
[`catalog/modules.yaml`](https://github.com/Mahdiar-Farzinfar/platform-iac-modules/blob/main/catalog/modules.yaml),
and each module README is
the source of truth for its exact interface, prerequisites, defaults, and
limitations.

## Security objectives

Changes to this repository should preserve these objectives:

1. **Secure defaults.** Encryption, private access, transport security,
   least privilege, auditability, and deletion safeguards should be enabled
   where the service and module boundary support them.
2. **Explicit contracts.** Inputs, outputs, account and Region assumptions,
   ownership boundaries, and destructive behavior must be typed, validated, and
   documented.
3. **Minimal authority.** IAM, KMS, S3, OIDC, and Organizations policies must
   grant only the access required by the stated module purpose.
4. **Safe change management.** Resource identity, state movement, policy scope,
   retention, and replacement risk must be reviewed as part of the change, not
   inferred from a successful Terraform plan alone.
5. **No credential material.** Credentials, tokens, private keys, real secrets,
   and production-sensitive fixtures must not be committed or emitted in logs,
   plans, examples, tests, or generated reports.
6. **Reproducible delivery.** Provider and tool versions, release references,
   and CI actions should be pinned or otherwise controlled so that a review can
   be reproduced.

## Threat model and non-goals

The primary threats are:

- insecure defaults or caller inputs that create public, unencrypted, or
  overly permissive AWS resources;
- accidental disclosure through Terraform state, plan files, outputs, policy
  documents, logs, test fixtures, or CI artifacts;
- overly broad GitHub OIDC trust or IAM permissions;
- malformed or unintended KMS, S3, IAM, or SCP policy changes;
- resource replacement, deletion, or state-address changes that cause data loss
  or security-control gaps;
- unauthorized repository changes, workflow abuse, dependency compromise, and
  secret leakage;
- incorrect account, Region, delegated-administrator, or organization context
  in a consuming configuration.

This baseline does not replace AWS service controls, organizational policy,
consumer-side identity governance, provider authentication, runtime
monitoring, incident response, or compliance-specific retention decisions. A
module can provide a secure building block, but its actual posture depends on
the consumer's values, provider aliases, account architecture, deployment
workflow, and operational controls.

## Common module requirements

Every module should:

- remain narrowly scoped and provider/backend neutral;
- declare Terraform and provider constraints in `versions.tf`;
- use typed variables with descriptions and validation for constrained or
  policy-sensitive values;
- fail closed where practical and make security-sensitive opt-outs explicit;
- avoid hard-coded account IDs, organization IDs, repositories, branches,
  credentials, or environment names unless they are deliberate inputs;
- preserve stable `for_each` keys, resource addresses, names, and outputs;
- document prerequisites, caller-owned resources, cross-account behavior,
  costs, retention, and destructive operations;
- expose only the identifiers and values needed for composition;
- mark a value `sensitive` when it may contain secret or confidential data;
- include native Terraform tests for inputs, defaults, conditional resources,
  policy behavior, and outputs; add integration coverage when the risk warrants
  live AWS validation;
- keep examples minimal and free of real account identifiers or secrets.

Do not add a Terraform backend block, provider credentials, or environment
deployment orchestration to a reusable module. Do not run `terraform apply` from
the repository root as a production workflow.

## Module security baselines

### `backend-bootstrap`

This module creates persistent Terraform state infrastructure and therefore
requires stronger lifecycle review than an ordinary example module.

- Require a customer-managed KMS key ARN for state and lock-table encryption.
- Keep S3 versioning, Bucket Owner Enforced ownership, all four public-access
  block settings, and TLS-only access enabled.
- Enforce KMS encryption and the expected KMS key on state-object writes.
- Keep DynamoDB point-in-time recovery, deletion protection, and
  `prevent_destroy` enabled for persistent use.
- Keep `force_destroy = false` in production. Use it only for explicitly
  ephemeral test bootstraps.
- Treat `backend_config` and `backend_hcl_snippet` as operationally sensitive
  configuration. Do not publish them with state paths, credentials, or plans.
- Apply the bootstrap with carefully controlled local state, then migrate the
  state deliberately; the module intentionally has no backend block.

### `github-oidc`

This module controls a trust boundary between GitHub and AWS.

- Prefer exact `subjects` with `StringEquals`; use `subject_patterns` only when
  necessary and only with the module's repository-scoped validation.
- Keep the audience restricted to the intended value, normally
  `sts.amazonaws.com`.
- Grant no workload permissions by default. Attach only the managed or inline
  policies required by each workflow, and use a permissions boundary where
  appropriate.
- Use protected GitHub environments and branch or tag subjects for sensitive
  deployments. Do not trust an entire organization or repository with a broad
  wildcard when a narrower subject is available.
- Use short-lived OIDC credentials; never add long-lived AWS access keys to
  workflows, examples, or repository variables.
- Create the account-level provider once and establish one clear owner for it.

### `kms`

- Keep key-policy lockout safety enabled unless a reviewed exception explains
  the recovery path.
- Preserve the account-root recovery statement and separate key
  administrators, key users, and service users by need.
- Keep keys enabled and automatic rotation enabled by default for supported
  symmetric keys.
- Treat `bypass_policy_lockout_safety_check`, policy overrides, grants, and
  deletion-window changes as high-risk changes.
- Use the shortest practical principal and resource scope in caller-supplied
  policy documents. Validate unique statement IDs and review the rendered
  policy, not just the HCL inputs.
- Treat key deletion as an explicit lifecycle event; the default deletion
  window is a safety mechanism, not a retention policy.

### `log-archive-bucket`

- Keep `BucketOwnerEnforced`, all public-access-block settings, versioning, and
  TLS-only access enabled.
- Use server-side encryption for every object; use SSE-KMS when the consumer
  requires customer-managed key control and has configured the key policy.
- Keep `force_destroy = false` for retained logs.
- Review lifecycle expiration, noncurrent-version expiration, and transitions
  against the consumer's legal, audit, and incident-response retention needs.
- Enable Object Lock at creation time when WORM retention is required. Choose
  `GOVERNANCE` versus `COMPLIANCE` deliberately because the latter cannot be
  overridden, including by the account root principal.
- Keep delivery principals limited to services that are actually configured to
  write to the bucket, and review the generated bucket policy.

### `cloudtrail`

- Keep logging enabled, multi-Region coverage, global service events, log-file
  validation, KMS encryption, private versioned S3 storage, and CloudWatch Logs
  delivery enabled unless a documented architecture requires otherwise.
- Review existing account and organization trails before creating another one;
  duplicate management-event logging can increase cost and obscure ownership.
- Treat `s3_force_destroy`, KMS deletion-window changes, event-selector changes,
  lifecycle expiration, and caller-owned bucket or key policies as high-risk.
- Verify that the KMS key policy, S3 bucket policy, CloudTrail service
  principal, and CloudWatch Logs role are mutually compatible.
- Remember that this module creates a standard account trail. It does not
  create an Organizations trail, CloudTrail Lake store, alarms, or the
  consumer's broader monitoring and response workflow.

### `guardduty`

- Keep the detector enabled by default and deploy one deliberate module owner
  per covered account and Region.
- Review changes to detector features, findings filters, trusted IP sets, and
  threat-intelligence feeds; disabling or archiving findings can create a
  detection gap.
- For findings export, use a private S3 bucket and KMS key whose resource
  policies explicitly permit GuardDuty. This module references those resources
  but does not manage their policies.
- Treat organization administration and auto-enrollment as account-context
  sensitive operations. Delegating the administrator belongs in the management
  account; organization configuration belongs in the delegated administrator
  context.
- Document the Regions and accounts covered; GuardDuty is regional and one
  detector does not establish organization-wide coverage by itself.

### `scp`

- Treat every policy or target change as a potentially organization-wide
  production change.
- Use the management-account provider context, validate target IDs, and review
  the fully rendered JSON document and attachment set before applying.
- Keep policy statements narrow, explicit, and justified. Avoid broad denies
  that can block break-glass access, security services, billing, or recovery
  workflows without a tested exception path.
- Remember that an SCP limits maximum permissions; it does not grant IAM
  permissions.
- Treat `skip_destroy`, policy-content overrides, target-list changes, and
  attachment changes as high-risk and include rollback or recovery guidance.

## State, outputs, and data handling

Terraform state, plans, policy documents, generated reports, and CI logs can
reveal resource names, account identifiers, trust
relationships, or security design. Handle them as sensitive operational data.

- Never commit `*.tfstate`, plan files, credentials, private keys, secret
  variables, provider caches, or scanner artifacts. Repository ignore rules
  cover the common Terraform, secret, report, and cache patterns, but an ignore
  rule is not a security control.
- Protect consumer backends with encryption, access logging where appropriate,
  least-privilege IAM, versioning, and controlled artifact retention.
- Do not place raw policy documents, tokens, or secret values in outputs when an
  ARN, ID, name, or boolean is sufficient.
- Review outputs after changes with
  [`scripts/tools/validate-outputs.py`](https://github.com/Mahdiar-Farzinfar/platform-iac-modules/blob/main/scripts/tools/validate-outputs.py)

  and check that generated CI output cannot be interpreted as shell or workflow
  input.
- Redact account-specific values and sensitive plan details from issue reports,
  pull requests, test logs, and uploaded artifacts.

## CI, validation, and security gates

The repository's canonical automation entry point is [`Taskfile.yml`](https://github.com/Mahdiar-Farzinfar/platform-iac-modules/blob/main/Taskfile.yml).
`Makefile` and `justfile` are convenience wrappers. Run the narrowest relevant
checks during development and the complete applicable gate before review.

### Validation workflow

`.github/workflows/validate.yml` runs for relevant pull requests and pushes to
`main`, with manual dispatch modes for full or module validation. Its module
checks include:

- toolchain and environment verification;
- Terraform formatting, backend-disabled initialization, validation, and native
  `*.tftest.hcl` tests;
- TFLint using [`tooling/.tflint.hcl`](https://github.com/Mahdiar-Farzinfar/platform-iac-modules/blob/main/tooling/.tflint.hcl);
- Go formatting, vetting, linting, and tests where Go code exists;
- Markdown, YAML, and GitHub Actions linting;
- generated documentation checks using [`.terraform-docs.yml`](https://github.com/Mahdiar-Farzinfar/platform-iac-modules/blob/main/.terraform-docs.yml);
- repository smoke and cross-platform checks where selected by the workflow.

The workflow expects deterministic provider resolution and validates module
lockfile behavior. A successful validation job is necessary but is not proof
that a consumer's account, organization, or runtime configuration is safe.

### Security-scan workflow

`.github/workflows/security-scan.yml` runs on pull requests, pushes to `main`,
and on a weekly schedule. It uses least-privilege job permissions and runs:

- **Checkov:** Terraform scanning with
  [`tooling/.checkov.yml`](https://github.com/Mahdiar-Farzinfar/platform-iac-modules/blob/main/tooling/.checkov.yml).
  The SARIF pass is
  soft-fail for report collection; the enforcing CLI pass is not soft-fail.
  No global `skip-check` entries are configured.
- **Trivy:** IaC and filesystem scanning for HIGH and CRITICAL findings, with
  unfixed findings ignored and an explicit non-zero exit code.
- **Gitleaks:** repository secret scanning through `task security:gitleaks`.
- **OSV-Scanner:** dependency vulnerability reporting. The current workflow
  allows the OSV command to complete with `|| true`, so maintainers must review
  its report rather than treating a successful job as proof that no dependency
  findings exist.

Locally, `task security:all` runs Checkov, Trivy, and Gitleaks. Local Trivy
includes MEDIUM findings and uses
[`tooling/.trivyignore`](https://github.com/Mahdiar-Farzinfar/platform-iac-modules/blob/main/tooling/.trivyignore).
Any exception must be narrow,
reviewed, and documented with an owner, rationale, expiry date, and tracking
reference. Do not use scanner exclusions to hide production IaC.

### Additional assurance

`.github/workflows/scorecard.yml` runs OpenSSF Scorecard on pushes, branch
protection changes, and a weekly schedule, then uploads SARIF results. Treat
workflow permission changes, third-party actions, dependency updates, and
development-container changes as supply-chain security changes.

## Review and release controls

All paths are routed through [`CODEOWNERS`](https://github.com/Mahdiar-Farzinfar/platform-iac-modules/blob/main/CODEOWNERS), currently to
`@Mahdiar-Farzinfar`. Reviewers should require additional evidence for changes
to:

- IAM trust or permission policies, GitHub OIDC subjects, KMS policies, S3
  bucket policies, CloudTrail delivery, GuardDuty organization settings, or
  SCPs;
- resource addresses, `for_each` keys, names, lifecycle rules, deletion
  protection, retention, or `force_destroy`;
- CI workflow permissions, action references, bootstrap installers, scanner
  configuration, or ignore files;
- release-domain mapping, version constraints, provider upgrades, or generated
  documentation.

Before merge, the pull request should state:

- the affected module or release domain;
- security and blast-radius impact;
- state migration, replacement, retention, and rollback implications;
- validation and security checks run, including any unavailable cloud-backed
  tests;
- the reason, owner, and expiry for every accepted scanner exception.

Modules are released independently with immutable tags in the form
`module/<module-name>/vX.Y.Z`. Root automation and documentation use the
`root/vX.Y.Z` domain. Consumers should pin an immutable module tag, review the
module README and release notes, and promote changes through a lower-risk
environment before production.

Per [`SECURITY.md`](https://github.com/Mahdiar-Farzinfar/platform-iac-modules/blob/main/SECURITY.md),
security fixes are guaranteed only for the
latest release of the affected release domain. Report vulnerabilities privately
through GitHub's private vulnerability reporting; do not open a public issue.

## Contributor checklist

Before requesting review for a security-relevant change, confirm:

- [ ] The change stays within the reusable-module boundary and does not add
      environment deployment or credential handling.
- [ ] Inputs are typed, validated, documented, and secure by default.
- [ ] Outputs are minimal and sensitive values are marked appropriately.
- [ ] IAM, KMS, S3, OIDC, CloudTrail, GuardDuty, or SCP policy changes were
      reviewed from the rendered policy and correct account/Region context.
- [ ] Destructive behavior, retention, resource replacement, and state-address
      impact are documented with migration or rollback guidance.
- [ ] Examples and tests contain no real secrets, credentials, or production
      identifiers.
- [ ] Relevant Terraform tests, Go tests, smoke tests, and cloud-backed tests
      have run or their limitations are documented.
- [ ] `task fmt`, `task validate:terraform`, `task lint:tflint`,
      `task security:all`, `task docs:check`, and relevant repository checks
      pass, or any exception is explicit and approved.
- [ ] New scanner ignores, workflow permissions, dependencies, and action
      references have a narrow, documented justification.
- [ ] The correct module-scoped or root release impact is identified.

When this document and an implementation detail diverge, treat the workflow,
module code, module README, and `SECURITY.md` as the immediate sources of truth,
then update this baseline in the same change.

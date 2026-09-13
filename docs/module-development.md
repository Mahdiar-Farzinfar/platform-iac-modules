# Terraform Module Development Guide

This guide defines how to design, change, test, document, and release modules
in `platform-iac-modules`.

## Repository role and boundaries

`platform-iac-modules` is a library of reusable, versioned, stateless Terraform
modules for AWS platform foundations. The modules are consumed by a separate
live-infrastructure repository that owns:

- provider configuration, credentials, aliases, and `default_tags`;
- backend configuration and state isolation;
- account, organization, and Region targeting;
- environment-specific values and dependency ordering;
- approvals, deployment orchestration, and `terraform apply`;
- runtime operations, drift management, and post-apply verification.

Do not add environment composition, credentials, or a Terraform backend block
to a reusable module. Do not use the repository root or `modules/` as a
production deployment root. A module's `examples/basic` directory is a
standalone root module for development and demonstration only.

## Module portfolio

The current module boundaries are:

| Module | Responsibility | Typical scope |
| --- | --- | --- |
| `backend-bootstrap` | Hardened S3 and DynamoDB prerequisites for Terraform remote state | One state-owning account and Region |
| `github-oidc` | GitHub Actions OIDC provider and repository-scoped IAM roles | Account-global IAM |
| `kms` | Customer-managed KMS keys, policies, aliases, and grants | One account and Region per instance |
| `log-archive-bucket` | Private, encrypted, versioned S3 log archive | One account and Region |
| `cloudtrail` | Account-level CloudTrail and secure destinations | One account and trail home Region |
| `guardduty` | Regional GuardDuty detector and protection features | One account and Region; organization operations are context-specific |
| `scp` | AWS Organizations Service Control Policy and attachments | Organizations management account |

Keep each module focused on one capability. Compose modules in the consuming
repository instead of hiding unrelated dependencies inside a module. The
module README and [`catalog/modules.yaml`](https://github.com/Mahdiar-Farzinfar/platform-iac-modules/blob/main/catalog/modules.yaml)
describe
the public inventory; the module README is authoritative for the module's
exact inputs, outputs, prerequisites, defaults, and limitations.

## Standard module structure

Every current module follows this structure:

```text
modules/<module-name>/
├── README.md                  # Narrative guide plus generated API reference
├── main.tf                    # Resources and module behavior
├── variables.tf               # Public inputs and validation
├── outputs.tf                 # Public outputs
├── versions.tf                # Terraform and provider constraints
├── locals.tf                  # Derived values and policy composition
├── examples/
│   └── basic/
│       └── main.tf            # Standalone consumer-facing example
└── tests/
    ├── <module>.tftest.hcl    # Native Terraform tests
    └── integration_test.go    # Optional Go/AWS integration tests
```

`integration_test.go` is present only for `cloudtrail`, `guardduty`, `kms`, and
`scp`. All seven modules currently have a native `*.tftest.hcl` test file.
Use additional files only when they improve the module's contract or test
layout; do not create empty structural files.

File responsibilities:

- `versions.tf`: minimum Terraform and provider constraints. Never configure
  providers or backends here.
- `variables.tf`: typed public inputs, descriptions, defaults, validation, and
  nullability.
- `outputs.tf`: stable public outputs, descriptions, and sensitivity metadata.
- `main.tf`: primary resources and module behavior.
- `locals.tf`: normalized names, derived values, policy documents, and internal
  constants.
- `examples/basic/main.tf`: a minimal root module that configures its own
  provider and demonstrates the module interface.
- `tests/*.tftest.hcl`: native tests for plan-time behavior and module
  contracts.
- `tests/integration_test.go`: Go tests when provider-backed validation is
  justified.

## Design the public contract first

Treat variables and outputs as a versioned API used by external live
repositories.

### Inputs

For every variable:

- use an explicit Terraform type;
- provide a precise description and document ownership of the value;
- choose a secure default only when it is broadly safe;
- add `validation` for names, enumerations, ranges, ARNs, policy-sensitive
  values, and mutually exclusive modes;
- use `nullable = false` when `null` is not meaningful;
- mark secret-bearing inputs as `sensitive = true`;
- avoid `any` unless a provider schema or intentionally pass-through policy
  document requires it;
- avoid hard-coded account IDs, Regions, OUs, repositories, branches, and
  environments unless they are deliberate caller inputs.

Prefer a typed `object` for cohesive configuration. Use stable map keys for
`for_each`; those keys are part of the consumer's Terraform state contract.

### Outputs

For every output:

- provide a useful description;
- expose identifiers needed for composition, such as names, IDs, ARNs, and
  booleans;
- mark values sensitive when they may contain confidential data;
- avoid exporting raw secrets, full policy documents, private configuration, or
  implementation details unless a consumer genuinely needs them;
- preserve output names and types after release.

Run [`scripts/tools/validate-outputs.py`](https://github.com/Mahdiar-Farzinfar/platform-iac-modules/blob/main/scripts/tools/validate-outputs.py)
when changing outputs. A narrow output is preferable to requiring consumers to
parse internal resources or policy JSON.

### Provider and backend neutrality

Modules may declare `required_providers` and version constraints, but must not
declare provider blocks, credentials, regions, aliases, or `default_tags`.
Modules must not contain backend blocks. The consuming root module configures
the provider and commits the dependency lock file appropriate for its
composition.

Provider constraints should be feature-driven and bounded deliberately. A
provider-major upgrade that changes resource schemas or behavior requires
compatibility testing and may require a major module release.

### Names, tags, and ownership

Names should be deterministic and caller-controlled. Preserve caller tags while
using module-managed tags only for stable ownership or purpose metadata. Do not
derive names from workspaces, accounts, or Regions unless that behavior is
explicitly documented and represented in the interface.

Document which resources the module owns and which resources remain caller
owned. Existing buckets, KMS keys, OIDC providers, log destinations, and
organization settings must have one clear Terraform owner.

## Security and operational defaults

Security-sensitive modules should fail closed where practical and make broad or
destructive behavior explicit.

Common expectations include:

- encryption at rest and TLS-only access where supported;
- S3 public-access blocking and `BucketOwnerEnforced` ownership;
- least-privilege IAM and exact GitHub OIDC subjects;
- narrow KMS principals, preserved lockout recovery, and rotation defaults;
- versioning, retention, deletion protection, and `prevent_destroy` for
  persistent state or audit data;
- `force_destroy = false` for persistent buckets;
- explicit review for SCP target changes, organization settings, policy
  overrides, key deletion, Object Lock, and resource replacement;
- no static credentials, tokens, private keys, or real secrets in source,
  examples, tests, documentation, plans, or logs.

For high-impact changes, review the rendered IAM, KMS, S3, CloudTrail,
GuardDuty, OIDC, or SCP policy and the intended account/Region context rather
than relying only on HCL appearance.

## Examples

Examples are standalone Terraform root modules, not production stacks. They
must:

- configure their own provider and required providers;
- use a local module source such as `source = "../.."`;
- use placeholder names and no real account IDs, secrets, or organization IDs;
- explain prerequisites, cost, and cleanup behavior;
- remain syntactically valid and aligned with the module interface.

Examples may create billable or high-impact AWS resources. Several current
examples intentionally use teardown-friendly settings such as
`force_destroy = true` or a shorter KMS deletion window. Those values must be
clearly labeled and must not be copied into production configurations.

The `backend-bootstrap` example intentionally starts with local state because
the module creates the backend infrastructure. The `scp` example can attach a
policy to an organization root and therefore requires especially careful
account-context and blast-radius review.

## Documentation workflow

Each module README contains human-written narrative outside these markers:

```markdown
<!-- BEGIN_TF_DOCS -->
<!-- END_TF_DOCS -->
```

The content between the markers is generated by `terraform-docs` using
[`.terraform-docs.yml`](https://github.com/Mahdiar-Farzinfar/platform-iac-modules/blob/main/.terraform-docs.yml).
Keep generated content
reproducible and do not hand-edit it. Update the narrative sections when
behavior, prerequisites, security assumptions, costs, ownership, or migration
steps change.

From the repository root, use:

```text
task docs
task docs:check
```

For one module:

```text
terraform-docs markdown table \
  --config .terraform-docs.yml \
  --output-file README.md \
  --output-mode inject \
  modules/cloudtrail
```

When changing variables, outputs, requirements, providers, or examples,
regenerate the affected README and review the generated diff. Documentation
changes to `modules/<module-name>/` belong to that module's release domain;
high-level documentation under `docs/` belongs to the `root` domain.

## Testing strategy

Testing depth should match the module's blast radius.

### Native Terraform tests

Native tests live in `modules/<module-name>/tests/<module>.tftest.hcl` and
should cover:

- required values and validation failures;
- secure defaults and opt-out behavior;
- conditional resource creation;
- IAM, KMS, S3, OIDC, CloudTrail, GuardDuty, or SCP policy shape;
- output presence, type, sensitivity, and stability;
- state-sensitive behavior where practical.

Run all native module tests with:

```text
task test:terraform
```

For one module:

```text
terraform -chdir=modules/cloudtrail init -backend=false
terraform -chdir=modules/cloudtrail test
```

### Go integration tests

Go integration tests are provider-backed tests for `cloudtrail`, `guardduty`,
`kms`, and `scp`. The `cloudtrail`, `guardduty`, and `kms` suites use the
`integration` build tag. The `scp` suite is always compiled and skips its live
tests only when run with `-short`; it also requires organization-specific
environment variables. These suites may create billable resources or affect
account and organization controls. Run them only with an approved sandbox or
test account, the minimum documented permissions, and an explicit cleanup plan.

Run one tagged module's integration suite from the repository root:

```text
go test -tags=integration -count=1 -timeout 30m -v ./modules/kms/tests
```

Run the SCP suite in its short, non-cloud mode with:

```text
go test -short -count=1 -timeout 30m -v ./modules/scp/tests
```

Run live SCP tests only after setting the required variables documented in
`modules/scp/tests/integration_test.go` and confirming the management-account
blast radius.

The repository exposes `task test:go` and the Windows equivalent as wrappers
for Go validation, but their current implementation does not add the
`integration` build tag or `-short`. Treat the explicit commands above as the
reliable integration invocations, and update the task implementation if the
repository intends `task test:go` to execute only safe or explicitly tagged
suites.

Do not assume that static Terraform tests prove safety in every account,
Region, provider alias, or organization. Cloud-backed test requirements and
limitations belong in the module README and pull request.

### Repository-level tests

Use the repository's canonical tasks for changes outside a single module:

```text
task test:smoke
task test:cross-platform
```

The Python smoke runner under `tests/smoke/` is the source of truth; the shell
and PowerShell files are platform wrappers. Cross-platform tests cover the
supported Linux, macOS, and Windows execution paths.

## Validation and security gates

Use `task` as the canonical interface. `make` and `just` are convenience
wrappers.

For a module implementation change, the normal local sequence is:

```text
task preflight
task fmt:terraform
task validate:terraform
task lint:tflint
task test:terraform
task docs:check
task security:all
```

Before review, run the complete relevant workflow:

```text
task ci
```

The validation workflow checks formatting, backend-disabled initialization,
Terraform validation, native tests, TFLint, generated documentation, and
repository language/workflow checks. The security workflow runs Checkov,
Trivy, Gitleaks, and OSV reporting; the exact enforcement and exclusions are
defined in `.github/workflows/security-scan.yml` and `tooling/`.

Pre-commit hooks also cover Markdown, YAML, Actions, Terraform formatting and
docs injection, secret/private-key detection, toolchain sanity, and selected
pre-push tests. Install them with:

```text
pre-commit install
pre-commit run --all-files
```

If a check cannot run because it requires cloud access or an unavailable tool,
record the limitation and the alternative evidence in the pull request.

## State, identity, and migration safety

Terraform validity is not enough. Review any change that can:

- force resource replacement or deletion;
- change resource addresses, `for_each` keys, or `count` behavior;
- rename public outputs, resource names, aliases, buckets, roles, or policies;
- alter ownership of a caller-created resource;
- change retention, Object Lock, deletion protection, or key deletion;
- change IAM, KMS, S3, OIDC, CloudTrail, GuardDuty, or SCP scope.

For state-sensitive changes, document:

- the old and new resource graph or address;
- whether consumers need `moved` blocks, imports, or manual migration;
- whether a plan can replace or destroy existing data;
- rollback limits, including irreversible policy, key, retention, or deletion
  effects;
- the lower-environment validation performed.

Do not commit state, plans, provider caches, generated reports, credentials, or
tool binaries. Treat state and plan artifacts as sensitive operational data.

## Catalog, releases, and compatibility

When adding a module:

1. Confirm that the capability belongs in this repository rather than the live
   infrastructure repository.
2. Add the complete standard structure, a focused README, a basic example, and
   native tests.
3. Add the module to [`catalog/modules.yaml`](https://github.com/Mahdiar-Farzinfar/platform-iac-modules/blob/main/catalog/modules.yaml) using
   the directory name as `name` and the correct `path`.
4. Run documentation generation, validation, tests, security scans, and smoke
   checks as appropriate.

Module changes are released independently with immutable tags:

```text
module/<module-name>/v<MAJOR>.<MINOR>.<PATCH>
```

Use the release workflow and
[`docs/versioning.md`](./versioning.md) for the exact domain mapping,
Conventional Commit bump rules, changelog behavior, and consumer upgrade
procedure. A module change must not force unrelated module releases.

Treat the following as potentially breaking:

- removed or renamed inputs and outputs;
- changed types, defaults, validation, or security posture;
- changed resource identity, state addresses, ownership, or retention;
- changed Terraform/provider compatibility;
- changes requiring consumer-side policy, provider, or account-context work.

Use a major-bump signal for breaking changes, document migration and rollback
guidance in the module README and release notes, and keep deprecations explicit
for as long as practical.

## Pull request checklist

Before requesting review, confirm:

- [ ] The module remains narrowly scoped and provider/backend neutral.
- [ ] Inputs are typed, described, validated, and secure by default.
- [ ] Outputs are minimal, stable, described, and sensitive where appropriate.
- [ ] Resource addresses, `for_each` keys, names, policies, and ownership were
      reviewed for state or replacement impact.
- [ ] `examples/basic/main.tf` reflects the supported interface and contains no
      real secrets or production identifiers.
- [ ] Native tests cover changed behavior; Go integration tests are updated
      when provider-backed risk warrants them.
- [ ] The module README narrative and generated Terraform docs are synchronized.
- [ ] `catalog/modules.yaml` is updated for new modules or metadata changes.
- [ ] Relevant `task` validation, security, test, and documentation checks pass
      or limitations are documented.
- [ ] Release impact is identified as patch, minor, or major.
- [ ] Breaking changes include migration, state, and rollback guidance.

If this guide diverges from module code, the module README, `Taskfile.yml`,
workflow files, or executable Terraform constraints, follow the enforced
implementation first and update this guide in the same change.

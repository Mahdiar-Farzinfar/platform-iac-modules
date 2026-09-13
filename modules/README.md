# Terraform Modules

Reusable Terraform building blocks for the AWS platform foundation. The
modules in this directory are designed to be composed by a separate live
infrastructure repository, where providers, backends, account targeting,
environment values, approvals, and deployment orchestration are defined.

> [!IMPORTANT]
> This directory contains reusable modules, not deployable environments. Do
> not run `terraform apply` from `modules/` or from the repository root.
> Consume a released module from a live infrastructure repository, or use a
> module's `examples/basic` directory for isolated development and testing.

## Contents

- [Module catalog](#module-catalog)
- [Common module contract](#common-module-contract)
- [Directory layout](#directory-layout)
- [Choose the right module](#choose-the-right-module)
- [Consume a released module](#consume-a-released-module)
- [Local development](#local-development)
- [Validation and testing](#validation-and-testing)
- [Authoring and review checklist](#authoring-and-review-checklist)
- [Versioning and upgrades](#versioning-and-upgrades)
- [Ownership and security](#ownership-and-security)

## Module catalog

| Module | Capability | Typical scope | Documentation |
| --- | --- | --- | --- |
| [`backend-bootstrap`](./backend-bootstrap/) | Creates hardened S3 and DynamoDB prerequisites for Terraform remote state | One state-owning account and Region | [`README.md`](./backend-bootstrap/README.md) |
| [`cloudtrail`](./cloudtrail/) | Configures an account-level, secure CloudTrail trail and optional destinations | One AWS account and trail home Region | [`README.md`](./cloudtrail/README.md) |
| [`github-oidc`](./github-oidc/) | Establishes GitHub Actions OIDC federation and repository-scoped IAM roles | Account-global IAM resources | [`README.md`](./github-oidc/README.md) |
| [`guardduty`](./guardduty/) | Enables GuardDuty, protection features, finding controls, publishing, and optional Organizations settings | One account and Region; organization operations are account-context specific | [`README.md`](./guardduty/README.md) |
| [`kms`](./kms/) | Creates customer-managed KMS primary or replica keys, policies, aliases, and grants | One account and Region per module instance | [`README.md`](./kms/README.md) |
| [`log-archive-bucket`](./log-archive-bucket/) | Provides a private, encrypted, versioned S3 archive for centralized logs | One account and Region | [`README.md`](./log-archive-bucket/README.md) |
| [`scp`](./scp/) | Creates and attaches an AWS Organizations Service Control Policy | Organization management account | [`README.md`](./scp/README.md) |

The module README is the authoritative source for a module's exact inputs,
outputs, prerequisites, defaults, security behavior, and operational
limitations. Read it before selecting a version or changing a live stack.

## Common module contract

All modules in this directory follow the same boundary rules:

- **Provider-neutral:** modules declare `required_providers` and version
  constraints, but do not configure providers, credentials, regions, aliases,
  or `default_tags`.
- **Backend-neutral:** modules do not contain Terraform backend blocks. Backend
  configuration belongs to the consuming root module.
- **Explicit interfaces:** inputs are typed, validated where practical, and
  documented. Outputs expose stable values useful for composition and policy
  wiring.
- **Secure defaults:** encryption, private access, least privilege, transport
  security, retention, and deletion guard rails are preferred where the AWS
  service supports them.
- **Clear ownership:** a module manages resources it creates. Caller-owned
  resources, such as an existing bucket or KMS key, remain the caller's
  responsibility unless the module README explicitly says otherwise.
- **Composable behavior:** account, Region, environment, dependency ordering,
  and rollout decisions stay in the live infrastructure repository.
- **Stable resource identity:** keys used with `for_each` are part of the
  Terraform state contract. Keep map keys stable; renaming one can replace a
  resource.

The calling root module should configure the provider, commit its
`.terraform.lock.hcl`, and pass environment-specific names, tags, principals,
retention values, and policy documents.

## Directory layout

Each module uses a predictable layout:

```text
modules/<module-name>/
├── README.md                  # Narrative guide plus generated API reference
├── main.tf                    # Resources and module behavior
├── variables.tf               # Typed and validated inputs
├── outputs.tf                 # Public outputs
├── versions.tf                # Terraform and provider constraints
├── locals.tf                  # Derived names, policies, and tag maps
├── examples/
│   └── basic/
│       └── main.tf            # Minimal runnable example
└── tests/
    ├── <module>.tftest.hcl    # Native Terraform tests
    └── integration_test.go    # Optional live AWS tests for higher-risk modules
```

The `integration_test.go` file is present only where infrastructure-level
testing is useful. The basic examples are intentionally small and may use
ephemeral-friendly settings; they are not production configurations.

## Choose the right module

Use the smallest module that owns the capability you need, and compose modules
in the live repository when a larger platform stack is required.

| Need | Start with | Important boundary |
| --- | --- | --- |
| Bootstrap remote state | `backend-bootstrap` | First apply uses local state; migrate state only after the backend exists |
| Encrypt a platform resource | `kms` | Principals and identity policies must already exist |
| Store centralized audit or service logs | `log-archive-bucket` | Log-producing services and the KMS key policy are configured separately |
| Record account audit events | `cloudtrail` | Review existing account and organization trails before creating another |
| Detect threats | `guardduty` | Deploy per covered account and Region; organization administration uses the correct account context |
| Authenticate GitHub Actions to AWS | `github-oidc` | Trust exact subjects and grant workload permissions separately |
| Apply organization guardrails | `scp` | SCPs restrict permissions; they do not grant them |

Common compositions include:

```text
backend-bootstrap ──> live repository backends
kms ────────────────> cloudtrail, log-archive-bucket, and application encryption
log-archive-bucket ─> cloudtrail and other log producers
github-oidc ────────> CI/CD deployment roles
scp ────────────────> organization-wide governance boundaries
guardduty ──────────> account/Region threat detection and findings export
```

The arrows describe a common dependency or integration relationship, not an
implicit Terraform dependency. Wire actual dependencies explicitly in the
consuming repository.

## Consume a released module

Production consumers should use an immutable, module-scoped release tag:

```hcl
module "cloudtrail" {
  source = "git::https://github.com/Mahdiar-Farzinfar/platform-iac-modules.git//modules/cloudtrail?ref=module/cloudtrail/v1.2.0"

  name       = "platform-audit"
  trail_name = "platform-audit"

  tags = {
    Environment = "production"
    Owner       = "security-platform"
  }
}
```

Release tags follow:

```text
module/<module-name>/v<MAJOR>.<MINOR>.<PATCH>
```

Do not use `main`, an unpinned branch, or a mutable reference for a production
deployment. Review the selected module README and the repository changelog
before upgrading.

For local composition or development from a root module at the repository root,
use a relative source:

```hcl
module "log_archive" {
  source = "./modules/log-archive-bucket"

  bucket_name = "example-log-archive-123456789012"
}
```

The consuming root module owns:

1. `terraform` and `required_providers` configuration.
2. Provider configuration, aliases, assume-role behavior, account, and Region.
3. Backend and state isolation.
4. Environment-specific values, dependency ordering, approvals, and apply.
5. The dependency lock file and the approved module version.

Initialize and plan from that consuming repository:

```text
terraform init
terraform plan
```

Apply only through the live repository's approved workflow.

## Local development

From the repository root, use `task` as the canonical interface. `make` and
`just` are convenience wrappers.

```text
task preflight
task fmt:terraform
task validate:terraform
task lint:tflint
task test:terraform
task docs:check
```

To work on one module directly:

```text
terraform -chdir=modules/cloudtrail init -backend=false
terraform -chdir=modules/cloudtrail validate
terraform -chdir=modules/cloudtrail test
terraform-docs -c .terraform-docs.yml modules/cloudtrail
```

Use a module's `examples/basic` directory when you need to inspect a real plan.
Examples that create AWS resources may incur charges and require credentials;
read the example comments and module README before applying.

## Validation and testing

Every module should pass the repository's quality gates:

- `terraform fmt` for consistent source formatting
- `terraform validate` for configuration and provider-schema correctness
- TFLint and configured policy/security scanners
- Native Terraform tests using mocked or plan-only behavior where possible
- Documentation generation with the repository's pinned `terraform-docs`
  configuration
- Pre-commit checks and CI workflows

Integration tests are opt-in and may create billable or organization-impacting
resources. Run them only with an explicitly approved sandbox or test account
and the permissions described in the module README:

```text
go test -v -tags=integration -timeout 45m ./modules/<module-name>/tests/...
```

Do not treat a successful static test run as proof that a module is safe to
apply in every account, Region, or organization. Review provider aliases,
resource policies, quotas, retention, and the complete plan.

## Authoring and review checklist

When adding or changing a module:

- Keep the module narrowly scoped and avoid environment-specific values.
- Update `main.tf`, `variables.tf`, `outputs.tf`, `versions.tf`, and `locals.tf`
  consistently.
- Keep provider configuration and backend state outside the module.
- Add or update `examples/basic/main.tf`.
- Add native tests for defaults, validations, conditional resources, and output
  behavior; add integration coverage when risk warrants it.
- Document prerequisites, ownership boundaries, security controls, limitations,
  costs, and destructive operations in the module README.
- Preserve the `<!-- BEGIN_TF_DOCS -->` and `<!-- END_TF_DOCS -->` markers in
  each module README so generated API documentation remains reproducible.
- Run formatting, validation, linting, tests, security checks, and
  `task docs:check` before opening a pull request.
- Use a Conventional Commit scope that identifies the affected module, such as
  `feat(cloudtrail): add data event selector support`.
- Call out breaking input, output, naming, state-address, or security-default
  changes and include migration guidance.

Treat examples and generated documentation as part of the public module
interface. If a change alters resource addresses, state migration may be
required even when the HCL still validates.

## Versioning and upgrades

Modules are released independently using Semantic Versioning:

- **Major:** incompatible input/output behavior, resource identity changes,
  removals, or security-default changes requiring consumer action
- **Minor:** backward-compatible capabilities or inputs
- **Patch:** compatible fixes, validation improvements, documentation, or
  dependency maintenance

Before upgrading a module:

1. Read its README and changelog entries since the current version.
2. Check Terraform and AWS provider compatibility in `versions.tf`.
3. Review the plan for replacements, policy changes, retention changes, and
   state-address changes.
4. Test in a non-production account or workspace when the module manages
   security, audit, encryption, or organization resources.
5. Promote the new immutable tag through the live repository's normal approval
   process.

Keep module tags immutable. If a release is defective, publish a new patch
version rather than moving an existing tag.

## Ownership and security

These modules can manage high-impact AWS controls. Protect the Terraform state,
plan artifacts, policy documents, trust relationships, KMS configuration, and
resource identifiers produced by them.

- Never commit credentials, tokens, private keys, or real secrets.
- Use least-privilege execution roles and workload policies.
- Prefer exact IAM and GitHub OIDC subjects over broad wildcards.
- Review SCPs and organization-level changes with account and platform owners.
- Keep `force_destroy` disabled for persistent buckets and inspect destroy
  plans carefully.
- Treat KMS key deletion, S3 Object Lock, audit-log retention, and resource
  renames as explicit lifecycle decisions.
- Follow [`SECURITY.md`](../SECURITY.md) for vulnerability reporting.

For contribution workflow and pull request requirements, see
[`CONTRIBUTING.md`](../CONTRIBUTING.md). For repository-wide architecture and
release policy, see the [root README](../README.md).

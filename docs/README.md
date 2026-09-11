# Platform IaC Modules Documentation

Welcome to the documentation for **Platform IaC Modules**.

This project provides reusable, versioned, and security-focused Terraform modules for building an enterprise AWS platform foundation. The modules are designed to be consumed by a separate live infrastructure repository, where environment composition, provider configuration, backend and state management, account targeting, approvals, and deployment orchestration are owned.

> [!IMPORTANT]
> This repository contains reusable Terraform modules, not deployable environment configurations.
> Do not run `terraform apply` from the repository root or from the `modules/` directory.

## Documentation Map

| Topic | Description |
| --- | --- |
| [Documentation Home](./index.md) | Project overview, architecture, and documentation entry point |
| [Module Development](./module-development.md) | Module structure, authoring conventions, testing, and contribution guidance |
| [Security Baseline](./security-baseline.md) | Security principles, secure defaults, and operational boundaries |
| [Versioning and Releases](./versioning.md) | Module-scoped release tags, semantic versioning, and upgrade guidance |
| [Cross-Platform Development](./cross-platform.md) | Local development expectations across Linux, macOS, and Windows |

## Project Scope

The repository contains stateless Terraform modules for AWS platform foundations, including:

- Terraform remote-state prerequisites
- AWS IAM federation for GitHub Actions through OIDC
- Customer-managed AWS KMS keys and related policies
- Centralized log-archive S3 buckets
- AWS CloudTrail audit logging
- Amazon GuardDuty threat detection
- AWS Organizations Service Control Policies

The authoritative module inventory is maintained in:

```text
catalog/modules.yaml
```

For module-specific inputs, outputs, prerequisites, security behavior, and operational limitations, consult the README in the relevant module directory:

```text
modules/<module-name>/README.md
```

## Architecture Boundary

The repository follows a clear separation between reusable modules and live infrastructure.

### This repository owns

- Reusable Terraform resource definitions
- Typed and validated module inputs
- Stable module outputs
- Secure-by-default resource configuration
- Module-level examples and tests
- Documentation and release metadata
- Static validation, linting, security checks, and CI quality gates

### The live infrastructure repository owns

- Terraform root modules and environment composition
- Provider configuration and aliases
- Credentials and assume-role behavior
- AWS account and Region targeting
- Backend configuration and state isolation
- Environment-specific naming, tags, and policy values
- Dependency ordering and rollout strategy
- Approvals and production applies

A typical consumption model is:

```text
Live infrastructure repository
│
├── provider configuration
├── backend and state
├── account and Region targeting
├── environment composition
└── pinned module references
│
▼
platform-iac-modules
│
└── reusable Terraform modules
```

Modules do not configure providers, credentials, Regions, aliases, backends, or environment orchestration.

## Design Principles

The project follows these principles:

- **Single responsibility** — Each module should own one clearly defined capability.
- **Secure by default** — Defaults should favor encryption, private access, least privilege, auditability, and deletion safeguards where supported.
- **Composable** — Modules should integrate with one another without hidden coupling.
- **Explicit interfaces** — Inputs, outputs, prerequisites, assumptions, and limitations must be documented.
- **Stable upgrades** — Compatibility-impacting changes must be versioned and communicated clearly.
- **Automation-first** — Formatting, validation, testing, documentation, and security checks should be reproducible in CI.
- **Provider and backend neutrality** — Deployment-specific configuration remains outside the reusable module boundary.
- **Cross-platform contributor experience** — Local workflows should remain usable across supported operating systems.

## Module Consumption

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

Module release tags follow this format:

```text
module/<module-name>/v<MAJOR>.<MINOR>.<PATCH>
```

Do not use `main`, an unpinned branch, or another mutable reference for production deployments.

Before upgrading a module:

1. Read the module README and relevant changelog entries.
2. Review Terraform and AWS provider compatibility.
3. Inspect the complete Terraform plan.
4. Check for resource replacements, policy changes, retention changes, and state-address changes.
5. Test the upgrade in a non-production environment.
6. Apply the change through the consuming repository's approved workflow.

## Repository Structure

```text
platform-iac-modules/
├── docs/
│   ├── README.md
│   ├── index.md
│   ├── module-development.md
│   ├── security-baseline.md
│   ├── versioning.md
│   ├── cross-platform.md
│   └── stylesheets/
├── modules/
│   ├── README.md
│   ├── backend-bootstrap/
│   ├── cloudtrail/
│   ├── github-oidc/
│   ├── guardduty/
│   ├── kms/
│   ├── log-archive-bucket/
│   └── scp/
├── scripts/
├── tooling/
├── tests/
├── .github/
├── .devcontainer/
├── catalog/
├── README.md
├── CONTRIBUTING.md
└── SECURITY.md
```

### Important Directories

| Path | Responsibility |
| --- | --- |
| `modules/` | Reusable Terraform modules |
| `docs/` | Project documentation and documentation-site content |
| `catalog/` | Machine-readable module inventory and metadata |
| `tests/` | Repository-level and cross-platform validation |
| `scripts/` | Bootstrap, CI, and tool-management utilities |
| `tooling/` | Shared validation, Terraform, and security configuration |
| `.github/` | CI workflows, pull-request templates, and automation |
| `.devcontainer/` | Reproducible development-container configuration |

## Local Development

From the repository root, use `task` as the canonical automation interface:

```bash
task --list
task preflight
task fmt:terraform
task validate:terraform
task lint:tflint
task test:terraform
task docs:check
```

For focused work on a single module:

```bash
terraform -chdir=modules/<module-name> init -backend=false
terraform -chdir=modules/<module-name> validate
terraform -chdir=modules/<module-name> test
terraform-docs -c .terraform-docs.yml modules/<module-name>
```

Use the module's `examples/basic` directory when you need to inspect a concrete configuration or plan.

> Examples that create AWS resources may incur charges and require appropriate credentials.
> Review the example and module documentation before applying anything.

## Quality Gates

Changes are expected to pass the repository's applicable quality gates:

- Terraform formatting
- Terraform validation
- TFLint and configured policy checks
- Native Terraform tests
- Security scanning
- Documentation generation and consistency checks
- Pre-commit hooks
- CI workflows
- Integration tests where the module's risk profile requires them

Integration tests must run only against an explicitly approved sandbox or test account. A successful static validation or unit test run is not proof that a module is safe to apply in every AWS account, Region, or organization.

## Security

Security is a core design requirement of this project.

Contributors and consumers should:

- Prefer encryption and private access by default.
- Follow least-privilege IAM design.
- Restrict federated trust policies to exact repositories, branches, tags, or environments where applicable.
- Treat resource policies and Service Control Policies as security-sensitive interfaces.
- Review retention, deletion, replacement, and recovery behavior before deployment.
- Avoid committing credentials, secrets, private keys, or sensitive infrastructure data.
- Validate the complete Terraform plan before applying changes.
- Follow the repository's [Security Policy](../SECURITY.md) for vulnerability reporting and security-related work.

SCPs restrict permissions; they do not grant permissions. Similarly, IAM trust configuration and workload permissions are separate concerns and must be reviewed independently.

## Documentation Standards

Every module README should document:

- Module purpose and supported use cases
- Terraform and provider requirements
- Account, Region, and service prerequisites
- Ownership boundaries
- Security behavior and defaults
- Inputs and outputs
- Basic usage examples
- Cost and operational considerations
- Destructive operations and replacement behavior
- Known limitations and upgrade considerations

Generated Terraform documentation must remain enclosed by the standard markers:

markdown
<!-- BEGIN_TF_DOCS -->

<!-- END_TF_DOCS -->

Documentation changes should be validated with the same discipline as Terraform code.

## Contributing

Please read [`CONTRIBUTING.md`](../CONTRIBUTING.md) before opening an issue or pull request.

Contributions should:

- Keep changes narrowly scoped.
- Preserve module boundaries and provider neutrality.
- Include tests and documentation updates where applicable.
- Follow the repository's formatting and validation workflow.
- Use clear, module-scoped commit messages.
- Explain breaking changes and include migration guidance.
- Call out changes affecting resource addresses, state migration, security defaults, or destructive behavior.

## Versioning

Modules are released independently using Semantic Versioning:

- **Major** — Incompatible interface, resource identity, state-address, removal, or security-default changes.
- **Minor** — Backward-compatible capabilities or inputs.
- **Patch** — Backward-compatible fixes, validation improvements, documentation changes, or dependency maintenance.

Consumers should pin module versions and upgrade deliberately through their live infrastructure repository.

## Support and Ownership

For usage questions, defects, documentation issues, or feature proposals:

1. Review the relevant module README and documentation page.
2. Search existing issues and pull requests.
3. Open a focused issue with reproduction details, Terraform and provider versions, and relevant logs.
4. For security-sensitive matters, follow [`SECURITY.md`](../SECURITY.md) instead of disclosing details publicly.

---

For the project overview, module catalog, architecture expectations, and repository-wide standards, see the [root README](../README.md).

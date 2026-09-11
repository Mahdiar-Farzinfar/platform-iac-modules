# Platform IaC Modules

Reusable Terraform Infrastructure as Code modules for building secure, scalable, and well-governed AWS platform foundations.

This repository is a **module library**. It is intended to provide reusable Terraform building blocks that are consumed from a separate live infrastructure repository where providers, backends, account targeting, environment values, approvals, and deployment orchestration are defined.

> **Important:** Do not run `terraform apply` from the repository root, from `modules/`, or from any shared module directory. Consume released modules from a live infrastructure repository, or use a module’s `examples/basic` directory for isolated development and testing.

---

## Who this is for

This repository is designed for:

- platform engineers building reusable infrastructure foundations,
- security engineers standardizing cloud controls,
- cloud architects defining repeatable AWS patterns,
- and developers who need reliable Terraform modules for platform infrastructure.

The modules are primarily focused on AWS and are designed to be composed into larger infrastructure stacks outside this repository.

---

## Core principles

The project is organized around the following principles:

- **Reusable building blocks**  
  Modules should be small, composable, and focused on a clear infrastructure capability.

- **Well-defined interfaces**  
  Inputs, outputs, defaults, assumptions, and limitations should be explicit and documented.

- **Secure and compliant defaults**  
  Modules should prefer secure defaults, least privilege, encryption where applicable, and reviewable behavior.

- **Cross-platform contributor experience**  
  Contributors should be able to work consistently across Linux, macOS, Windows, and containerized development environments.

- **Versioned consumption**  
  Production consumers should pin immutable, module-scoped release references instead of using mutable branches.

- **Automation-first quality**  
  Formatting, validation, linting, documentation checks, tests, and security scanning are part of the normal development workflow.

---

## Repository layout

The repository is organized into predictable top-level areas:

| Path | Purpose |
| --- | --- |
| `modules/` | Reusable Terraform modules. |
| `docs/` | Documentation site content. |
| `scripts/` | Bootstrap, validation, and helper scripts. |
| `tooling/` | Shared tool configuration and version pins. |
| `.github/workflows/` | CI, release, documentation, validation, and security workflows. |
| `.devcontainer/` | Containerized development environment configuration. |
| `.vscode/` | VS Code settings and extension recommendations. |
| `Taskfile.yml` | Canonical task automation entry point. |

Use the documentation and task definitions together: documentation explains the expected workflow, while tasks provide the repeatable commands used locally and in CI.

---

## Module catalog

The `modules/` directory contains reusable Terraform building blocks for AWS platform foundations.

Available modules include:

| Module | Purpose |
| --- | --- |
| `backend-bootstrap` | Bootstrap resources commonly needed for Terraform backend setup. |
| `cloudtrail` | AWS CloudTrail foundation logging capability. |
| `github-oidc` | GitHub Actions OIDC integration for AWS access. |
| `guardduty` | Amazon GuardDuty security monitoring foundation. |
| `kms` | AWS KMS key management building block. |
| `log-archive-bucket` | Centralized log archive S3 bucket capability. |
| `scp` | AWS Organizations Service Control Policy support. |

The README inside each module is the authoritative source for that module’s exact inputs, outputs, prerequisites, defaults, security behavior, operational limitations, and example usage.

---

## Standard module structure

Each module generally follows this layout:

```text
modules/<module-name>/
├── README.md
├── main.tf
├── variables.tf
├── outputs.tf
├── versions.tf
├── locals.tf
├── examples/
│   └── basic/
│       └── main.tf
└── tests/
```

A module README should document:

- purpose,
- intended use cases,
- inputs,
- outputs,
- usage examples,
- dependencies,
- assumptions,
- security considerations,
- limitations,
- and upgrade notes where relevant.

---

## How to consume a module

Modules should be consumed from a separate Terraform root module, live infrastructure repository, or orchestration layer such as Terragrunt.

Use immutable, module-scoped release references for production deployments.

Example:

```hcl
module "cloudtrail" {
  source = "git::https://github.com/Mahdiar-Farzinfar/platform-iac-modules.git//modules/cloudtrail?ref=cloudtrail/v1.2.0"

  # Configure required module inputs here.
}
```

Production consumers should:

- pin a released version,
- review the target module README before applying,
- define providers and backends outside the reusable module,
- manage environment-specific values in the live infrastructure repository,
- review plans before apply,
- and upgrade intentionally.

Do not use `main`, an unpinned branch, or another mutable reference for production deployments.

---

## What this repository is not

This repository is not a live infrastructure environment.

It should not contain:

- environment-specific Terraform root deployments,
- production state,
- backend state files,
- account-specific secrets,
- or deployment approvals for live environments.

Those concerns belong in the consuming infrastructure repository.

Reusable modules in this repository should remain provider-neutral and backend-neutral at the module boundary unless a module’s documented purpose explicitly requires otherwise.

---

## Quick start for contributors

Clone the repository:

```bash
git clone https://github.com/Mahdiar-Farzinfar/platform-iac-modules.git
cd platform-iac-modules
```

Bootstrap your local environment.

Linux/macOS:

```bash
./scripts/bootstrap/setup.sh
```

Windows:

```powershell
./scripts/bootstrap/setup.ps1
```

Verify the toolchain:

```bash
python scripts/tools/verify-toolchain.py
```

Install Git hooks:

```bash
pre-commit install
```

Inspect available automation tasks:

```bash
task --list
```

Run the local CI-equivalent validation flow:

```bash
task ci
```

Run `task ci` before opening a pull request whenever practical.

---

## Local module development workflow

A typical module change should follow this flow:

1. Create or update a module under `modules/<module-name>/`.
2. Implement Terraform logic in `main.tf`, `variables.tf`, `outputs.tf`, and supporting files.
3. Add or update examples under `examples/basic/`.
4. Add or update tests under `tests/`.
5. Regenerate or refresh documentation where required.
6. Run formatting, validation, linting, tests, documentation checks, and security checks.
7. Open a pull request with a clear scope and release impact.

For focused development, use module-specific commands where appropriate, for example:

```bash
terraform -chdir=modules/<module-name>/examples/basic init
terraform -chdir=modules/<module-name>/examples/basic validate
```

Prefer repository tasks for standard validation because they represent the expected project workflow.

---

## Definition of done

A module change is ready for review when the relevant checks have passed and the documentation reflects the behavior of the code.

At minimum, verify:

- Terraform formatting,
- Terraform validation,
- TFLint or configured Terraform linting,
- security scanning where applicable,
- Terraform tests,
- documentation generation or documentation checks,
- updated examples,
- updated module README,
- and clear release impact.

If the change affects module behavior, document the impact clearly in the pull request.

---

## Module design contract

Reusable modules should follow a consistent contract:

- keep provider configuration outside the module unless explicitly documented,
- keep backend configuration outside the module,
- expose explicit inputs and outputs,
- avoid hidden environment assumptions,
- use secure defaults,
- support composition with other modules,
- preserve stable resource identity where possible,
- and document operational limitations.

When adding a new module or changing an existing one, keep the scope intentionally small. A module should represent one clear capability rather than an entire environment.

---

## Versioning and upgrades

Modules are released independently and should follow Semantic Versioning expectations:

- **Major** versions are for incompatible changes, resource identity changes, removals, or security-default changes that require explicit migration.
- **Minor** versions are for backward-compatible capabilities or new optional inputs.
- **Patch** versions are for compatible fixes, validation improvements, documentation updates, and maintenance changes.

Before upgrading a module in a consuming repository:

1. Read the module README.
2. Review the changelog or release notes.
3. Compare input and output changes.
4. Run `terraform plan`.
5. Review any resource replacement or destructive behavior.
6. Apply only after the plan is understood and approved.

---

## Security expectations

Security is a first-class concern for this repository.

Contributors and consumers should:

- never commit secrets,
- protect Terraform state and plan artifacts,
- use least-privilege AWS roles,
- prefer encryption at rest where supported,
- review IAM and SCP changes carefully,
- review destructive plans before apply,
- and treat generated reports or scan outputs as sensitive when they contain infrastructure details.

Security-related defaults and limitations should be documented in the relevant module README.

---

## Documentation expectations

Documentation should stay close to the module behavior.

When a public interface changes, update the corresponding documentation in the same change set. This includes:

- module README files,
- usage examples,
- input and output descriptions,
- assumptions and limitations,
- security considerations,
- and upgrade notes.

The module README is the authoritative reference for module-specific usage. The documentation site provides shared guidance, conventions, and navigation.

---

## Recommended reading

Start here, then continue based on your role.

For module consumers:

1. Review this overview.
2. Open the target module README under `modules/<module-name>/README.md`.
3. Review the module’s `examples/basic` usage.
4. Pin a released module version in your live infrastructure repository.
5. Run and review `terraform plan` before applying.

For contributors:

1. Review the repository README.
2. Review the module README you are changing.
3. Follow the standard module structure.
4. Run the repository task workflow.
5. Keep code, examples, tests, and documentation in sync.

Useful entry points:

- `README.md`
- `modules/README.md`
- `docs/module-development.md`
- `docs/cross-platform.md`
- `docs/versioning.md`
- `docs/security-baseline.md`

---

## Safe usage checklist

Before using a module in a live environment, confirm that:

- you are consuming from a separate live infrastructure repository,
- the module source is pinned to an immutable release reference,
- providers and backends are configured outside the reusable module,
- required inputs are explicit,
- the module README has been reviewed,
- the plan has been reviewed,
- security-sensitive changes have been approved,
- and no Terraform apply is being run from this repository root or from `modules/`.

---

## Summary

`platform-iac-modules` is a reusable Terraform module library for AWS platform foundations.

Use it as a source of versioned, composable infrastructure modules. Keep live deployment concerns in a separate repository, pin module versions for production, follow the documented validation workflow, and treat each module README as the authoritative source for module-specific behavior.

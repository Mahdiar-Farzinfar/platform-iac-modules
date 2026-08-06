# Security Policy

## Supported Versions

This repository does not use a single repository-wide version.

Releases are versioned independently per release domain using domain-scoped Git tags.

| Release Domain | Tag Format | Supported Versions |
| ---------------- | ------------ | -------------------- |
| Repository/root files | `root/vX.Y.Z` | Latest release only |
| Terraform modules | `module/<module-name>/vX.Y.Z` | Latest release of each module only |
| Devcontainer image | `image/devcontainer/vX.Y.Z` | Latest release only |

Security fixes are provided for the latest released version of the affected release domain.

For example:

- A vulnerability in `modules/kms` is handled against the latest `module/kms/vX.Y.Z` release.
- A vulnerability in `modules/cloudtrail` is handled against the latest `module/cloudtrail/vX.Y.Z` release.
- A vulnerability in repository-level tooling, CI/CD, documentation, or shared configuration is handled against the latest `root/vX.Y.Z` release.
- A vulnerability in the development container is handled against the latest `image/devcontainer/vX.Y.Z` release.

Older releases are not guaranteed to receive security patches unless explicitly stated by the maintainers.

### Pre-1.0 Releases

Pre-1.0 releases may include breaking changes and are considered unstable from an API compatibility perspective.

However, the latest released version of each release domain remains eligible for security fixes, regardless of whether it is `0.x` or `1.x+`.

## Reporting a Vulnerability

**Do not open a public GitHub issue for security vulnerabilities.**

Please report suspected security vulnerabilities privately using
[GitHub's private vulnerability reporting](../../security/advisories/new).
This helps ensure that security issues are disclosed responsibly and can be
reviewed before any public discussion.

### Please include

- Description of the vulnerability
- Affected module(s) under `modules/`
- Steps to reproduce
- Potential impact
- Suggested fix (optional)

You will receive an acknowledgement according to the targets defined in the
[Severity Classification and SLA](#severity-classification-and-sla) section.
A preliminary resolution timeline will be provided after initial triage.

### PGP Key

For sensitive vulnerability reports, use the following OpenPGP public key to encrypt the report details:

-----BEGIN PGP PUBLIC KEY BLOCK-----

mDMEamMUPxYJKwYBBAHaRw8BAQdAgAcdLy/M0GLL3EHbP5EPGwNXl8UgSIztERBU
r2mwGmG0Lk1haGRpYXIgRmFzemluZmFyIDxtYWhkaWFyZmFyemluZmFyQGdtYWls
LmNvbT6IrwQTFgoAVxYhBKt6PCFgiSj2GbU2yPUCg16p8oKCBQJqYxQ/GxSAAAAA
AAQADm1hbnUyLDIuNSsxLjEyLDIsMQIbAwULCQgHAgIiAgYVCgkICwIEFgIDAQIe
BwIXgAAKCRD1AoNeqfKCggomAP9D4OArxt89hc7uZ8a7kmF0v9MEwJPstT1aFZUw
YyVuCQEAkJPzixGf46QfDpnXMug2+39ch5sozX/XTZQn0wD2WAQ=
=uhO9  
-----END PGP PUBLIC KEY BLOCK-----

Key fingerprint:

AB7A 3C21 6089 28F6 19B5 36C8 F502 835E A9F2 8282

Please verify the fingerprint through an independent channel before using the key to encrypt highly sensitive information.

## Severity Classification and SLA

Security vulnerabilities are classified using the Common Vulnerability Scoring
System (CVSS) v3.1. The final severity may also consider exploitability,
affected release domains, exposure, required privileges, and practical impact.

| Severity | CVSS v3.1 Score | Initial Acknowledgement Target | Remediation Target |
| --- | --- | --- | --- |
| Critical | 9.0–10.0 | Within 24 hours | Within 7 days |
| High | 7.0–8.9 | Within 48 hours | Within 30 days |
| Medium | 4.0–6.9 | Within 5 business days | Within 60 days |
| Low | 0.1–3.9 | Within 7 business days | Within 90 days |
| Informational | 0.0 | Within 7 business days | No mandatory SLA |

The timelines above are operational targets and are not contractual guarantees.
Remediation timelines may vary depending on the complexity of the issue,
upstream dependencies, release coordination, and the affected release domain.

A report may be reclassified after validation if additional technical context changes the practical severity or impact.

## Bug Bounty Policy

This project does not operate a paid bug bounty program.

Responsible security research is accepted under a Coordinated Vulnerability Disclosure process. No financial compensation, reward, or other consideration is offered or guaranteed for vulnerability reports.

Researchers who submit reports in good faith and follow this policy should:

- Avoid accessing, modifying, deleting, or exfiltrating data that does not belong to them
- Avoid actions that could degrade the availability or performance of the repository or its services
- Avoid social engineering, phishing, spam, denial-of-service testing, and physical attacks
- Minimize interaction with systems, accounts, and data that are not required to demonstrate the vulnerability
- Stop testing and notify the maintainer if sensitive data is encountered
- Delete any sensitive data obtained unintentionally and confirm its deletion when requested
- Allow a reasonable period for investigation and remediation before public disclosure

Reports that involve prohibited activities, intentional harm, privacy
violations, or unlawful conduct may not qualify for safe-harbor treatment.

## Security Baseline

This repository provides reusable Terraform modules for composing secure
infrastructure. It is a module source repository and does not provision or
operate production infrastructure.

The repository does not run `terraform apply` against real cloud
environments. Therefore, the presence of a module in this repository does not,
by itself, mean that the corresponding security control is enabled in a
consumer environment.

The baseline documented in
[`docs/security-baseline.md`](docs/security-baseline.md) defines the security
properties, implementation expectations, and recommended controls that modules
should support or enforce when they are used by a consuming configuration.

Depending on the module and its configuration, the repository provides building
blocks for controls such as:

- **Encryption at rest** — KMS-backed encryption through the `kms` module
- **Audit logging** — CloudTrail configuration through the `cloudtrail` module
- **Threat detection** — GuardDuty configuration through the `guardduty` module
- **Centralized log archiving** — S3-based audit log storage through the `log-archive-bucket` module
- **Keyless CI/CD authentication** — GitHub OIDC integration through the `github-oidc` module
- **Preventive organization guardrails** — Service Control Policies through the `scp` module
- **Least-privilege IAM** — narrowly scoped IAM policies and permissions within the supported module implementations

Actual security posture depends on the consuming Terraform configuration,
provider settings, variable values, account and organization architecture, deployment process, and operational controls.

Consumers are responsible for:

- Selecting and composing the appropriate modules
- Supplying secure and production-appropriate configuration
- Running Terraform plan and apply through their own controlled workflow
- Verifying that the resulting resources satisfy their security and compliance requirements
- Monitoring, operating, and maintaining the deployed infrastructure
- Managing cloud accounts, organizational policies, credentials, and runtime incident response

## Automated Security Scanning

The `.github/workflows/security-scan.yml` workflow runs on every pull request and includes:

- [Checkov](https://www.checkov.io/) — IaC static analysis (config: `tooling/.checkov.yml`)
- [Trivy](https://trivy.dev/) — vulnerability and misconfiguration scanning (ignore list: `tooling/.trivyignore`)
- [tflint](https://github.com/terraform-linters/tflint) — Terraform linting (config: `tooling/.tflint.hcl`)

Findings must be resolved or explicitly suppressed with justification before merge.

## Secrets Management

- **No secrets, credentials, or access keys** may be committed to this repository
- Use OIDC-based authentication for CI/CD (see `modules/github-oidc/`)
- Rotate any accidentally committed credentials immediately and treat them as compromised
- Pre-commit hooks (`.pre-commit-config.yaml`) include secret detection; ensure they are installed locally

## Dependency Management

Dependencies are monitored and update pull requests are created by Renovate using [`.github/renovate.json`](.github/renovate.json).

All dependency updates, including security patches, are reviewed and merged manually by the maintainer after the required validation and automated checks have passed. Automatic merging is not enabled.

Terraform provider and module version constraints are defined in each module's `versions.tf` and are updated through the same review process.

## Disclosure Policy

This project follows [Coordinated Vulnerability Disclosure (CVD)](https://cheatsheetseries.owasp.org/cheatsheets/Vulnerability_Disclosure_Cheat_Sheet.html). Public disclosure occurs after a fix is available or after 90 days, whichever comes first.

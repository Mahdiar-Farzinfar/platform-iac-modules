# GitHub Actions OIDC Federation for AWS

Terraform module that configures passwordless federation from GitHub Actions
to AWS. It creates or reuses the account-level GitHub Actions OpenID Connect
(OIDC) provider and creates repository-scoped IAM roles that workflows assume
with short-lived credentials.

The module grants no workload permissions by default. Callers must attach only
the managed or inline policies required by each workflow.

## What It Creates

| Component | Purpose |
| --- | --- |
| IAM OIDC provider *(optional)* | Registers `https://token.actions.githubusercontent.com` in the target AWS account |
| IAM roles | Provides one role for each entry in `roles`, using stable caller-defined map keys |
| Role trust policies | Exact-matches audiences and GitHub subjects; wildcard subjects require an explicit repository-scoped opt-in |
| Managed policy attachments *(optional)* | Attaches caller-supplied IAM managed policies to each role |
| Inline role policies *(optional)* | Adds caller-supplied, workload-specific JSON policies to each role |

This module does not create GitHub repositories, environments, workflows,
secrets, variables, or environment protection rules.

## Prerequisites and Ownership

- Configure the AWS provider for the account that will own the OIDC provider
  and IAM roles.
- Create the GitHub OIDC provider only once per AWS account. A centralized
  identity stack should normally own it; other stacks should set
  `create_oidc_provider = false` and pass its ARN.
- Grant the Terraform execution identity the IAM permissions needed to manage
  OIDC providers, roles, trust policies, and any configured policy
  attachments.
- Give the GitHub Actions job `id-token: write` permission. No long-lived AWS
  access keys are required.
- Configure GitHub environment protection rules before trusting an environment
  subject for sensitive deployments.

Production consumers should pin an immutable module-scoped release tag rather
than a branch or mutable reference.

## Usage

The recommended configuration trusts an exact protected-environment subject:

```hcl
module "github_oidc" {
  source = "git::https://github.com/Mahdiar-Farzinfar/platform-iac-modules.git//modules/github-oidc?ref=module/github-oidc/vX.Y.Z"

  role_path = "/github-actions/"

  roles = {
    production = {
      name        = "github-production-deploy"
      description = "Deploys the production application from GitHub Actions."

      subjects = [
        "repo:acme/payments-api:environment:production",
      ]

      # Add only the workload permissions this workflow requires.
      managed_policy_arns = [
        "arn:aws:iam::123456789012:policy/github-production-deploy",
      ]

      tags = {
        Environment = "production"
        Owner       = "platform-team"
      }
    }
  }

  tags = {
    CostCenter = "platform"
  }
}
```

Replace `vX.Y.Z`, the account ID, repository identity, role name, and policy
ARN with values owned by the consuming live-infrastructure repository. See
[`examples/basic`](./examples/basic) for a runnable local example.

### Reuse an Existing OIDC Provider

```hcl
module "github_oidc" {
  source = "git::https://github.com/Mahdiar-Farzinfar/platform-iac-modules.git//modules/github-oidc?ref=module/github-oidc/vX.Y.Z"

  create_oidc_provider = false
  oidc_provider_arn    = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"

  roles = {
    production = {
      subjects = [
        "repo:acme/payments-api:environment:production",
      ]
    }
  }
}
```

When `create_oidc_provider` is `false`, `oidc_provider_arn` is required if any
roles are configured. Disabling provider creation with an empty `roles` map is
a valid no-op.

## GitHub Actions Configuration

The workflow job must request an OIDC token and use a subject that exactly
matches the role trust policy. Store the role ARN as a GitHub configuration
variable; it is an identifier, not a secret.

```yaml
permissions:
  contents: read
  id-token: write

jobs:
  deploy:
    environment: production
    runs-on: ubuntu-latest

    steps:
      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@<full-commit-sha>
        with:
          role-to-assume: ${{ vars.AWS_DEPLOY_ROLE_ARN }}
          aws-region: us-east-1
          role-session-name: github-${{ github.run_id }}
```

Replace `<full-commit-sha>` with a reviewed commit for the approved action
version and keep it updated with dependency automation.

## Subject Claims and Trust Boundaries

Use `subjects` whenever the complete GitHub `sub` claim is known. Exact
subjects use IAM `StringEquals` and are the secure default.

| Workflow context | Example subject |
| --- | --- |
| Protected environment *(recommended for deployments)* | `repo:acme/payments-api:environment:production` |
| Branch | `repo:acme/payments-api:ref:refs/heads/main` |
| Tag | `repo:acme/payments-api:ref:refs/tags/v1.2.3` |
| Pull request | `repo:acme/payments-api:pull_request` |
| Immutable organization and repository IDs | `repo:acme@123456/payments-api@789012:environment:production` |

If the GitHub organization uses a customized OIDC subject template, supply the
exact resulting claim value.

Use `subject_patterns` only when a bounded wildcard is required. Patterns use
IAM `StringLike`, must contain `*` or `?`, and must retain an exact owner and
repository prefix:

```hcl
roles = {
  release = {
    subject_patterns = [
      "repo:acme/payments-api:ref:refs/tags/release-*",
    ]
  }
}
```

Wildcards in the owner or repository portion are rejected. When both
`subjects` and `subject_patterns` are configured, the module emits separate
trust-policy statements; a token may match either statement.

## Role Configuration

Each `roles` map key is a stable Terraform resource identity and becomes the
IAM role name when `name` is omitted.

| Attribute | Behavior |
| --- | --- |
| `name` | Optional IAM role name; defaults to the map key |
| `description` | Defaults to `Assumed by GitHub Actions using OpenID Connect.` |
| `subjects` | Exact OIDC subject claims matched with `StringEquals` |
| `subject_patterns` | Explicit wildcard claims matched with `StringLike` |
| `max_session_duration` | Role session ceiling in seconds; defaults to `3600` |
| `permissions_boundary_arn` | Optional IAM permissions boundary |
| `managed_policy_arns` | Up to 20 caller-supplied managed policy ARNs |
| `inline_policies` | Up to 10 named JSON policies, with an aggregate normalized size limit of 10,240 characters |
| `tags` | Role-specific tags merged over common tags; the module-controlled `Name` tag wins |

Changing a map key changes the Terraform resource address and can cause
replacement. Keep keys stable even when a human-readable role name changes.

## Security Considerations

- Prefer protected GitHub environments and exact subjects for deployment
  roles. Reserve wildcard patterns for narrowly bounded cases such as a
  repository's release tags.
- Keep `audiences` minimal. The default is `sts.amazonaws.com`; every
  configured role trusts every audience supplied to the module.
- Attach least-privilege policies. This module validates policy shape and IAM
  limits but cannot determine whether permissions are appropriate.
- Use separate roles for workloads with different trust contexts or
  permissions instead of combining unrelated repositories or environments.
- Review the Terraform plan whenever subjects, audiences, attached policies,
  permissions boundaries, or role names change.
- Protect the Terraform state because it records trust configuration and
  inline policy documents.

The provider intentionally omits certificate thumbprints. AWS provider
`>= 5.81.0` relies on AWS IAM's trusted certificate authority library, avoiding
plan-time TLS lookups and certificate-rotation drift.

## Tagging

The OIDC provider receives the caller's common tags plus these
module-controlled values:

```text
Name      = github-actions-oidc
ManagedBy = terraform
Module    = github-oidc
Component = ci-cd-identity
```

IAM roles receive the common tags, then role-specific tags, followed by a
module-controlled `Name` tag containing the effective role name.

<!-- markdownlint-disable MD012 -->
<!-- BEGIN_TF_DOCS -->


## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.6.0 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | >= 5.81.0 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | 6.65.0 |



## Resources

| Name | Type |
|------|------|
| [aws_iam_openid_connect_provider.github](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_openid_connect_provider) | resource |
| [aws_iam_role.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.inline](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy_attachment.managed](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_audiences"></a> [audiences](#input\_audiences) | OIDC audiences trusted by the provider and IAM roles. Use sts.amazonaws.com for standard AWS partitions or the audience required by the target partition. | `set(string)` | <pre>[<br>  "sts.amazonaws.com"<br>]</pre> | no |
| <a name="input_create_oidc_provider"></a> [create\_oidc\_provider](#input\_create\_oidc\_provider) | Whether to create the account-level GitHub Actions OIDC provider. | `bool` | `true` | no |
| <a name="input_oidc_provider_arn"></a> [oidc\_provider\_arn](#input\_oidc\_provider\_arn) | ARN of an existing GitHub Actions OIDC provider. Required when create\_oidc\_provider is false and roles are configured. | `string` | `null` | no |
| <a name="input_role_path"></a> [role\_path](#input\_role\_path) | IAM path applied to every role created by this module. | `string` | `"/"` | no |
| <a name="input_roles"></a> [roles](#input\_roles) | IAM roles trusted by GitHub Actions, keyed by stable Terraform identifiers.<br>The map key becomes the IAM role name when name is omitted.<br><br>subjects contains exact OIDC `sub` claim values. Exact subjects cannot<br>contain IAM wildcard characters, but may use GitHub's standard, immutable,<br>or customized subject formats.<br><br>subject\_patterns is an explicit opt-in to StringLike matching. Every<br>pattern must remain scoped to an exact owner and repository using:<br>  repo:<owner>/<repository>:<pattern><br><br>Examples:<br>  repo:octo-org/octo-repo:ref:refs/heads/main<br>  repo:octo-org/octo-repo:environment:production<br>  repo:octo-org@123456/octo-repo@456789:ref:refs/heads/main<br>  repo:octo-org/octo-repo:ref:refs/tags/release-*<br><br>managed\_policy\_arns and inline\_policies define the role's permissions.<br>Callers remain responsible for granting least privilege. | <pre>map(object({<br>    name                     = optional(string)<br>    description              = optional(string, "Assumed by GitHub Actions using OpenID Connect.")<br>    subjects                 = optional(set(string), [])<br>    subject_patterns         = optional(set(string), [])<br>    max_session_duration     = optional(number, 3600)<br>    permissions_boundary_arn = optional(string)<br>    managed_policy_arns      = optional(set(string), [])<br>    inline_policies          = optional(map(string), {})<br>    tags                     = optional(map(string), {})<br>  }))</pre> | `{}` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags applied to the GitHub OIDC provider and all IAM roles. Role-specific tags are merged on top; module-managed Name tags take precedence. | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_oidc_provider_arn"></a> [oidc\_provider\_arn](#output\_oidc\_provider\_arn) | ARN of the GitHub Actions OIDC provider created by this module or supplied by the caller; null when neither is configured. |
| <a name="output_oidc_provider_url"></a> [oidc\_provider\_url](#output\_oidc\_provider\_url) | Issuer URL of the GitHub Actions OIDC provider. |
| <a name="output_role_arns"></a> [role\_arns](#output\_role\_arns) | IAM role ARNs keyed by the corresponding roles map key; use these values with GitHub Actions role-to-assume. |
| <a name="output_role_names"></a> [role\_names](#output\_role\_names) | IAM role names keyed by the corresponding roles map key. |

<!-- END_TF_DOCS -->
<!-- markdownlint-enable MD012 -->

## Operational Notes

- IAM OIDC providers and roles are account-global even though the AWS provider
  requires a region.
- `role_path` applies to every role in a module instance. Use separate module
  instances if roles require different paths or ownership boundaries.
- Managed and inline policies are optional. A role with no attached policies
  can authenticate but has no workload permissions.
- The module does not configure GitHub's organization-level OIDC subject
  template. Trust values must match the claims GitHub actually emits.
- Import or otherwise establish a single Terraform owner before bringing an
  existing GitHub OIDC provider under management.

## Testing

Native Terraform tests use a mocked AWS provider, require Terraform `>= 1.7`,
and do not create AWS resources:

```bash
terraform init -backend=false
terraform test
```

From the repository root, use the canonical workflows:

```bash
task docs
task docs:check
task test:terraform
```

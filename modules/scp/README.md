# AWS Organizations Service Control Policy

Terraform module that creates one AWS Organizations Service Control Policy
(SCP) and attaches it to one or more organization targets: the organization
root, organizational units (OUs), or AWS accounts.

The module is intended for organization-wide guardrails and centralized
governance baselines. It renders structured IAM-style statements to JSON or
accepts a caller-supplied JSON document, validates the resolved document, and
manages one attachment per target.

SCPs define the maximum permissions available to principals in affected
accounts; they do not grant permissions. A policy attached to the organization
root can affect every account and OU, so review the rendered document and
target list as production governance changes.

## What It Creates

| Component | Creation behavior | Purpose |
| --- | --- | --- |
| Service Control Policy | Created when `create = true` | Stores the resolved SCP document in AWS Organizations |
| Policy attachments | One per unique value in `target_ids` | Applies the SCP to a root, OU, or account |

This module does not create or manage the AWS Organization, roots, OUs,
accounts, account enrollment, delegated administration, IAM principals,
permissions policies, an AWS provider, or a Terraform backend.

## Prerequisites and Ownership

- Terraform `>= 1.5` and AWS provider `>= 5.0, < 6.0`.
- An AWS provider configured for the AWS Organizations management account.
  SCPs are organization-level resources and are normally created from the
  management account; the provider Region is still required by the AWS
  provider configuration.
- AWS Organizations with the `ALL` feature set enabled. SCPs are not available
  when the organization uses the `CONSOLIDATED_BILLING` feature set.
- An execution identity with permissions to describe the organization and
  create, attach, detach, update, and (when applicable) delete Organizations
  policies.
- A clear Terraform owner for the policy and each attachment. Import an
  existing SCP before managing it here instead of creating a second owner.
- Valid target identifiers:
  `r-*` organization root IDs, `ou-*` organizational unit IDs, or 12-digit
  AWS account IDs.

Production consumers should pin an immutable module-scoped release tag rather
than a branch or mutable reference.

## Usage

The structured interface is convenient when statements are maintained as HCL.
This example resolves the organization root ID instead of hard-coding it:

```hcl
data "aws_organizations_organization" "this" {}

module "baseline_guardrails" {
  source = "git::https://github.com/Mahdiar-Farzinfar/platform-iac-modules.git//modules/scp?ref=module/scp/vX.Y.Z"

  name        = "baseline-guardrails"
  description = "Organization-wide guardrails for the security baseline."

  statements = [
    {
      sid       = "DenyLeaveOrganization"
      effect    = "Deny"
      actions   = ["organizations:LeaveOrganization"]
      resources = ["*"]
    },
    {
      sid    = "DenyDisableCloudTrail"
      effect = "Deny"
      actions = [
        "cloudtrail:StopLogging",
        "cloudtrail:DeleteTrail",
        "cloudtrail:UpdateTrail",
      ]
      resources = ["*"]
    },
  ]

  target_ids = [data.aws_organizations_organization.this.roots[0].id]

  tags = {
    Environment = "all"
    Owner       = "platform-security"
  }
}
```

Replace `vX.Y.Z`, the target IDs, and tags with values owned by the consuming
live-infrastructure repository. See [`examples/basic`](./examples/basic) for a
runnable example.

### Supply a raw JSON document

Use `policy_content` when the policy is generated elsewhere or must be kept as
an exact JSON artifact:

```hcl
module "region_guardrail" {
  source = "git::https://github.com/Mahdiar-Farzinfar/platform-iac-modules.git//modules/scp?ref=module/scp/vX.Y.Z"

  name = "deny-unapproved-regions"

  policy_content = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyOutsideApprovedRegions"
        Effect    = "Deny"
        NotAction = ["iam:*", "organizations:*"]
        Resource  = "*"
        Condition = {
          StringNotEquals = {
            "aws:RequestedRegion" = ["us-east-1", "us-west-2"]
          }
        }
      }
    ]
  })

  target_ids = ["ou-ab12-12345678"]
}
```

`policy_content` and `statements` are mutually exclusive. When
`create = true`, provide exactly one non-empty policy source. The module uses
raw JSON as supplied; otherwise it renders `statements` with
`Version = "2012-10-17"`.

## Policy and Attachment Behavior

### Policy sources

Structured statements have the following shape:

| Attribute | Required | Behavior |
| --- | :---: | --- |
| `sid` | No | Optional statement identifier |
| `effect` | Yes | Must be `Allow` or `Deny` |
| `actions` | Yes | Must contain at least one action |
| `resources` | Yes | Must contain at least one resource |
| `condition` | No | Optional `map(map(list(string)))` condition map |

The final JSON document must be valid and no longer than 5,120 characters,
which is the AWS Organizations SCP limit. The module checks both conditions
before Terraform submits the policy to AWS.

### Targets

`target_ids` accepts roots, OUs, and accounts. Attachments are keyed by target
ID with `for_each`, so adding or removing one target produces a focused plan
without re-attaching unrelated targets. Duplicate IDs are collapsed
automatically. An empty list creates the SCP without any attachments.

Changing a policy's targets changes where its restrictions apply. Treat root
and OU attachments as high-impact governance changes and review the complete
Terraform plan before approval.

### Disable and retention modes

Set `create = false` to create no policy or attachments. Resource-derived scalar
outputs (`id`, `arn`, `name`, and `aws_managed`) become `null`, while
attachment collections become empty; the resolved `policy_content` output
remains available for configuration inspection.

Set `skip_destroy = true` when the SCP must outlive this Terraform state. On
destroy, Terraform removes the attachments from management and retains the
policy in AWS; it is then the caller's responsibility to track, detach, and
delete the retained policy when it is no longer needed. Keep the default
`false` for ordinary module-owned policies.

## Security and Operational Considerations

- Review every SCP with the affected account and platform owners. A `Deny`
  statement can block recovery, billing, security, or deployment operations
  across all attached accounts.
- Start with a narrow OU or test-account attachment before targeting the
  organization root. Validate break-glass access and required AWS service
  behavior before widening the target set.
- Remember that SCPs do not grant access. Each account still needs IAM
  identity and resource policies, and an SCP can only further restrict the
  permissions those policies would otherwise allow.
- Keep policy statements explicit and small. The 5,120-character limit applies
  to the final JSON string, including whitespace and all conditions.
- Protect Terraform state and plan artifacts. The `policy_content` output
  exposes the complete governance document and may contain sensitive
  organizational constraints.
- Keep module-managed ownership tags intact for inventory and policy
  ownership:

  ```text
  ManagedBy = terraform
  Module    = scp
  ```

  These keys take precedence over caller-supplied values with the same names.

- AWS Organizations policy changes and attachments can affect multiple
  accounts and may incur operational or support costs if they interrupt
  workloads. Use change management and an explicit rollback plan.

## Limitations

The module intentionally does not manage organization structure, account
provisioning, policy version history, IAM permissions, delegated
administrators, or SCP testing in a live organization. Build those concerns in
dedicated stacks and connect them with the outputs below.

<!-- markdownlint-disable MD012 -->
<!-- BEGIN_TF_DOCS -->


## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.5 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | >= 5.0, < 6.0 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | 5.100.0 |



## Resources

| Name | Type |
|------|------|
| [aws_organizations_policy.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/organizations_policy) | resource |
| [aws_organizations_policy_attachment.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/organizations_policy_attachment) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_name"></a> [name](#input\_name) | Name of the Service Control Policy. Must be unique within the organization. | `string` | n/a | yes |
| <a name="input_create"></a> [create](#input\_create) | Controls whether the SCP and its attachments are created. When false, the<br>module manages no resources while preserving the caller's configuration. | `bool` | `true` | no |
| <a name="input_description"></a> [description](#input\_description) | Human-readable description of the SCP's purpose. | `string` | `"Managed by Terraform"` | no |
| <a name="input_policy_content"></a> [policy\_content](#input\_policy\_content) | Raw JSON policy document for the SCP. Mutually exclusive with<br>var.statements. When set, it is used verbatim as the policy content.<br>Leave null to render the document from var.statements instead. | `string` | `null` | no |
| <a name="input_skip_destroy"></a> [skip\_destroy](#input\_skip\_destroy) | When true, the SCP is retained in AWS after the resource is removed from<br>Terraform state. Useful for shared baseline SCPs whose lifecycle extends<br>beyond a single module or state boundary. | `bool` | `false` | no |
| <a name="input_statements"></a> [statements](#input\_statements) | Structured policy statements rendered to a JSON document by locals.tf.<br>Mutually exclusive with var.policy\_content. Each statement follows the IAM<br>policy statement shape; sid and condition are optional. | <pre>list(object({<br>    sid       = optional(string)<br>    effect    = string<br>    actions   = list(string)<br>    resources = list(string)<br>    condition = optional(map(map(list(string))), {})<br>  }))</pre> | `[]` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags applied to the SCP. Merged with module-managed tags (ManagedBy,<br>Module), which take precedence on key collisions. | `map(string)` | `{}` | no |
| <a name="input_target_ids"></a> [target\_ids](#input\_target\_ids) | Organization targets the SCP is attached to. Accepts organization root IDs<br>(r-*), organizational unit IDs (ou-*), and 12-digit AWS account IDs.<br>Duplicate values are de-duplicated by the attachment resource. | `list(string)` | `[]` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_arn"></a> [arn](#output\_arn) | The Amazon Resource Name (ARN) of the Service Control Policy, or null when create = false. |
| <a name="output_attachments"></a> [attachments](#output\_attachments) | Map of target ID to attachment details for each SCP attachment, keyed by<br>the same stable target ID used in main.tf. Empty when create = false. |
| <a name="output_aws_managed"></a> [aws\_managed](#output\_aws\_managed) | Whether the SCP is an AWS-managed policy. Always false for module-created policies, or null when create = false. |
| <a name="output_id"></a> [id](#output\_id) | The unique identifier (ID) of the Service Control Policy, or null when create = false. |
| <a name="output_name"></a> [name](#output\_name) | The name of the Service Control Policy, or null when create = false. |
| <a name="output_policy_content"></a> [policy\_content](#output\_policy\_content) | The resolved policy document (JSON) that was submitted to AWS Organizations,<br>whether provided as raw JSON via var.policy\_content or rendered from<br>var.statements. Exposed to support debugging and downstream composition. |
| <a name="output_target_ids"></a> [target\_ids](#output\_target\_ids) | The set of organization target IDs (roots, OUs, or accounts) the SCP is attached to. Empty when create = false or no targets are configured. |

<!-- END_TF_DOCS -->
<!-- markdownlint-enable MD012 -->

## Testing

Native Terraform tests use a mocked AWS provider and exercise rendering,
attachment fan-out, tag merging, disabled-mode outputs, validation failures,
and the SCP size precondition without creating AWS resources:

```bash
terraform -chdir=modules/scp init -backend=false
terraform -chdir=modules/scp test
```

The integration suite creates real AWS Organizations resources in a live
management account. It is skipped unless `TEST_ORG_ROOT_ID` and
`AWS_DEFAULT_REGION` are set, and it can affect organization governance:

```bash
go test -v -timeout 30m ./modules/scp/tests/...
```

Optional integration targets are supplied with `TEST_OU_ID` and
`TEST_ACCOUNT_ID`. Review the test implementation and use a disposable
organization or dedicated test targets.

Regenerate and validate the embedded Terraform API documentation with the
repository's pinned toolchain:

```bash
terraform-docs -c .terraform-docs.yml modules/scp
task docs:check
```

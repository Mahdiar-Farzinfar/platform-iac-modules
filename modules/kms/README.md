# AWS KMS Key

Terraform module that provisions one customer-managed AWS KMS key, its key
policy, optional aliases, and optional grants. A module instance creates either
a primary key or a multi-Region replica key.

The defaults favor a general-purpose symmetric encryption key: the key is
enabled, automatic rotation is enabled, the policy lockout safety check remains
enabled, and deletion uses a 30-day waiting period.

## What It Creates

| Component | Behavior |
| --- | --- |
| Primary KMS key | Created when `create = true` and `create_replica = false` |
| Multi-Region replica key | Created instead of a primary key when `create_replica = true` |
| Key policy | Composes root-account recovery, administration, usage, service-grant, and caller-supplied statements |
| KMS aliases | Creates each value in `aliases` and normalizes bare names to `alias/<name>` |
| KMS grants | Creates each entry in `grants` using stable caller-defined map keys |

This module does not create IAM principals or identity policies, configure an
AWS provider or Terraform backend, or attach aliases and grants to an existing
key. Setting `create = false` creates no KMS resources.

## Prerequisites

- Configure the AWS provider for the account and Region that will own the key.
- Ensure every IAM principal referenced by the key policy or a grant already
  exists.
- Grant the Terraform execution identity permission to create and manage the
  requested KMS resources and policy.
- Use one clear Terraform owner for each key. Import an existing key before
  managing it with this module instead of creating a second owner.
- Pin production consumers to an immutable, module-scoped release tag.

## Usage

```hcl
module "kms" {
  source = "git::https://github.com/Mahdiar-Farzinfar/platform-iac-modules.git//modules/kms?ref=module/kms/vX.Y.Z"

  description = "Encrypts production data for the payments service."
  aliases     = ["alias/payments-production"]

  key_administrators = [
    "arn:aws:iam::123456789012:role/platform-kms-administrator",
  ]

  key_users = [
    "arn:aws:iam::123456789012:role/payments-production",
  ]

  tags = {
    Environment = "production"
    Owner       = "platform-team"
    CostCenter  = "payments"
  }
}
```

Replace the release tag, account ID, principal ARNs, alias, and tags with
values owned by the consuming infrastructure repository. See
[`examples/basic`](./examples/basic) for a runnable local example.

## Key Policy Model

The module builds the key policy in layers:

| Input or statement | Access granted |
| --- | --- |
| `EnableRootAccountAccess` | Adds the current account root principal as the policy safety net and enables account IAM policies to delegate KMS access |
| `key_administrators` | Key-management permissions; administration does not imply cryptographic use |
| `key_users` | Encrypt, decrypt, re-encrypt, data-key generation, and key-description permissions |
| `key_service_users` | Grant-management permissions constrained by `kms:GrantIsForAWSResource` for integrated AWS services |
| `source_policy_documents` | Additional policy documents merged into the base policy |
| `override_policy_documents` | Final policy overrides applied after all other documents |

Use unique, non-empty statement SIDs in caller-supplied policy documents.
Treat the module SIDs `EnableRootAccountAccess`, `KeyAdministration`,
`KeyUsage`, and `KeyServiceUsage` as reserved unless replacing one is
intentional. An override with a matching SID can replace a safety or access
statement, so review the rendered `key_policy` output and Terraform plan
carefully.

Prefer the structured principal inputs for common same-account access. Use
`source_policy_documents` for service principals, cross-account access,
`kms:ViaService` restrictions, encryption-context conditions, or other policy
requirements that the structured inputs do not represent. Cross-account
access also requires appropriate identity permissions in the external
account.

The `key_users` statement is intentionally encryption-oriented and does not
change when `key_usage` changes. For `SIGN_VERIFY`, `GENERATE_VERIFY_MAC`, or
`KEY_AGREEMENT` keys, add a least-privilege source policy document containing
the required signing, MAC, public-key, or key-agreement actions.

## Multi-Region Keys

Create the primary and each replica as separate module instances using AWS
provider configurations for their respective Regions:

```hcl
provider "aws" {
  region = "us-east-1"
}

provider "aws" {
  alias  = "replica"
  region = "us-west-2"
}

module "kms_primary" {
  source = "git::https://github.com/Mahdiar-Farzinfar/platform-iac-modules.git//modules/kms?ref=module/kms/vX.Y.Z"

  description  = "Multi-Region key for the payments service."
  multi_region = true
  aliases      = ["alias/payments"]
}

module "kms_replica" {
  source = "git::https://github.com/Mahdiar-Farzinfar/platform-iac-modules.git//modules/kms?ref=module/kms/vX.Y.Z"

  providers = {
    aws = aws.replica
  }

  create_replica  = true
  primary_key_arn = module.kms_primary.key_arn
  aliases         = ["alias/payments"]
}
```

`primary_key_arn` must identify a multi-Region primary key. Policy, aliases,
grants, enabled state, deletion settings, and tags are managed independently
for each module instance. Primary-key-only inputs such as `key_spec`,
`key_usage`, `enable_key_rotation`, `rotation_period_in_days`, and
`multi_region` do not configure a replica resource.

## Aliases and Grants

Aliases may be supplied as either `alias/name` or `name`; the latter is
normalized to `alias/name`. The exact input value is also the Terraform
resource key and the key in the `aliases` output. Choose one representation
and keep it stable to avoid unnecessary resource address changes.

Define grants with stable map keys. When a grant's `name` is omitted, its map
key becomes the AWS grant name. A grant may use
`encryption_context_equals` or `encryption_context_subset`, but not both.
Grant tokens are exported as a sensitive output for workloads that must use a
new grant before eventual consistency has propagated.

## Security Considerations

- Keep `bypass_policy_lockout_safety_check = false`. Enabling it can permit a
  policy that makes the key unmanageable.
- Grant administrators and cryptographic users separately. Add the same
  principal to both lists only when it genuinely needs both capabilities.
- Use least-privilege grants and policy conditions. Avoid broad principals,
  unconstrained service access, and unnecessary `kms:*` permissions.
- Automatic rotation defaults to enabled. Set
  `enable_key_rotation = false` deliberately for asymmetric or HMAC keys for
  which this module's rotation setting is not valid.
- The module validates allowed `key_spec` and `key_usage` values separately;
  callers must select a compatible pair for the intended cryptographic
  operation.
- Protect Terraform state. It contains the rendered key policy and may contain
  sensitive grant tokens; Terraform's `sensitive` flag hides display but does
  not encrypt state.
- Review destroy plans carefully. Destroying the key schedules deletion after
  `deletion_window_in_days`, while dependent aliases are removed as part of
  the same operation.
- Changing immutable key characteristics can require replacement. Treat
  changes to `key_spec`, `key_usage`, and `multi_region` as migrations and
  inspect the plan before approval.

## Tagging

The key receives the module tag `terraform-module = "kms"` plus the caller's
`tags`. Caller-supplied tags win on key collision. Put organization-wide tags
such as environment, owner, and cost center in the AWS provider's
`default_tags` when they should apply to every supported resource.

KMS aliases and grants are not tagged by this module.

<!-- markdownlint-disable MD012 -->
<!-- BEGIN_TF_DOCS -->


## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.3.0 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | >= 5.0 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | >= 5.0 |



## Resources

| Name | Type |
|------|------|
| [aws_kms_alias.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_alias) | resource |
| [aws_kms_grant.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_grant) | resource |
| [aws_kms_key.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_key) | resource |
| [aws_kms_replica_key.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_replica_key) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_aliases"></a> [aliases](#input\_aliases) | List of aliases to create for the key. Accepts either "alias/name" or bare "name"; names must not begin with "aws/" (reserved for AWS managed keys). | `list(string)` | `[]` | no |
| <a name="input_bypass_policy_lockout_safety_check"></a> [bypass\_policy\_lockout\_safety\_check](#input\_bypass\_policy\_lockout\_safety\_check) | Whether to bypass the key policy lockout safety check. Leave false unless you fully understand the risk of locking the key. | `bool` | `false` | no |
| <a name="input_create"></a> [create](#input\_create) | Whether to create any resources in this module. Set to false to disable the module entirely (useful in conditional wrappers). | `bool` | `true` | no |
| <a name="input_create_replica"></a> [create\_replica](#input\_create\_replica) | Whether to create a multi-Region replica key (aws\_kms\_replica\_key) instead of a primary key. Requires primary\_key\_arn. | `bool` | `false` | no |
| <a name="input_deletion_window_in_days"></a> [deletion\_window\_in\_days](#input\_deletion\_window\_in\_days) | Waiting period (7–30 days) before the key is deleted after destruction is requested. | `number` | `30` | no |
| <a name="input_description"></a> [description](#input\_description) | Description of the key, shown in the AWS console and API responses. | `string` | `null` | no |
| <a name="input_enable_key_rotation"></a> [enable\_key\_rotation](#input\_enable\_key\_rotation) | Whether automatic annual key rotation is enabled. Only valid for symmetric keys; disable deliberately if using asymmetric/HMAC keys. | `bool` | `true` | no |
| <a name="input_grants"></a> [grants](#input\_grants) | Map of KMS grants to create, keyed by a stable identifier (used as the grant<br>name when name is not set). Example:<br><br>  grants = {<br>    ebs = {<br>      grantee\_principal = "arn:aws:iam::111122223333:role/service-role"<br>      operations        = ["Encrypt", "Decrypt", "DescribeKey"]<br>      constraints = {<br>        encryption\_context\_equals = { Department = "Finance" }<br>      }<br>    }<br>  } | <pre>map(object({<br>    name                  = optional(string)<br>    grantee_principal     = string<br>    operations            = list(string)<br>    retiring_principal    = optional(string)<br>    grant_creation_tokens = optional(list(string))<br>    retire_on_delete      = optional(bool, false)<br>    constraints = optional(object({<br>      encryption_context_equals = optional(map(string))<br>      encryption_context_subset = optional(map(string))<br>    }))<br>  }))</pre> | `{}` | no |
| <a name="input_is_enabled"></a> [is\_enabled](#input\_is\_enabled) | Whether the key is enabled for use. | `bool` | `true` | no |
| <a name="input_key_administrators"></a> [key\_administrators](#input\_key\_administrators) | List of IAM principal ARNs granted key administration permissions (manage, not use). | `list(string)` | `[]` | no |
| <a name="input_key_service_users"></a> [key\_service\_users](#input\_key\_service\_users) | List of IAM principal ARNs allowed to create grants for AWS service integration (constrained by kms:GrantIsForAWSResource). | `list(string)` | `[]` | no |
| <a name="input_key_spec"></a> [key\_spec](#input\_key\_spec) | Key spec (customer\_master\_key\_spec). Determines the key material type and supported algorithms. | `string` | `"SYMMETRIC_DEFAULT"` | no |
| <a name="input_key_usage"></a> [key\_usage](#input\_key\_usage) | Intended use of the key. One of: ENCRYPT\_DECRYPT, SIGN\_VERIFY, GENERATE\_VERIFY\_MAC, KEY\_AGREEMENT. | `string` | `"ENCRYPT_DECRYPT"` | no |
| <a name="input_key_users"></a> [key\_users](#input\_key\_users) | List of IAM principal ARNs granted cryptographic usage permissions (Encrypt, Decrypt, GenerateDataKey, ...). | `list(string)` | `[]` | no |
| <a name="input_multi_region"></a> [multi\_region](#input\_multi\_region) | Whether to create a multi-Region primary key. Cannot be changed after creation. | `bool` | `false` | no |
| <a name="input_override_policy_documents"></a> [override\_policy\_documents](#input\_override\_policy\_documents) | List of IAM policy documents (JSON) that override the merged policy. Applied after source\_policy\_documents; later documents win on SID conflict. | `list(string)` | `[]` | no |
| <a name="input_primary_key_arn"></a> [primary\_key\_arn](#input\_primary\_key\_arn) | ARN of the multi-Region primary key to replicate. Required when create\_replica is true. | `string` | `null` | no |
| <a name="input_rotation_period_in_days"></a> [rotation\_period\_in\_days](#input\_rotation\_period\_in\_days) | Custom rotation period in days (90–2560). Only used when enable\_key\_rotation is true. Null uses the AWS default (365). | `number` | `null` | no |
| <a name="input_source_policy_documents"></a> [source\_policy\_documents](#input\_source\_policy\_documents) | List of IAM policy documents (JSON) merged into the key policy. Statements with non-blank SIDs override module statements with the same SID. | `list(string)` | `[]` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Map of tags applied to all resources created by this module (merged with provider default\_tags via locals). | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_aliases"></a> [aliases](#output\_aliases) | Map of aliases created, keyed by the input alias value. Each entry exposes<br>`arn` and `name` (normalized to the `alias/...` form). |
| <a name="output_grant_tokens"></a> [grant\_tokens](#output\_grant\_tokens) | Map of grant tokens, keyed by the input grant key. A grant token allows a<br>grantee to use the grant immediately, before eventual consistency has<br>propagated. Marked sensitive because a token temporarily conveys the<br>permissions of its grant to whoever holds it. |
| <a name="output_grants"></a> [grants](#output\_grants) | Map of grants created, keyed by the input grant key. Each entry exposes the grant `id` (unique per key) and `key_id`. |
| <a name="output_key_arn"></a> [key\_arn](#output\_key\_arn) | ARN of the KMS key (primary or replica). `null` when `create = false`. |
| <a name="output_key_id"></a> [key\_id](#output\_key\_id) | Globally unique identifier of the KMS key. `null` when `create = false`. |
| <a name="output_key_policy"></a> [key\_policy](#output\_key\_policy) | Rendered JSON key policy attached to the key. `null` when `create = false`. |

<!-- END_TF_DOCS -->
<!-- markdownlint-enable MD012 -->

## Operational Notes

- `create = false` leaves `key_arn`, `key_id`, and `key_policy` as `null` and
  returns empty alias and grant maps.
- `rotation_period_in_days = null` uses the AWS default rotation period when
  rotation is enabled; an explicit value must be between 90 and 2560 days.
- Alias names must be unique per account and Region and cannot use the
  AWS-reserved `aws/` prefix.
- Caller-provided tags override the module's identifying tag on collision.
- Some accepted key specifications require an AWS provider release newer than
  the module's minimum `>= 5.0` constraint. Ensure the selected provider
  version supports the chosen `key_spec`.
- Customer-managed KMS keys and KMS API requests may incur AWS charges.

## Testing

Run the mocked native Terraform tests without creating AWS resources:

```bash
terraform -chdir=modules/kms init -backend=false
terraform -chdir=modules/kms test
```

The integration test creates billable AWS resources and schedules the test key
for deletion during teardown:

```bash
cd modules/kms/tests
go test -tags integration -timeout 45m -run TestKMSBasicExample -v
```

Regenerate the embedded requirements, providers, resources, inputs, and
outputs with the repository documentation workflow:

```bash
task docs
```

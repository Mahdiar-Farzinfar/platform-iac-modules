# Log Archive Bucket

Terraform module that provisions a hardened Amazon S3 bucket for centralized,
long-term log retention. It is suitable for sources such as AWS CloudTrail,
VPC Flow Logs, and load-balancer access logs when those services are configured
separately to deliver into the bucket.

The module owns the bucket's storage, encryption, lifecycle, access-control,
and transport-security settings. It does not configure the log-producing AWS
services, create a KMS key, create an access-log destination bucket, or
configure an AWS provider or Terraform backend.

## What It Creates

| Component | Purpose |
| --- | --- |
| S3 bucket | Stores archived log objects under a caller-selected, globally unique name |
| Ownership controls | Enforces `BucketOwnerEnforced` object ownership and disables ACL-based ownership |
| Public access block | Enables all four S3 public-access-block settings |
| Versioning | Keeps object versions enabled for recovery and Object Lock compatibility |
| Server-side encryption | Uses SSE-S3 (`AES256`) by default, or SSE-KMS when `kms_key_arn` is supplied |
| Lifecycle configuration | Transitions objects through `STANDARD_IA`, `GLACIER`, and `DEEP_ARCHIVE`; expires noncurrent versions and aborts incomplete multipart uploads |
| Bucket policy | Denies every non-TLS request and optionally grants `s3:PutObject` to listed log-delivery service principals |
| Object Lock *(optional)* | Applies a default WORM retention mode and period when enabled at creation |
| Server access logging *(optional)* | Sends this bucket's S3 access logs to a separate bucket |

## Prerequisites

- Terraform `>= 1.5.0, < 2.0.0` and AWS provider `>= 5.0.0, < 7.0.0`.
- An AWS provider configuration for the account and Region that will own the
  bucket. Reusable modules should configure the provider in the caller.
- An execution identity with permission to manage the S3 resources, bucket
  policy, and (when used) the referenced KMS key configuration.
- A bucket name that satisfies S3 naming rules and is globally unique. Use a
  deterministic name in production so the bucket can be located and owned
  unambiguously.
- When `kms_key_arn` is set, an existing customer-managed KMS key that S3 can
  use in the bucket's Region. This module does not create or manage that key's
  policy.
- When `access_log_bucket` is set, an existing, separate destination bucket
  configured to receive S3 server access logs. The destination cannot be this
  bucket.
- When log producers are enabled, the producer services must also be
  configured to write to this bucket. The module's generic delivery statement
  does not create CloudTrail, VPC Flow Logs, or load-balancer configuration.

## Usage

Pin production consumers to an immutable module release. Replace the release
reference, bucket name, account-specific values, and tags with values owned by
the consuming infrastructure repository.

```hcl
module "log_archive" {
  source = "git::https://github.com/Mahdiar-Farzinfar/platform-iac-modules.git//modules/log-archive-bucket?ref=module/log-archive-bucket/vX.Y.Z"

  bucket_name = "acme-production-log-archive-123456789012"

  # Add only the services that are configured to deliver logs here.
  log_delivery_service_principals = [
    "cloudtrail.amazonaws.com",
    "delivery.logs.amazonaws.com",
  ]

  tags = {
    Environment = "production"
    Owner       = "platform-team"
    CostCenter  = "security"
  }
}
```

For local development, a checkout can use
`source = "./modules/log-archive-bucket"`. See
[`examples/basic`](./examples/basic) for a runnable example; it deliberately
uses a random suffix and `force_destroy = true`, so it is not a production
retention configuration.

## Security Defaults

The module is intentionally restrictive by default:

| Control | Default behavior |
| --- | --- |
| Encryption | SSE-S3 (`AES256`); supplying `kms_key_arn` selects SSE-KMS and enables the S3 Bucket Key |
| Transport | Bucket policy denies all requests where `aws:SecureTransport` is `false` |
| Public access | All four S3 public access block settings are `true` |
| Object ownership | `BucketOwnerEnforced`; ACLs are not used |
| Versioning | Always enabled |
| Destruction | `force_destroy = false`, so non-empty buckets cannot be removed accidentally |
| Log-delivery writes | No service principals are allowed unless explicitly listed |
| Provenance tags | `ManagedBy = terraform`, `TerraformModule = log-archive-bucket`, and `DataClassification = log-archive` |

Caller-supplied tags are merged over the module tags, so a caller can
intentionally override a default key.

## Encryption

Leave `kms_key_arn` as `null` for SSE-S3, or provide a customer-managed KMS
key ARN to use SSE-KMS. With SSE-KMS, the module enables the S3 Bucket Key to
reduce KMS request volume. The KMS key is not created by this module; ensure
its key policy and grants allow the S3 bucket and the configured log-delivery
path to use the required encryption operations.

Changing encryption settings can affect existing objects differently from new
objects. Plan and test the change with the retention requirements for the
workload, and verify the effective encryption with the
`encryption_algorithm` and `kms_key_arn` outputs.

## Lifecycle and Object Lock

The default lifecycle rule applies to the whole bucket and transitions current
objects at 30 days (`STANDARD_IA`), 90 days (`GLACIER`), and 365 days
(`DEEP_ARCHIVE`). Noncurrent versions expire after 90 days, and incomplete
multipart uploads are aborted after seven days. Set `lifecycle_prefix` to
scope the rule to a key prefix, and set `expiration_days` only when eventual
deletion is intentional.

Keep custom transition thresholds in chronological order and choose
`expiration_days` after the final transition. The module validates AWS minimum
floors, but callers remain responsible for avoiding a transition or expiration
schedule that is operationally or financially unsuitable.

Object Lock is disabled by default. If enabled, it must be selected when the
bucket is first created and cannot subsequently be enabled or disabled. Use
`GOVERNANCE` when an authorized administrator may need to bypass retention;
use `COMPLIANCE` only when the stronger, non-bypassable WORM guarantee is
required. Retention can prevent deletion even when Terraform or a lifecycle
rule would otherwise remove an object.

## Log Delivery and Access Logging

`log_delivery_service_principals` adds an account-scoped
`s3:PutObject` allow statement for the listed AWS service principals. An empty
list omits that statement, and the statement is not restricted to a particular
object-key prefix. The module does not add service-specific prefixes,
`GetBucketAcl` permissions, source-ARN conditions, or producer resources;
review the delivery requirements for each AWS service and add or manage any
additional controls required by that service.

`access_log_bucket` enables S3 server access logging with a module-generated
prefix (`s3-access/<bucket-name>/`). The destination bucket is external to this
module and must be prepared according to AWS S3 server-access-logging
requirements.

## Operational Considerations

- Review every destroy plan. Keep `force_destroy = false` for audit data and
  use an explicit retention/decommissioning process before removing a bucket.
- Treat enabling Object Lock, changing its mode, and changing the bucket name
  as lifecycle decisions that may require replacement or migration. Confirm
  the plan before approval.
- Protect Terraform state and the KMS key policy. State records the bucket
  policy, names, ARNs, and retention-related configuration.
- S3 storage, request, lifecycle-transition, retrieval, and KMS charges depend
  on log volume and retention. Validate the tiering schedule against recovery
  objectives and expected access patterns.

<!-- markdownlint-disable MD012 -->
<!-- BEGIN_TF_DOCS -->


## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.5.0, < 2.0.0 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | >= 5.0.0, < 7.0.0 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | >= 5.0.0, < 7.0.0 |



## Resources

| Name | Type |
|------|------|
| [aws_s3_bucket.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket) | resource |
| [aws_s3_bucket_lifecycle_configuration.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_lifecycle_configuration) | resource |
| [aws_s3_bucket_logging.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_logging) | resource |
| [aws_s3_bucket_notification.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_notification) | resource |
| [aws_s3_bucket_object_lock_configuration.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_object_lock_configuration) | resource |
| [aws_s3_bucket_ownership_controls.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_ownership_controls) | resource |
| [aws_s3_bucket_policy.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_policy) | resource |
| [aws_s3_bucket_public_access_block.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_public_access_block) | resource |
| [aws_s3_bucket_server_side_encryption_configuration.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_server_side_encryption_configuration) | resource |
| [aws_s3_bucket_versioning.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_versioning) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_bucket_name"></a> [bucket\_name](#input\_bucket\_name) | Base name of the log archive bucket. Must satisfy S3 naming rules (3-63 chars, lowercase letters, digits, hyphens, dots). | `string` | n/a | yes |
| <a name="input_access_log_bucket"></a> [access\_log\_bucket](#input\_access\_log\_bucket) | Name of a separate bucket to receive S3 server access logs for this bucket. Null disables access logging. Must not be this bucket itself (recursive logging). | `string` | `null` | no |
| <a name="input_expiration_days"></a> [expiration\_days](#input\_expiration\_days) | Days after which current object versions expire. Null disables expiration (retain indefinitely). When set, must exceed the last transition to avoid paying early-deletion fees. | `number` | `null` | no |
| <a name="input_force_destroy"></a> [force\_destroy](#input\_force\_destroy) | Allow Terraform to delete the bucket even when it contains objects. Keep false for audit/log buckets; enable only in ephemeral environments. | `bool` | `false` | no |
| <a name="input_kms_key_arn"></a> [kms\_key\_arn](#input\_kms\_key\_arn) | ARN of a customer-managed KMS key for SSE-KMS. When null, SSE-S3 (AES256) is used and Bucket Keys are disabled. | `string` | `null` | no |
| <a name="input_lifecycle_prefix"></a> [lifecycle\_prefix](#input\_lifecycle\_prefix) | Object key prefix the lifecycle rule applies to. Empty string applies the rule to the whole bucket. | `string` | `""` | no |
| <a name="input_log_delivery_service_principals"></a> [log\_delivery\_service\_principals](#input\_log\_delivery\_service\_principals) | AWS service principals granted s3:PutObject via bucket policy, scoped to this account (e.g. ["cloudtrail.amazonaws.com", "delivery.logs.amazonaws.com"]). Empty list omits the statement. | `list(string)` | `[]` | no |
| <a name="input_noncurrent_version_expiration_days"></a> [noncurrent\_version\_expiration\_days](#input\_noncurrent\_version\_expiration\_days) | Days after which noncurrent (overwritten/deleted) object versions are permanently removed. | `number` | `90` | no |
| <a name="input_object_lock_enabled"></a> [object\_lock\_enabled](#input\_object\_lock\_enabled) | Enable S3 Object Lock (WORM). Must be decided at bucket creation; it cannot be enabled or disabled afterwards. | `bool` | `false` | no |
| <a name="input_object_lock_mode"></a> [object\_lock\_mode](#input\_object\_lock\_mode) | Default Object Lock retention mode. GOVERNANCE allows privileged bypass; COMPLIANCE cannot be overridden by anyone, including the root user. | `string` | `"GOVERNANCE"` | no |
| <a name="input_object_lock_retention_days"></a> [object\_lock\_retention\_days](#input\_object\_lock\_retention\_days) | Default retention period (days) applied to new objects when Object Lock is enabled. | `number` | `365` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags applied to all resources created by this module (merged with module defaults in locals.tf). | `map(string)` | `{}` | no |
| <a name="input_transition_to_deep_archive_days"></a> [transition\_to\_deep\_archive\_days](#input\_transition\_to\_deep\_archive\_days) | Days after object creation before transition to DEEP\_ARCHIVE. Must be greater than transition\_to\_glacier\_days. | `number` | `365` | no |
| <a name="input_transition_to_glacier_days"></a> [transition\_to\_glacier\_days](#input\_transition\_to\_glacier\_days) | Days after object creation before transition to GLACIER. Must be greater than transition\_to\_ia\_days (recommended: +30 or more). | `number` | `90` | no |
| <a name="input_transition_to_ia_days"></a> [transition\_to\_ia\_days](#input\_transition\_to\_ia\_days) | Days after object creation before transition to STANDARD\_IA. AWS requires a minimum of 30 days. | `number` | `30` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_bucket_arn"></a> [bucket\_arn](#output\_bucket\_arn) | ARN of the S3 bucket. Use this to grant IAM permissions. |
| <a name="output_bucket_domain_name"></a> [bucket\_domain\_name](#output\_bucket\_domain\_name) | Bucket-regional domain name (path-style). Suitable for CloudFront origins. |
| <a name="output_bucket_id"></a> [bucket\_id](#output\_bucket\_id) | The name (ID) of the S3 bucket. |
| <a name="output_bucket_region"></a> [bucket\_region](#output\_bucket\_region) | AWS region the bucket was created in. |
| <a name="output_encryption_algorithm"></a> [encryption\_algorithm](#output\_encryption\_algorithm) | SSE algorithm in use: 'aws:kms' when a KMS key is supplied, otherwise 'AES256'. |
| <a name="output_kms_key_arn"></a> [kms\_key\_arn](#output\_kms\_key\_arn) | ARN of the KMS key used for SSE-KMS encryption. Null when AES256 is used. |
| <a name="output_object_lock_enabled"></a> [object\_lock\_enabled](#output\_object\_lock\_enabled) | Whether S3 Object Lock (WORM) is active on this bucket. |
| <a name="output_tags"></a> [tags](#output\_tags) | Effective tag map applied to the bucket (module defaults merged with caller tags). |
| <a name="output_versioning_status"></a> [versioning\_status](#output\_versioning\_status) | Current versioning state of the bucket (always 'Enabled' for this module). |

<!-- END_TF_DOCS -->
<!-- markdownlint-enable MD012 -->

## Testing

The native Terraform tests use a mocked AWS provider and run plan-only
assertions, so they do not create AWS resources. The test suite requires
Terraform `>= 1.7.0` because mocked providers are a test-only feature:

```bash
terraform -chdir=modules/log-archive-bucket init -backend=false
terraform -chdir=modules/log-archive-bucket test
```

The basic example can create billable AWS resources. Review its configuration
before applying it:

```bash
terraform -chdir=modules/log-archive-bucket/examples/basic init
terraform -chdir=modules/log-archive-bucket/examples/basic plan
```

Regenerate and verify the embedded Terraform reference documentation with the
repository workflow:

```bash
task docs
task docs:check
```

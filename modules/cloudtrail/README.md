# AWS CloudTrail

Terraform module that provisions one AWS CloudTrail trail with secure,
account-level defaults. It can create and manage the trail's S3 destination,
a dedicated customer-managed KMS key, and a CloudWatch Logs destination, or
integrate the trail with caller-owned storage and encryption.

By default, the module creates a multi-Region trail that includes global
service events, validates delivered log files, encrypts logs with a rotating
KMS key, stores them in a private versioned S3 bucket, and streams events to
CloudWatch Logs.

This module creates a standard account trail. It does not create an AWS
Organizations trail, CloudTrail Lake event data store, SNS topic, CloudWatch
metric filters or alarms, S3 Object Lock configuration, an AWS provider, or a
Terraform backend.

## What It Creates

| Component | Creation behavior | Purpose |
| --- | --- | --- |
| CloudTrail trail | Always | Records the selected management, data, network-activity, and Insight events |
| KMS key and alias | Created when `create_kms_key = true` (default) | Encrypts CloudTrail log files, the managed S3 bucket, and the managed CloudWatch log group |
| S3 bucket and supporting configuration | Created when `create_s3_bucket = true` (default) | Stores log files with versioning, encryption, public-access blocking, lifecycle management, and a CloudTrail-specific bucket policy |
| CloudWatch log group | Created when `enable_cloudwatch_logs = true` (default) | Makes events available for near-real-time monitoring and alerting |
| CloudWatch Logs IAM role and inline policy | Always | Allows CloudTrail to publish events when CloudWatch Logs delivery is enabled |

The module also reads the current AWS account, Region, and partition to build
resource names, ARNs, and policies.

## Prerequisites

- Terraform `>= 1.3.0` and AWS provider `>= 5.0.0, < 6.0.0`.
- An AWS provider configured by the calling root module for the account and
  home Region that will own the trail.
- An execution identity allowed to manage CloudTrail, S3, KMS, CloudWatch
  Logs, and IAM resources, plus read the current AWS identity and partition.
- Globally unique, policy-compliant names for any explicitly named S3 bucket.
- When using an existing bucket or KMS key, resource policies that permit the
  CloudTrail and CloudWatch Logs integration described below.
- An immutable, module-scoped release tag for production consumers.

Before creating another trail, review the account's existing account and
organization trails. Duplicated management-event logging can increase cost
and make audit ownership unclear.

## Usage

Pin production consumers to an immutable module release and use a stable,
lowercase, hyphenated trail name that is also safe for the derived S3 bucket,
KMS alias, IAM role, and CloudWatch log group names.

```hcl
module "cloudtrail" {
  source = "git::https://github.com/Mahdiar-Farzinfar/platform-iac-modules.git//modules/cloudtrail?ref=module/cloudtrail/vX.Y.Z"

  # Both inputs are required by the current module interface.
  name       = "acme-production-audit"
  trail_name = "acme-production-audit"

  # Optional: set an explicit globally unique name instead of using the
  # generated <trail-name>-<account-id>-<region> value.
  s3_bucket_name = "acme-production-cloudtrail-123456789012-us-east-1"

  tags = {
    Environment = "production"
    Owner       = "security-platform"
    CostCenter  = "security"
  }
}
```

Replace the release tag, account ID, Region, names, retention periods, and
tags with values owned by the consuming infrastructure repository. For local
development, a checkout can use `source = "./modules/cloudtrail"`.

See [`examples/basic`](./examples/basic) for a runnable example. That example
sets `s3_force_destroy = true` and shortens the KMS deletion window so it can
be torn down easily; do not copy those two settings into production.

## Security Defaults

| Control | Default behavior |
| --- | --- |
| Trail scope | Multi-Region with global service events included |
| Trail status | Logging enabled |
| Log integrity | CloudTrail log file validation is always enabled |
| KMS encryption | Dedicated customer-managed key with automatic rotation and a 30-day deletion window |
| S3 encryption | SSE-KMS with an S3 Bucket Key when a KMS key is configured; otherwise SSE-S3 (`AES256`) |
| S3 public access | All four public-access-block controls enabled |
| S3 transport | Bucket policy denies requests made without secure transport |
| S3 recoverability | Versioning enabled |
| S3 retention | Current objects transition to `STANDARD_IA` after 30 days, to `GLACIER` after 90 days, and expire after 365 days; noncurrent versions expire after 90 days |
| Destruction | `s3_force_destroy = false`, so Terraform cannot delete a non-empty managed bucket |
| CloudWatch Logs | Enabled with 365-day retention and KMS encryption when a KMS key is configured |

These defaults are a baseline, not a substitute for workload-specific
security and compliance review. In particular, the default 365-day expiration
period may be shorter than the required audit retention period.

## Naming and Tags

The current implementation derives resource names and module-managed tags from
`trail_name`. The `name` input is also required and validated by the public
interface; set it to the same stable value as `trail_name` to keep naming
intent unambiguous.

When `s3_bucket_name` is omitted, the managed bucket name is:

```text
<lowercase-trail-name>-<account-id>-<region>
```

Because the same trail name also becomes part of an S3 bucket name, KMS alias,
IAM role name, and CloudWatch log group name, prefer a short lowercase value
containing only letters, digits, and hyphens. Although the variable accepts
underscores and periods, those characters are not valid in every derived
resource name. Keep the derived bucket name within S3's 63-character limit or
provide an explicit `s3_bucket_name`.

The default CloudWatch log group is `/aws/cloudtrail/<trail-name>`. The module
merges caller tags with the following module-controlled values, which take
precedence on collision:

```text
Name      = <trail-name>
Module    = cloudtrail
ManagedBy = terraform
```

## Managed and Existing Resources

### S3 Destination

With `create_s3_bucket = true`, the module owns the bucket, versioning,
encryption, public access block, lifecycle configuration, and bucket policy.
The policy grants CloudTrail `s3:GetBucketAcl` and scoped `s3:PutObject`
access, requires the `bucket-owner-full-control` canned ACL, restricts requests
to the trail ARN, and denies non-TLS access.

With `create_s3_bucket = false`, `s3_bucket_name` is required in practice and
must identify a prepared bucket. The module does not read, modify, or validate
that bucket or its policy. The caller must configure the CloudTrail ACL check
and object-write permissions for the selected prefix, account, and trail ARN,
including any cross-account ownership requirements. Managed-bucket lifecycle,
encryption, public-access, and force-destroy inputs have no effect in this
mode.

### KMS Encryption

With `create_kms_key = true`, the module creates a rotating key and alias and
uses that key for the trail, managed S3 bucket, and managed CloudWatch log
group. A supplied `kms_key_arn` is ignored in this mode.

With `create_kms_key = false`, set `kms_key_arn` to a compatible existing key
ARN or leave it `null`. An existing key policy must authorize CloudTrail and,
when CloudWatch Logs delivery is enabled, the required CloudWatch Logs use in
the trail's home Region. When no KMS key is configured, the managed S3 bucket
uses SSE-S3 and the trail and log group use their AWS-managed encryption
behavior.

The module does not manage an external key's policy, grants, rotation, or
deletion lifecycle.

## Event Selection

`event_selectors` provides basic management and data-event filtering.
`advanced_event_selectors` provides field-based filtering. Configure only one
of these inputs for a trail; AWS does not allow basic and advanced event
selectors to be active together.

The following example records data events only for objects in one S3 bucket:

```hcl
advanced_event_selectors = [
  {
    name = "Production S3 object activity"

    field_selectors = [
      {
        field  = "eventCategory"
        equals = ["Data"]
      },
      {
        field  = "resources.type"
        equals = ["AWS::S3::Object"]
      },
      {
        field       = "resources.ARN"
        starts_with = ["arn:aws:s3:::acme-production-data/"]
      },
    ]
  },
]
```

Leave both selector lists empty only when the AWS default event-selection
behavior is intentional. For compliance-sensitive trails, configure the
desired coverage explicitly and verify the live selectors after deployment.

Data events, network-activity events, and CloudTrail Insights can generate
additional charges and high event volume. Scope selectors narrowly, enable
only the required Insight types, and monitor ingestion and storage costs.

## Retention and Destruction

Choose lifecycle values from the organization's retention and recovery policy,
not only from storage cost targets:

- `s3_transition_to_ia_days` must be at least 30.
- Keep `s3_transition_to_glacier_days` greater than the IA transition.
- Keep `s3_expiration_days` greater than the Glacier transition.
- The managed lifecycle rule permanently expires current log objects at
  `s3_expiration_days` and noncurrent versions after 90 days.
- Disable `s3_lifecycle_enabled` if another control owns retention.

This module does not configure S3 Object Lock or `lifecycle.prevent_destroy`.
If immutable WORM retention is required, use a suitably configured external
bucket and set `create_s3_bucket = false`, or extend the module under a
separately reviewed change.

Keep `s3_force_destroy = false` in persistent environments. Destroying a
module-managed KMS key schedules deletion after
`kms_key_deletion_window`; it does not delete the key immediately. Review
plans carefully when changing the trail name, bucket name, log group name, or
ownership flags because those changes can replace or detach audit resources.

<!-- markdownlint-disable MD012 -->
<!-- BEGIN_TF_DOCS -->


## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.3.0 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | ~> 5.0 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | 5.100.0 |



## Resources

| Name | Type |
|------|------|
| [aws_cloudtrail.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudtrail) | resource |
| [aws_cloudwatch_log_group.cloudtrail](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_iam_role.cloudwatch_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.cloudwatch_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_kms_alias.cloudtrail](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_alias) | resource |
| [aws_kms_key.cloudtrail](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_key) | resource |
| [aws_s3_bucket.cloudtrail](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket) | resource |
| [aws_s3_bucket_lifecycle_configuration.cloudtrail](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_lifecycle_configuration) | resource |
| [aws_s3_bucket_notification.cloudtrail](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_notification) | resource |
| [aws_s3_bucket_policy.cloudtrail](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_policy) | resource |
| [aws_s3_bucket_public_access_block.cloudtrail](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_public_access_block) | resource |
| [aws_s3_bucket_server_side_encryption_configuration.cloudtrail](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_server_side_encryption_configuration) | resource |
| [aws_s3_bucket_versioning.cloudtrail](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_versioning) | resource |
| [aws_sns_topic.cloudtrail](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sns_topic) | resource |
| [aws_sns_topic_policy.cloudtrail](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sns_topic_policy) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_trail_name"></a> [trail\_name](#input\_trail\_name) | Name of the CloudTrail trail. Must be 3-128 characters: letters, digits, hyphens, underscores, or periods. | `string` | n/a | yes |
| <a name="input_advanced_event_selectors"></a> [advanced\_event\_selectors](#input\_advanced\_event\_selectors) | List of advanced event selectors for fine-<br>grained filtering (e.g., filtering on `eventName`, `eventCategory`, `resources.ARN`).<br>    Mutually exclusive with `event_selectors`.<br><br>    Example:<br>      [{<br>        name = "Log S3 Data Events"<br>        field\_selectors = [{<br>          field  = "eventCategory"<br>          equals = ["Data"]<br>        }]<br>      }] | <pre>list(object({<br>    name = string<br>    field_selectors = list(object({<br>      field           = string<br>      equals          = optional(list(string))<br>      not_equals      = optional(list(string))<br>      starts_with     = optional(list(string))<br>      not_starts_with = optional(list(string))<br>      ends_with       = optional(list(string))<br>      not_ends_with   = optional(list(string))<br>    }))<br>  }))</pre> | `[]` | no |
| <a name="input_cloudwatch_log_group_name"></a> [cloudwatch\_log\_group\_name](#input\_cloudwatch\_log\_group\_name) | Custom name for the CloudWatch Log Group. When `null`, a default name is derived in `locals.tf` (e.g. `/aws/cloudtrail/<name>`). | `string` | `null` | no |
| <a name="input_cloudwatch_logs_retention_days"></a> [cloudwatch\_logs\_retention\_days](#input\_cloudwatch\_logs\_retention\_days) | Retention period (in days) for the CloudWatch Log Group. Must be one of the values supported by AWS. | `number` | `365` | no |
| <a name="input_create_kms_key"></a> [create\_kms\_key](#input\_create\_kms\_key) | Whether to create a dedicated KMS customer managed key (CMK) with automatic rotation for encrypting CloudTrail logs. Set to `false` to supply an existing key via `kms_key_arn` or to fall back to SSE-S3 (AES256). | `bool` | `true` | no |
| <a name="input_create_s3_bucket"></a> [create\_s3\_bucket](#input\_create\_s3\_bucket) | Whether to create and manage the S3 log destination bucket (versioning, SSE, public access block, lifecycle, bucket policy). Set to `false` to deliver logs to an existing bucket via `s3_bucket_name`. | `bool` | `true` | no |
| <a name="input_enable_cloudwatch_logs"></a> [enable\_cloudwatch\_logs](#input\_enable\_cloudwatch\_logs) | Whether to stream CloudTrail events to a CloudWatch Log Group for real-time monitoring, metric filters, and alerting. | `bool` | `true` | no |
| <a name="input_enable_logging"></a> [enable\_logging](#input\_enable\_logging) | Whether the trail actively records events. Setting `false` suspends recording without destroying the trail (useful for break-glass scenarios). | `bool` | `true` | no |
| <a name="input_enable_sns_notifications"></a> [enable\_sns\_notifications](#input\_enable\_sns\_notifications) | Whether to create an SNS topic and configure CloudTrail to publish delivery notifications to it. | `bool` | `true` | no |
| <a name="input_event_selectors"></a> [event\_selectors](#input\_event\_selectors) | List of basic event selectors for filtering management and data events.<br>Mutually exclusive with `advanced_event_selectors`.<br><br>Example:<br>  [{<br>    read\_write\_type           = "All"<br>    include\_management\_events = true<br>    data\_resources = [{<br>      type   = "AWS::S3::Object"<br>      values = ["arn:aws:s3"]<br>    }]<br>  }] | <pre>list(object({<br>    read_write_type           = optional(string, "All")<br>    include_management_events = optional(bool, true)<br>    data_resources = optional(list(object({<br>      type   = string<br>      values = list(string)<br>    })), [])<br>  }))</pre> | `[]` | no |
| <a name="input_include_global_service_events"></a> [include\_global\_service\_events](#input\_include\_global\_service\_events) | Whether to include events from global services such as IAM, STS, and CloudFront. | `bool` | `true` | no |
| <a name="input_insight_selectors"></a> [insight\_selectors](#input\_insight\_selectors) | A list of CloudTrail Insight types to enable. Supported values: `ApiCallRateInsight`, `ApiErrorRateInsight`. | `list(string)` | `[]` | no |
| <a name="input_is_multi_region_trail"></a> [is\_multi\_region\_trail](#input\_is\_multi\_region\_trail) | Whether the trail captures events from all AWS regions. Strongly recommended (`true`) per CIS AWS Foundations Benchmark 3.1. | `bool` | `true` | no |
| <a name="input_kms_key_arn"></a> [kms\_key\_arn](#input\_kms\_key\_arn) | ARN of an existing KMS key to use when `create_kms_key = false`. Leave `null` to use SSE-S3 (AES256) for the bucket and no CMK for the trail. | `string` | `null` | no |
| <a name="input_kms_key_deletion_window"></a> [kms\_key\_deletion\_window](#input\_kms\_key\_deletion\_window) | Waiting period (in days) before the KMS key is deleted after `terraform destroy`. AWS allows 7-30 days; longer windows provide a safety net against accidental deletion. | `number` | `30` | no |
| <a name="input_s3_bucket_name"></a> [s3\_bucket\_name](#input\_s3\_bucket\_name) | Name of the S3 bucket. When `create_s3_bucket = true` and this is `null`, a deterministic name is derived in `locals.tf`. When `create_s3_bucket = false`, this is REQUIRED and must reference an existing bucket with a valid CloudTrail bucket policy. | `string` | `null` | no |
| <a name="input_s3_expiration_days"></a> [s3\_expiration\_days](#input\_s3\_expiration\_days) | Number of days after object creation before logs are permanently expired. Align with your compliance retention requirements (e.g. 365 for SOC 2, 2555 for 7-year regulatory retention). Must be greater than `s3_transition_to_glacier_days`. | `number` | `365` | no |
| <a name="input_s3_force_destroy"></a> [s3\_force\_destroy](#input\_s3\_force\_destroy) | Allow Terraform to destroy the bucket even if it contains objects. DANGER: enables irreversible deletion of audit logs — keep `false` in production. | `bool` | `false` | no |
| <a name="input_s3_key_prefix"></a> [s3\_key\_prefix](#input\_s3\_key\_prefix) | Prefix (folder path) under which CloudTrail delivers log files within the bucket. Useful for multi-trail or organization-wide buckets. | `string` | `"cloudtrail"` | no |
| <a name="input_s3_lifecycle_enabled"></a> [s3\_lifecycle\_enabled](#input\_s3\_lifecycle\_enabled) | Whether to enable the S3 lifecycle policy that transitions logs to STANDARD\_IA and GLACIER, then expires them. Disable if retention is governed externally (e.g. Object Lock or compliance tooling). | `bool` | `true` | no |
| <a name="input_s3_transition_to_glacier_days"></a> [s3\_transition\_to\_glacier\_days](#input\_s3\_transition\_to\_glacier\_days) | Number of days after object creation before transitioning logs to GLACIER. Must be greater than `s3_transition_to_ia_days`. | `number` | `90` | no |
| <a name="input_s3_transition_to_ia_days"></a> [s3\_transition\_to\_ia\_days](#input\_s3\_transition\_to\_ia\_days) | Number of days after object creation before transitioning logs to STANDARD\_IA. AWS requires a minimum of 30 days. | `number` | `30` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | A map of tags applied to all resources created by this module. Merged with module-managed tags in `locals.tf`. | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_cloudwatch_log_group_arn"></a> [cloudwatch\_log\_group\_arn](#output\_cloudwatch\_log\_group\_arn) | ARN of the CloudWatch log group. Null when `enable_cloudwatch_logs` is false. Note this ARN has no trailing `:*`; CloudTrail itself requires that suffix, which the module appends internally. |
| <a name="output_cloudwatch_log_group_name"></a> [cloudwatch\_log\_group\_name](#output\_cloudwatch\_log\_group\_name) | Name of the CloudWatch log group receiving events. Null when `enable_cloudwatch_logs` is false. Pass this to `aws_cloudwatch_log_metric_filter` to build CIS-style alarms. |
| <a name="output_cloudwatch_logs_role_arn"></a> [cloudwatch\_logs\_role\_arn](#output\_cloudwatch\_logs\_role\_arn) | ARN of the IAM role CloudTrail assumes to write to CloudWatch Logs. Always created, so it is non-null even when log delivery is disabled. |
| <a name="output_cloudwatch_logs_role_name"></a> [cloudwatch\_logs\_role\_name](#output\_cloudwatch\_logs\_role\_name) | Name of the IAM role CloudTrail assumes to write to CloudWatch Logs. |
| <a name="output_kms_key_alias_arn"></a> [kms\_key\_alias\_arn](#output\_kms\_key\_alias\_arn) | ARN of the alias pointing at the module-managed CMK. Null when `create_kms_key` is false. |
| <a name="output_kms_key_alias_name"></a> [kms\_key\_alias\_name](#output\_kms\_key\_alias\_name) | Alias name (`alias/<trail-name>`) of the module-managed CMK. Null when `create_kms_key` is false. |
| <a name="output_kms_key_arn"></a> [kms\_key\_arn](#output\_kms\_key\_arn) | ARN of the KMS key encrypting the log files — the module-managed CMK when `create_kms_key` is true, otherwise the caller-supplied `kms_key_arn`. Null when no CMK is in use (logs fall back to SSE-S3 / AWS-managed encryption). |
| <a name="output_kms_key_created"></a> [kms\_key\_created](#output\_kms\_key\_created) | Whether this module created and therefore owns the lifecycle of the KMS key. |
| <a name="output_kms_key_id"></a> [kms\_key\_id](#output\_kms\_key\_id) | Key ID of the module-managed CMK. Null when `create_kms_key` is false, including when an external key ARN is supplied. |
| <a name="output_s3_bucket_arn"></a> [s3\_bucket\_arn](#output\_s3\_bucket\_arn) | ARN of the module-created log bucket. Null when `create_s3_bucket` is false, since the ARN of an externally managed bucket is not read by this module. |
| <a name="output_s3_bucket_created"></a> [s3\_bucket\_created](#output\_s3\_bucket\_created) | Whether this module created and therefore owns the lifecycle of the log bucket. |
| <a name="output_s3_bucket_domain_name"></a> [s3\_bucket\_domain\_name](#output\_s3\_bucket\_domain\_name) | Global domain name of the module-created log bucket. Null when `create_s3_bucket` is false. |
| <a name="output_s3_bucket_id"></a> [s3\_bucket\_id](#output\_s3\_bucket\_id) | Name of the S3 bucket receiving the log files, whether created by this module or supplied by the caller. |
| <a name="output_s3_bucket_regional_domain_name"></a> [s3\_bucket\_regional\_domain\_name](#output\_s3\_bucket\_regional\_domain\_name) | Region-specific domain name of the module-created log bucket. Prefer this over the global name to avoid cross-region request redirects. Null when `create_s3_bucket` is false. |
| <a name="output_s3_key_prefix"></a> [s3\_key\_prefix](#output\_s3\_key\_prefix) | Normalized key prefix (no leading or trailing slashes) under which log files are delivered. |
| <a name="output_s3_log_path_prefix"></a> [s3\_log\_path\_prefix](#output\_s3\_log\_path\_prefix) | Full S3 key prefix of delivered log objects, including the CloudTrail-managed `AWSLogs/<account-id>/` segment. Useful as the `LOCATION` for an Athena table or as an EventBridge/S3 notification filter. |
| <a name="output_sns_topic_arn"></a> [sns\_topic\_arn](#output\_sns\_topic\_arn) | ARN of the SNS topic used by CloudTrail for delivery notifications. Null when SNS notifications are disabled. |
| <a name="output_sns_topic_name"></a> [sns\_topic\_name](#output\_sns\_topic\_name) | Name of the SNS topic used by CloudTrail for delivery notifications. Null when SNS notifications are disabled. |
| <a name="output_tags"></a> [tags](#output\_tags) | Effective tag set applied to every taggable resource in this module, after merging caller tags with module-managed provenance tags. |
| <a name="output_trail_arn"></a> [trail\_arn](#output\_trail\_arn) | ARN of the CloudTrail trail. Use this for `aws:SourceArn` conditions in external resource policies. |
| <a name="output_trail_home_region"></a> [trail\_home\_region](#output\_trail\_home\_region) | Region in which the trail was created. For a multi-region trail this is the home region that owns the configuration. |
| <a name="output_trail_id"></a> [trail\_id](#output\_trail\_id) | Name (ID) of the CloudTrail trail, as tracked by Terraform state. |
| <a name="output_trail_is_multi_region"></a> [trail\_is\_multi\_region](#output\_trail\_is\_multi\_region) | Whether the trail captures events from all regions. |
| <a name="output_trail_logging_enabled"></a> [trail\_logging\_enabled](#output\_trail\_logging\_enabled) | Whether the trail is actively delivering events. A trail can exist with logging stopped. |
| <a name="output_trail_name"></a> [trail\_name](#output\_trail\_name) | Name of the CloudTrail trail. |

<!-- END_TF_DOCS -->
<!-- markdownlint-enable MD012 -->

## Operational Notes

- The AWS provider's configured Region becomes the trail's home Region and is
  embedded in generated names and policy ARNs.
- The CloudWatch Logs IAM role and inline policy are created even when
  `enable_cloudwatch_logs = false`; only the log group and trail integration
  are conditional.
- Outputs for conditionally managed resources return `null` when the
  corresponding resource is not created. `s3_bucket_id` still returns the
  supplied external bucket name.
- The module does not create metric filters, alarms, dashboards, EventBridge
  rules, Athena tables, or an SNS notification target. Build those controls
  in a separate monitoring layer using the module outputs.
- CloudTrail, CloudTrail Insights, CloudWatch Logs ingestion and retention,
  S3 storage and retrieval, and KMS API usage can incur charges.
- Protect Terraform state because it records resource identifiers, key and
  bucket policies, event selectors, and retention configuration.

## Testing

The native Terraform tests use a mocked AWS provider, require Terraform
`>= 1.7` for `mock_provider`, and do not create AWS resources:

```bash
terraform -chdir=modules/cloudtrail init -backend=false
terraform -chdir=modules/cloudtrail test
```

The integration test creates real, billable AWS resources and requires AWS
credentials with broad permissions for this module:

```bash
go test -v -tags=integration -timeout 45m ./modules/cloudtrail/tests/...
```

Regenerate and check the embedded requirements, providers, resources, inputs,
and outputs with the repository documentation workflow:

```bash
terraform-docs -c .terraform-docs.yml modules/cloudtrail
task docs:check
```

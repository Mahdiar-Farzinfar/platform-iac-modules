# Backend Bootstrap — Terraform Remote State Infrastructure

Terraform module that provisions the foundational infrastructure required for
**S3 remote state** with **DynamoDB state locking**, hardened with
encryption-at-rest (SSE-KMS), TLS-only access, versioning, and lifecycle
management.

> **Chicken-and-egg note:** This module intentionally has **no** `backend`
> block. It must be applied **once with local state**, after which its own
> state can be migrated into the bucket it created via
> `terraform init -migrate-state`. See [Bootstrap Procedure](#bootstrap-procedure).

## What It Creates

| Resource | Purpose | Hardening |
| --- | --- | --- |
| S3 bucket (`<name_prefix>-tfstate-<account_id>`) | Terraform remote state | Versioning, SSE-KMS (CMK), Bucket Key, public access block, `BucketOwnerEnforced`, `prevent_destroy`, lifecycle rules |
| S3 bucket policy | Enforce transport and encryption | Denies non-TLS requests, denies uploads without `aws:kms`, denies uploads using any KMS key other than `kms_key_arn` |
| S3 bucket (`<name_prefix>-tfstate-logs-<account_id>`) *(optional)* | Server access logs for the state bucket | SSE-S3 (`AES256` - KMS is not supported for log delivery), public access block, log expiration |
| DynamoDB table (`<name_prefix>-tfstate-lock`) | State locking (`LockID` hash key) | PAY_PER_REQUEST, PITR, SSE-KMS (CMK), deletion protection, `prevent_destroy` |

Bucket names embed the AWS account ID to guarantee global S3 uniqueness when
the same `name_prefix` is reused across accounts.

## Architecture

```text
┌─────────────────────────────┐        ┌──────────────────────────────┐
│  S3: <prefix>-tfstate-<acct>│        │  DynamoDB:                   │
│  • versioned                │        │  <prefix>-tfstate-lock       │
│  • SSE-KMS (CMK) + BucketKey│        │  • hash key: LockID          │
│  • TLS-only / KMS-only puts │        │  • PITR + deletion protection│
│  • noncurrent-version expiry│        │  • SSE-KMS (CMK)             │
└──────────────┬──────────────┘        └──────────────────────────────┘
               │ server access logs (optional)
               ▼
┌─────────────────────────────┐
│  S3: <prefix>-tfstate-logs- │
│  <acct> • SSE-S3 • expiring │
└─────────────────────────────┘
```

## Usage

```hcl
module "backend_bootstrap" {
  source = "../../modules/backend-bootstrap"

  name_prefix = "acme-platform"
  environment = "shared"
  kms_key_arn = "arn:aws:kms:eu-west-1:123456789012:key/00000000-0000-0000-0000-000000000000"


  # Optional overrides (defaults shown)
  enable_access_logging              = true
  access_logs_retention_days         = 365
  noncurrent_version_expiration_days = 90
  noncurrent_versions_to_retain      = 10
  enable_deletion_protection         = true
  force_destroy                      = false

  tags = {
    Owner      = "platform-team"
    CostCenter = "infra"
  }
}
```

See [`examples/basic`](./examples/basic) for a runnable example.

## Bootstrap Procedure

1. **Apply with local state** (no backend configured):

   ```bash
   terraform init
   terraform apply
   ```

2. **Retrieve the generated backend configuration:**

   ```bash
   terraform output backend_hcl_snippet
   ```

3. **Add the `backend "s3"` block** to the bootstrap stack (and/or consuming
   stacks), setting a unique `key` per stack:

   ```hcl
   terraform {
     backend "s3" {
       bucket         = "acme-platform-tfstate-123456789012"
       key            = "backend-bootstrap/terraform.tfstate"
       region         = "eu-west-1"
       dynamodb_table = "acme-platform-tfstate-lock"
       encrypt        = true
       kms_key_id     = "arn:aws:kms:eu-west-1:123456789012:key/..."
     }
   }
   ```

4. **Migrate the local state into the new backend:**

   ```bash
   terraform init -migrate-state
   ```

Alternatively, consume the `backend_config` output map with
`terraform init -backend-config=...` in automation.

## Security Posture

- **Encryption at rest:** State objects and the lock table are encrypted with a
  **customer-managed KMS key** (`kms_key_arn`). The bucket policy rejects any
  `PutObject` that is unencrypted, uses SSE-S3, or uses a different KMS key.
- **Encryption in transit:** All requests over plain HTTP are denied
  (`aws:SecureTransport = false`).
- **No public access:** Public access blocks on all buckets; object ownership
  is `BucketOwnerEnforced` (ACLs disabled).
- **Recoverability:** Bucket versioning plus DynamoDB point-in-time recovery;
  the newest `noncurrent_versions_to_retain` state versions are kept regardless
  of age.
- **Deletion guard rails:** `lifecycle.prevent_destroy` on the state bucket and
  lock table, DynamoDB deletion protection, and `force_destroy = false` by
  default.

> **IAM note:** Principals using the backend need `s3:GetObject`/`s3:PutObject`
> on the state key, `s3:ListBucket` on the bucket, DynamoDB
> `GetItem`/`PutItem`/`DeleteItem` on the lock table, and
> `kms:Encrypt`/`kms:Decrypt`/`kms:GenerateDataKey` on the KMS key.
> Use `state_bucket_arn`, `lock_table_arn`, and `kms_key_arn` outputs to build
> those policies.

<!-- markdownlint-disable MD012 -->
<!-- BEGIN_TF_DOCS -->


## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.6.0, < 2.0.0 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | >= 5.70.0, < 7.0.0 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | 6.64.0 |



## Resources

| Name | Type |
|------|------|
| [aws_dynamodb_table.lock](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/dynamodb_table) | resource |
| [aws_s3_bucket.access_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket) | resource |
| [aws_s3_bucket.state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket) | resource |
| [aws_s3_bucket_lifecycle_configuration.access_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_lifecycle_configuration) | resource |
| [aws_s3_bucket_lifecycle_configuration.state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_lifecycle_configuration) | resource |
| [aws_s3_bucket_logging.state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_logging) | resource |
| [aws_s3_bucket_notification.access_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_notification) | resource |
| [aws_s3_bucket_notification.state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_notification) | resource |
| [aws_s3_bucket_ownership_controls.state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_ownership_controls) | resource |
| [aws_s3_bucket_policy.state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_policy) | resource |
| [aws_s3_bucket_public_access_block.access_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_public_access_block) | resource |
| [aws_s3_bucket_public_access_block.state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_public_access_block) | resource |
| [aws_s3_bucket_server_side_encryption_configuration.access_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_server_side_encryption_configuration) | resource |
| [aws_s3_bucket_server_side_encryption_configuration.state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_server_side_encryption_configuration) | resource |
| [aws_s3_bucket_versioning.access_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_versioning) | resource |
| [aws_s3_bucket_versioning.state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_versioning) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_kms_key_arn"></a> [kms\_key\_arn](#input\_kms\_key\_arn) | ARN of the customer-managed KMS key used to encrypt the state bucket and<br>the DynamoDB lock table. The bucket policy denies uploads encrypted with<br>any other key. | `string` | n/a | yes |
| <a name="input_name_prefix"></a> [name\_prefix](#input\_name\_prefix) | Prefix used to derive resource names (state bucket, access-logs bucket,<br>lock table). Must be globally-unique-friendly since S3 bucket names are<br>global. Example: "acme-platform". | `string` | n/a | yes |
| <a name="input_access_logs_retention_days"></a> [access\_logs\_retention\_days](#input\_access\_logs\_retention\_days) | Retention period (in days) for S3 server access logs. Only used when enable\_access\_logging is true. | `number` | `365` | no |
| <a name="input_enable_access_logging"></a> [enable\_access\_logging](#input\_enable\_access\_logging) | Whether to create an access-logs bucket and enable S3 server access logging on the state bucket. | `bool` | `true` | no |
| <a name="input_enable_deletion_protection"></a> [enable\_deletion\_protection](#input\_enable\_deletion\_protection) | Enable DynamoDB deletion protection on the state-lock table. | `bool` | `true` | no |
| <a name="input_environment"></a> [environment](#input\_environment) | Deployment environment identifier used in resource names and tags. | `string` | `"shared"` | no |
| <a name="input_force_destroy"></a> [force\_destroy](#input\_force\_destroy) | Allow buckets to be destroyed even when they contain objects. Keep false<br>in production; enable only for ephemeral/test bootstraps. Note that the<br>state bucket also carries lifecycle.prevent\_destroy as a second guard. | `bool` | `false` | no |
| <a name="input_noncurrent_version_expiration_days"></a> [noncurrent\_version\_expiration\_days](#input\_noncurrent\_version\_expiration\_days) | Days after which noncurrent state object versions are expired. | `number` | `90` | no |
| <a name="input_noncurrent_versions_to_retain"></a> [noncurrent\_versions\_to\_retain](#input\_noncurrent\_versions\_to\_retain) | Number of newest noncurrent state versions always retained, regardless of age. | `number` | `10` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Additional tags merged into all resources (on top of module-managed tags). | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_access_logs_bucket_arn"></a> [access\_logs\_bucket\_arn](#output\_access\_logs\_bucket\_arn) | ARN of the access-logs bucket, or null if logging is disabled. |
| <a name="output_access_logs_bucket_name"></a> [access\_logs\_bucket\_name](#output\_access\_logs\_bucket\_name) | Name of the access-logs bucket, or null if logging is disabled. |
| <a name="output_backend_config"></a> [backend\_config](#output\_backend\_config) | Backend settings as a map — usable with `terraform init -backend-config` or in automation. |
| <a name="output_backend_hcl_snippet"></a> [backend\_hcl\_snippet](#output\_backend\_hcl\_snippet) | Copy-paste `backend "s3"` block for consuming Terraform projects. |
| <a name="output_kms_key_arn"></a> [kms\_key\_arn](#output\_kms\_key\_arn) | KMS key ARN used to encrypt state objects and the lock table. |
| <a name="output_lock_table_arn"></a> [lock\_table\_arn](#output\_lock\_table\_arn) | ARN of the lock table (for IAM policy statements). |
| <a name="output_lock_table_name"></a> [lock\_table\_name](#output\_lock\_table\_name) | Name of the DynamoDB table used for state locking. |
| <a name="output_state_bucket_arn"></a> [state\_bucket\_arn](#output\_state\_bucket\_arn) | ARN of the state bucket (for IAM policy statements). |
| <a name="output_state_bucket_name"></a> [state\_bucket\_name](#output\_state\_bucket\_name) | Name of the S3 bucket holding Terraform remote state. |
| <a name="output_state_bucket_region"></a> [state\_bucket\_region](#output\_state\_bucket\_region) | Region of the state bucket (use as `region` in backend config). |

<!-- END_TF_DOCS -->
<!-- markdownlint-enable MD012 -->

## Operational Notes

- **Costs:** DynamoDB is on-demand (PAY_PER_REQUEST); S3 Bucket Key is enabled
  to reduce KMS API costs on frequent state reads/writes.
- **Lifecycle:** Incomplete multipart uploads are aborted after 7 days;
  noncurrent state versions expire per the configured retention.
- **Destroying:** Intentional teardown requires removing `prevent_destroy`,
  disabling DynamoDB deletion protection, and (for non-empty buckets) setting
  `force_destroy = true`. This is deliberate friction.

## Testing

Native Terraform tests live in [`tests/tftest.hcl`](./tests/tftest.hcl):

```bash
terraform test
```

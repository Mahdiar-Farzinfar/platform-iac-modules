<!-- BEGIN_TF_DOCS -->


## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.6.0, < 2.0.0 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | >= 5.70.0, < 7.0.0 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | >= 5.70.0, < 7.0.0 |

## Modules

| Name | Source | Version |
|------|--------|---------|
| <a name="module_backend_bootstrap"></a> [backend\_bootstrap](#module\_backend\_bootstrap) | ../.. | n/a |

## Resources

| Name | Type |
|------|------|
| [aws_kms_alias.terraform_state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_alias) | resource |
| [aws_kms_key.terraform_state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_key) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_name_prefix"></a> [name\_prefix](#input\_name\_prefix) | Globally-unique-friendly prefix for bucket and table names. | `string` | `"acme-platform"` | no |
| <a name="input_region"></a> [region](#input\_region) | AWS region to deploy the remote-state infrastructure into. | `string` | `"eu-central-1"` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_backend_config"></a> [backend\_config](#output\_backend\_config) | Backend settings map for `terraform init -backend-config` or automation. |
| <a name="output_backend_hcl_snippet"></a> [backend\_hcl\_snippet](#output\_backend\_hcl\_snippet) | Copy-paste `backend "s3"` block for consuming Terraform projects. |
| <a name="output_kms_key_arn"></a> [kms\_key\_arn](#output\_kms\_key\_arn) | KMS key ARN used to encrypt state objects and the lock table. |
| <a name="output_lock_table_name"></a> [lock\_table\_name](#output\_lock\_table\_name) | Name of the DynamoDB table used for state locking. |
| <a name="output_state_bucket_name"></a> [state\_bucket\_name](#output\_state\_bucket\_name) | Name of the S3 bucket holding Terraform remote state. |

<!-- END_TF_DOCS -->
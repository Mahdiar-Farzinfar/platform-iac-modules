<!-- BEGIN_TF_DOCS -->


## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.3.0 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | >= 5.0 |



## Modules

| Name | Source | Version |
|------|--------|---------|
| <a name="module_kms"></a> [kms](#module\_kms) | ../../ | n/a |



## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_name"></a> [name](#input\_name) | Name used for the key alias. Must be unique within the region. | `string` | `"example-basic"` | no |
| <a name="input_region"></a> [region](#input\_region) | AWS region to create the example key in. | `string` | `"us-east-1"` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_alias_arn"></a> [alias\_arn](#output\_alias\_arn) | ARN of the alias created for the example key. |
| <a name="output_alias_name"></a> [alias\_name](#output\_alias\_name) | Normalized alias name (alias/<name>). |
| <a name="output_key_arn"></a> [key\_arn](#output\_key\_arn) | ARN of the example KMS key. |
| <a name="output_key_id"></a> [key\_id](#output\_key\_id) | ID of the example KMS key. |

<!-- END_TF_DOCS -->
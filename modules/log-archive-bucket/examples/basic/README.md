<!-- BEGIN_TF_DOCS -->


## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.5.0, < 2.0.0 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | >= 5.0.0, < 7.0.0 |
| <a name="requirement_random"></a> [random](#requirement\_random) | >= 3.5.0, < 4.0.0 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_random"></a> [random](#provider\_random) | >= 3.5.0, < 4.0.0 |

## Modules

| Name | Source | Version |
|------|--------|---------|
| <a name="module_log_archive"></a> [log\_archive](#module\_log\_archive) | ../.. | n/a |

## Resources

| Name | Type |
|------|------|
| [random_pet.suffix](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/pet) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_region"></a> [region](#input\_region) | AWS region to deploy the example into. | `string` | `"eu-central-1"` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_bucket_arn"></a> [bucket\_arn](#output\_bucket\_arn) | ARN of the created log archive bucket. |
| <a name="output_bucket_id"></a> [bucket\_id](#output\_bucket\_id) | Name of the created log archive bucket. |
| <a name="output_encryption_algorithm"></a> [encryption\_algorithm](#output\_encryption\_algorithm) | Effective SSE algorithm (AES256 in this basic example). |

<!-- END_TF_DOCS -->
<!-- BEGIN_TF_DOCS -->


## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.6.0, < 2.0.0 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | >= 5.81.0, < 7.0.0 |



## Modules

| Name | Source | Version |
|------|--------|---------|
| <a name="module_github_oidc"></a> [github\_oidc](#module\_github\_oidc) | ../.. | n/a |



## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_github_repository_subject_prefix"></a> [github\_repository\_subject\_prefix](#input\_github\_repository\_subject\_prefix) | Exact GitHub OIDC repository subject prefix, without a trailing context; for example repo:ORG@ORG-ID/REPO@REPO-ID or repo:ORG/REPOSITORY. | `string` | n/a | yes |
| <a name="input_create_oidc_provider"></a> [create\_oidc\_provider](#input\_create\_oidc\_provider) | Whether this example should create the account-level GitHub Actions OIDC provider. | `bool` | `true` | no |
| <a name="input_existing_oidc_provider_arn"></a> [existing\_oidc\_provider\_arn](#input\_existing\_oidc\_provider\_arn) | ARN of an existing GitHub Actions OIDC provider; required when create\_oidc\_provider is false. | `string` | `null` | no |
| <a name="input_github_environment"></a> [github\_environment](#input\_github\_environment) | Protected GitHub environment allowed to assume the deployment role. | `string` | `"production"` | no |
| <a name="input_name_prefix"></a> [name\_prefix](#input\_name\_prefix) | Prefix used to construct the example IAM role name. | `string` | `"acme-platform"` | no |
| <a name="input_region"></a> [region](#input\_region) | AWS region used to configure the provider. IAM resources are account-global. | `string` | `"us-east-1"` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_deployment_role_arn"></a> [deployment\_role\_arn](#output\_deployment\_role\_arn) | IAM role ARN to use as role-to-assume in aws-actions/configure-aws-credentials. |
| <a name="output_oidc_provider_arn"></a> [oidc\_provider\_arn](#output\_oidc\_provider\_arn) | ARN of the created or reused GitHub Actions OIDC provider. |
| <a name="output_trusted_subject"></a> [trusted\_subject](#output\_trusted\_subject) | Exact GitHub OIDC subject trusted by the deployment role. |

<!-- END_TF_DOCS -->
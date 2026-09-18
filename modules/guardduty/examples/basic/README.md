<!-- BEGIN_TF_DOCS -->


## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.5.0, < 2.0.0 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | >= 5.40.0, < 7.0.0 |



## Modules

| Name | Source | Version |
|------|--------|---------|
| <a name="module_guardduty"></a> [guardduty](#module\_guardduty) | ../../ | n/a |



## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_region"></a> [region](#input\_region) | AWS Region in which to enable GuardDuty. GuardDuty is regional; deploy the module once per region you want monitored. | `string` | `"eu-central-1"` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_detector_arn"></a> [detector\_arn](#output\_detector\_arn) | GuardDuty detector ARN, usable in IAM policy conditions. |
| <a name="output_detector_feature_ids"></a> [detector\_feature\_ids](#output\_detector\_feature\_ids) | Map of enabled protection-plane feature IDs, confirming which planes were activated. |
| <a name="output_detector_id"></a> [detector\_id](#output\_detector\_id) | GuardDuty detector ID for this region. |
| <a name="output_effective_tags"></a> [effective\_tags](#output\_effective\_tags) | The final merged tag set applied by the module. |

<!-- END_TF_DOCS -->
<!-- BEGIN_TF_DOCS -->


## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.3.0 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | ~> 5.0 |



## Modules

| Name | Source | Version |
|------|--------|---------|
| <a name="module_cloudtrail"></a> [cloudtrail](#module\_cloudtrail) | ../.. | n/a |





## Outputs

| Name | Description |
|------|-------------|
| <a name="output_cloudwatch_log_group_name"></a> [cloudwatch\_log\_group\_name](#output\_cloudwatch\_log\_group\_name) | CloudWatch log group receiving real-time events. |
| <a name="output_kms_key_arn"></a> [kms\_key\_arn](#output\_kms\_key\_arn) | ARN of the CMK encrypting the logs. |
| <a name="output_s3_bucket_id"></a> [s3\_bucket\_id](#output\_s3\_bucket\_id) | Name of the S3 bucket receiving the log files. |
| <a name="output_s3_log_path_prefix"></a> [s3\_log\_path\_prefix](#output\_s3\_log\_path\_prefix) | Full S3 key prefix under which log objects are delivered. |
| <a name="output_sns_topic_arn"></a> [sns\_topic\_arn](#output\_sns\_topic\_arn) | ARN of the SNS topic used for CloudTrail delivery notifications. |
| <a name="output_sns_topic_name"></a> [sns\_topic\_name](#output\_sns\_topic\_name) | Name of the SNS topic used for CloudTrail delivery notifications. |
| <a name="output_trail_arn"></a> [trail\_arn](#output\_trail\_arn) | ARN of the created CloudTrail trail. |
| <a name="output_trail_name"></a> [trail\_name](#output\_trail\_name) | Name of the created CloudTrail trail. |

<!-- END_TF_DOCS -->
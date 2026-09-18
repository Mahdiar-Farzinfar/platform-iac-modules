# Amazon GuardDuty

Terraform module for enabling and operating Amazon GuardDuty in one AWS account
and Region. It manages the detector lifecycle, GuardDuty protection features,
optional findings export, trusted IP and threat-intelligence sets, finding
filters, and AWS Organizations integration.

The module is designed for consumption from a separate live-infrastructure
repository. It does not configure an AWS provider, Terraform backend, account
or Region rollout, member-account enrollment workflows, S3/KMS policies, or
downstream EventBridge and notification resources.

## What It Creates

| Component | Creation behavior | Purpose |
| --- | --- | --- |
| GuardDuty detector | Created when `enabled = true` (default) | Enables GuardDuty for the provider's account and Region |
| Detector features | One resource per entry in `detector_features` | Enables or disables protection planes such as S3, EKS, malware, RDS, Lambda, and runtime monitoring |
| S3 publishing destination | Created when `publishing_destination` is provided | Exports findings to a caller-owned S3 bucket encrypted with a caller-owned KMS key |
| Trusted IP sets | One resource per entry in `ipsets` | Allow-lists known addresses to reduce unwanted findings |
| Threat intelligence sets | One resource per entry in `threat_intel_sets` | Imports caller-managed malicious-address feeds |
| Finding filters | One resource per entry in `filters` | Archives or leaves findings unchanged according to ranked criteria |
| Organizations administration | Created when `organization_admin.delegate_admin = true` | Registers the delegated GuardDuty administrator from the management account |
| Organizations configuration | Created when `organization_admin.manage_org_configuration = true` | Applies organization-wide auto-enrollment and feature settings from the delegated administrator account |

GuardDuty is regional and AWS permits only one detector per account and Region.
Deploy one module instance per Region that the security baseline is intended to
cover.

## Prerequisites and Ownership

- Terraform `>= 1.5.0, < 2.0.0` and AWS provider `>= 5.40.0, < 7.0.0`.
- An AWS provider configured by the caller for the target account and Region.
  Provider aliases, credentials, assume-role behavior, and backend settings
  remain outside this module.
- An execution identity with permission to manage GuardDuty resources and to
  create the GuardDuty service-linked role
  (`iam:CreateServiceLinkedRole`) when GuardDuty is first enabled.
- A clear ownership decision for the account and Region. Import or otherwise
  establish a single Terraform owner before managing an existing detector,
  filter, IP set, threat-intel set, or organization setting.
- For an S3 publishing destination, an existing bucket and KMS key whose
  resource policies permit `guardduty.amazonaws.com` to write findings and use
  the key. This module creates the destination reference only; it does not
  create or modify those policies.
- For an IP set or threat-intel set, an externally managed feed file at the
  supplied S3 or HTTPS location. The module does not upload or maintain feed
  contents.
- For Organizations integration, AWS Organizations must already be enabled and
  the caller must use the correct account context:
  `delegate_admin` is a management-account operation, while
  `manage_org_configuration` is a delegated-administrator operation.

Production consumers should pin an immutable module-scoped release tag rather
than a branch or mutable reference.

## Usage

The basic configuration enables the detector and the module's secure default
protection planes:

```hcl
module "guardduty" {
  source = "git::https://github.com/Mahdiar-Farzinfar/platform-iac-modules.git//modules/guardduty?ref=module/guardduty/vX.Y.Z"

  tags = {
    Environment = "production"
    Owner       = "security-platform"
    CostCenter  = "security"
  }
}
```

The default `detector_features` map enables:

```text
S3_DATA_EVENTS
EKS_AUDIT_LOGS
EBS_MALWARE_PROTECTION
RDS_LOGIN_EVENTS
LAMBDA_NETWORK_LOGS
RUNTIME_MONITORING
```

Replace `vX.Y.Z`, account-specific values, and tags with values owned by the
consuming live-infrastructure repository. For local development, use
`source = "./modules/guardduty"`. See [`examples/basic`](./examples/basic) for
a runnable standalone-account example.

### Select protection features

Map keys are stable Terraform resource identities. Renaming a key causes a
destroy/create operation, so keep feature names stable:

```hcl
module "guardduty" {
  source = "git::https://github.com/Mahdiar-Farzinfar/platform-iac-modules.git//modules/guardduty?ref=module/guardduty/vX.Y.Z"

  detector_features = {
    S3_DATA_EVENTS = {
      enabled = true
    }
    EKS_AUDIT_LOGS = {
      enabled = true
    }
    RUNTIME_MONITORING = {
      enabled = true
      additional_configuration = {
        EC2_AGENT_MANAGEMENT          = true
        ECS_FARGATE_AGENT_MANAGEMENT  = true
        EKS_ADDON_MANAGEMENT          = true
      }
    }
  }
}
```

To manage a feature explicitly without enabling it, keep the map entry and set
`enabled = false`. Omitting the entry removes that feature resource from
Terraform management.

### Export findings to S3

Prepare the bucket and KMS key policies before applying this configuration:

```hcl
module "guardduty" {
  source = "git::https://github.com/Mahdiar-Farzinfar/platform-iac-modules.git//modules/guardduty?ref=module/guardduty/vX.Y.Z"

  publishing_destination = {
    bucket_arn  = "arn:aws:s3:::acme-guardduty-findings"
    kms_key_arn = "arn:aws:kms:eu-central-1:123456789012:key/00000000-0000-0000-0000-000000000000"
  }
}
```

The destination bucket and key are caller-owned. Ensure the bucket policy
allows GuardDuty to validate the bucket and write to the expected findings
prefix, and that the KMS key policy permits the GuardDuty service principal to
use the key in the target Region.

### Configure AWS Organizations

Use the management account to register the delegated administrator, then use
the delegated administrator account to manage organization configuration. These
operations are commonly represented by separate module instances in the live
infrastructure repository:

```hcl
# Management account
module "guardduty_admin" {
  source = "git::https://github.com/Mahdiar-Farzinfar/platform-iac-modules.git//modules/guardduty?ref=module/guardduty/vX.Y.Z"

  organization_admin = {
    delegate_admin   = true
    admin_account_id = "111122223333"
  }
}

# Delegated administrator account
module "guardduty_org_configuration" {
  source = "git::https://github.com/Mahdiar-Farzinfar/platform-iac-modules.git//modules/guardduty?ref=module/guardduty/vX.Y.Z"

  organization_admin = {
    manage_org_configuration = true
    auto_enable              = "NEW"
  }

  organization_features = {
    S3_DATA_EVENTS     = "ALL"
    RUNTIME_MONITORING = "NEW"
  }
}
```

`auto_enable` and `organization_features` accept `ALL`, `NEW`, or `NONE`.
Account enrollment, member invitations, organizational policy, and rollout
ordering remain consumer responsibilities.

## Security and Operational Considerations

- **Regional scope:** Deploy once per monitored account and Region. The
  provider's Region determines where the detector and regional GuardDuty
  configuration are created.
- **Secure defaults:** The detector is enabled by default, findings are
  published every 15 minutes by default, and the six default protection planes
  are enabled.
- **Least privilege:** The module does not create IAM policies for consumers.
  Grant the Terraform execution identity only the permissions required for the
  selected features and integrations.
- **Findings export:** Treat the S3 bucket, KMS key, and their policies as part
  of the security boundary. Protect the bucket from public access and align
  retention, versioning, lifecycle, and deletion controls with the findings
  retention requirement.
- **Filters:** `ARCHIVE` permanently suppresses matching findings from the
  active findings view. Use stable names and criteria, and review rank changes
  carefully because lower ranks take precedence.
- **Feed integrity:** IP-set and threat-intelligence files are external inputs.
  Secure their storage, write permissions, integrity, and update process.
- **Organizations:** Delegated-admin and organization-configuration operations
  require the correct account context and appropriate Organizations
  permissions. Do not enable organization-wide settings until the rollout and
  member-account ownership model is agreed.
- **Disable behavior:** Setting `enabled = false` creates no resources. Outputs
  for count-gated resources become `null`; collection outputs become empty maps.
- **Costs:** GuardDuty pricing is usage-based and varies by data source,
  feature, and Region. The basic example's 30-day free trial is not a
  permanent cost exemption.
- **State protection:** Terraform state records detector identifiers, filters,
  feed locations, and integration configuration. Protect state with the
  backend and access controls defined by the live-infrastructure repository.

Caller-supplied `tags` are merged with the module defaults:

```text
ManagedBy = terraform
Module    = guardduty
```

Caller values override those keys when an intentional exception is required.

## Limitations

This module intentionally does not create or manage:

- GuardDuty member-account invitations or acceptance workflows
- AWS Organizations, organizational units, or account provisioning
- S3 buckets, KMS keys, bucket policies, or KMS key policies for findings
- EventBridge rules, SNS topics, dashboards, alarms, or remediation automation
- IP-set and threat-intelligence feed files
- AWS provider configuration, credentials, state backends, or deployment
  orchestration

Build those concerns in dedicated modules or live-infrastructure stacks and
connect them using this module's outputs.

<!-- markdownlint-disable MD012 -->
<!-- BEGIN_TF_DOCS -->


## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.5.0, < 2.0.0 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | >= 5.40.0, < 7.0.0 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | 6.64.0 |



## Resources

| Name | Type |
|------|------|
| [aws_guardduty_detector.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/guardduty_detector) | resource |
| [aws_guardduty_detector_feature.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/guardduty_detector_feature) | resource |
| [aws_guardduty_filter.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/guardduty_filter) | resource |
| [aws_guardduty_ipset.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/guardduty_ipset) | resource |
| [aws_guardduty_organization_admin_account.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/guardduty_organization_admin_account) | resource |
| [aws_guardduty_organization_configuration.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/guardduty_organization_configuration) | resource |
| [aws_guardduty_organization_configuration_feature.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/guardduty_organization_configuration_feature) | resource |
| [aws_guardduty_publishing_destination.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/guardduty_publishing_destination) | resource |
| [aws_guardduty_threatintelset.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/guardduty_threatintelset) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_detector_features"></a> [detector\_features](#input\_detector\_features) | Per-feature enablement for the detector. Keys are GuardDuty feature names; additional\_configuration holds sub-feature toggles (agent/addon management). | <pre>map(object({<br>    enabled                  = bool<br>    additional_configuration = optional(map(bool), {})<br>  }))</pre> | <pre>{<br>  "EBS_MALWARE_PROTECTION": {<br>    "enabled": true<br>  },<br>  "EKS_AUDIT_LOGS": {<br>    "enabled": true<br>  },<br>  "LAMBDA_NETWORK_LOGS": {<br>    "enabled": true<br>  },<br>  "RDS_LOGIN_EVENTS": {<br>    "enabled": true<br>  },<br>  "RUNTIME_MONITORING": {<br>    "enabled": true<br>  },<br>  "S3_DATA_EVENTS": {<br>    "enabled": true<br>  }<br>}</pre> | no |
| <a name="input_enabled"></a> [enabled](#input\_enabled) | Master switch for the module. When false, no resources are created; useful for uniform multi-region/multi-account compositions. | `bool` | `true` | no |
| <a name="input_filters"></a> [filters](#input\_filters) | Finding filters keyed by filter name. action is NOOP or ARCHIVE; rank (1-100) sets evaluation precedence, lower first. | <pre>map(object({<br>    description = optional(string, "Managed by Terraform")<br>    action      = string<br>    rank        = number<br>    criteria = list(object({<br>      field                 = string<br>      equals                = optional(list(string))<br>      not_equals            = optional(list(string))<br>      greater_than          = optional(string)<br>      greater_than_or_equal = optional(string)<br>      less_than             = optional(string)<br>      less_than_or_equal    = optional(string)<br>    }))<br>  }))</pre> | `{}` | no |
| <a name="input_finding_publishing_frequency"></a> [finding\_publishing\_frequency](#input\_finding\_publishing\_frequency) | How often GuardDuty publishes updated findings to CloudWatch Events / EventBridge. | `string` | `"FIFTEEN_MINUTES"` | no |
| <a name="input_ipsets"></a> [ipsets](#input\_ipsets) | Trusted IP sets keyed by set name. location is the S3 URI of the list file (e.g. https://s3.amazonaws.com/bucket/key or s3://bucket/key). | <pre>map(object({<br>    format   = string<br>    location = string<br>    activate = optional(bool, true)<br>  }))</pre> | `{}` | no |
| <a name="input_organization_admin"></a> [organization\_admin](#input\_organization\_admin) | Organization role configuration. delegate\_admin registers admin\_account\_id as the delegated administrator (management account only); manage\_org\_configuration controls org-wide auto-enrollment (delegated admin only). | <pre>object({<br>    delegate_admin           = optional(bool, false)<br>    admin_account_id         = optional(string, null)<br>    manage_org_configuration = optional(bool, false)<br>    auto_enable              = optional(string, "NEW")<br>  })</pre> | `{}` | no |
| <a name="input_organization_features"></a> [organization\_features](#input\_organization\_features) | Org-wide auto-enable mode per GuardDuty feature (used only when manage\_org\_configuration is true). Keys are feature names; values are ALL, NEW, or NONE. | `map(string)` | `{}` | no |
| <a name="input_publishing_destination"></a> [publishing\_destination](#input\_publishing\_destination) | S3 export destination for findings. Bucket policy and KMS key policy must already grant guardduty.amazonaws.com. Set to null to disable export. | <pre>object({<br>    bucket_arn  = string<br>    kms_key_arn = string<br>  })</pre> | `null` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Additional tags applied to all taggable resources created by this module. | `map(string)` | `{}` | no |
| <a name="input_threat_intel_sets"></a> [threat\_intel\_sets](#input\_threat\_intel\_sets) | Threat intelligence sets keyed by set name; same schema as ipsets. | <pre>map(object({<br>    format   = string<br>    location = string<br>    activate = optional(bool, true)<br>  }))</pre> | `{}` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_account_id"></a> [account\_id](#output\_account\_id) | The AWS account ID in which the detector was created. Null when var.enabled is false. |
| <a name="output_detector_arn"></a> [detector\_arn](#output\_detector\_arn) | The ARN of the GuardDuty detector. Null when var.enabled is false. Use in IAM resource conditions and cross-service resource policies. |
| <a name="output_detector_feature_ids"></a> [detector\_feature\_ids](#output\_detector\_feature\_ids) | Map of feature name (e.g. "S3\_DATA\_EVENTS", "EKS\_AUDIT\_LOGS") to the<br>internal resource ID of each aws\_guardduty\_detector\_feature. Empty map<br>when var.enabled is false or var.detector\_features is empty.<br><br>Primary use: `depends_on` reference in the root module to ensure all<br>protection planes are fully configured before enrolling member accounts<br>or attaching policies that react to specific finding types. |
| <a name="output_detector_id"></a> [detector\_id](#output\_detector\_id) | The unique identifier of the GuardDuty detector in this Region. Null when var.enabled is false. Required by member-account enrollment and EventBridge event-pattern rules. |
| <a name="output_enabled"></a> [enabled](#output\_enabled) | Whether the GuardDuty module is enabled. Mirrors var.enabled and is useful as a guard expression in conditional resources in the root module. |
| <a name="output_filter_ids"></a> [filter\_ids](#output\_filter\_ids) | Map of filter name to its resource ID (format: "<detector\_id>:<filter\_name>").<br>Empty map when var.enabled is false or var.filters is empty. |
| <a name="output_ipset_ids"></a> [ipset\_ids](#output\_ipset\_ids) | Map of IP-set name to its resource ID. Empty map when var.enabled is<br>false or var.ipsets is empty. Use the individual IDs in IAM or CloudWatch<br>rules that reference specific allow-listed feeds. |
| <a name="output_organization_admin_account_id"></a> [organization\_admin\_account\_id](#output\_organization\_admin\_account\_id) | The AWS account ID that was registered as the GuardDuty delegated<br>administrator. Mirrors var.organization\_admin.admin\_account\_id when<br>delegation was performed; null otherwise.<br><br>NOTE: This value is always the admin account ID, not the current account.<br>The resource itself has no meaningful attributes beyond the ID it was<br>passed, so this output simply confirms successful delegation. |
| <a name="output_organization_configuration_id"></a> [organization\_configuration\_id](#output\_organization\_configuration\_id) | The detector ID acting as the key for the Organization configuration<br>resource. Null when manage\_org\_configuration is false or var.enabled is<br>false. Useful as a `depends_on` target for resources that must be created<br>after the org-wide auto-enable policy is in place. |
| <a name="output_organization_feature_ids"></a> [organization\_feature\_ids](#output\_organization\_feature\_ids) | Map of organization feature name (e.g. "S3\_DATA\_EVENTS") to the internal<br>resource ID of each aws\_guardduty\_organization\_configuration\_feature.<br>Empty map when manage\_org\_configuration is false, var.enabled is false,<br>or var.organization\_features is empty. |
| <a name="output_publishing_destination_id"></a> [publishing\_destination\_id](#output\_publishing\_destination\_id) | The ID of the S3 publishing destination. Null when no publishing\_destination is configured or var.enabled is false. |
| <a name="output_tags"></a> [tags](#output\_tags) | The effective tag set applied to all taggable resources (module default tags merged with var.tags). Useful for root-module audit outputs and downstream tag-based IAM conditions. |
| <a name="output_threat_intel_set_ids"></a> [threat\_intel\_set\_ids](#output\_threat\_intel\_set\_ids) | Map of threat-intel-set name to its resource ID. Empty map when<br>var.enabled is false or var.threat\_intel\_sets is empty. |

<!-- END_TF_DOCS -->

<!-- markdownlint-enable MD012 -->

## Testing

Native Terraform tests use a mocked AWS provider and exercise default,
disabled, feature-selection, publishing, filters, feed sets, Organizations,
tagging, and output-contract scenarios without creating AWS resources:

```bash
terraform -chdir=modules/guardduty init -backend=false
terraform -chdir=modules/guardduty test
```

The integration suite applies the basic example against a disposable AWS
account, verifies the live GuardDuty API, and destroys the resources afterward.
It is gated by the `integration` build tag and incurs GuardDuty usage charges:

```bash
go test -v -tags=integration -timeout 45m ./modules/guardduty/tests/...
```

Regenerate and validate the embedded Terraform API documentation with the
repository's pinned toolchain:

```bash
terraform-docs -c .terraform-docs.yml modules/guardduty
task docs:check
```

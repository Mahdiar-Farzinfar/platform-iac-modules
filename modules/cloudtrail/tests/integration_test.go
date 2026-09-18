//go:build integration
// +build integration

// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Mahdiar Farzinfar

// Package test contains the apply-time integration suite for the AWS
// CloudTrail module.
//
// Strategy
//
//	Unlike the plan-only native tests (cloudtrail.tftest.hcl), this suite
//	provisions REAL infrastructure in a REAL AWS account, asserts the live
//	security posture through the AWS SDK, and then destroys everything.
//	It is expensive and credentialed, so it is gated behind the `integration`
//	build tag and belongs in a nightly or manually-triggered CI lane — never
//	on the every-commit path.
//
// Prerequisites
//
//   - Go >= 1.21
//   - Valid AWS credentials in the environment (env vars, shared config,
//     or an assumed CI role) with permissions for CloudTrail, S3, KMS,
//     CloudWatch Logs, and IAM.
//   - Terraform >= 1.3.0 and the AWS provider ~> 5.0 on PATH.
//
// Running
//
//	go test -v -tags=integration -timeout 45m ./tests/...
//
// Cost & safety
//
//	Every run creates a trail, a KMS CMK (7-day deletion window via the
//	example), an S3 bucket, and a CloudWatch log group. `defer terraform.Destroy`
//	runs even on assertion failure so orphaned resources are the exception,
//	not the rule. If a run is killed mid-apply, sweep leftovers manually.
package test

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	awsconfig "github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/cloudtrail"
	"github.com/aws/aws-sdk-go-v2/service/cloudwatchlogs"
	cwltypes "github.com/aws/aws-sdk-go-v2/service/cloudwatchlogs/types"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	s3types "github.com/aws/aws-sdk-go-v2/service/s3/types"

	"github.com/gruntwork-io/terratest/modules/terraform"
	test_structure "github.com/gruntwork-io/terratest/modules/test-structure"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

const (
	// The example pins us-east-1 in its provider block; keep the SDK clients
	// aligned so status/describe calls target the trail's home region.
	awsRegion = "us-east-1"

	// CloudTrail can take a short while after apply to begin reporting
	// IsLogging=true; poll rather than assert once.
	loggingPollTimeout  = 3 * time.Minute
	loggingPollInterval = 10 * time.Second
)

// TestCloudTrailBasicExample provisions the basic example end-to-end and
// verifies the live security posture through the AWS SDK.
//
// The test is split into Terratest "stages" (setup → validate) so a developer
// can iterate on validation logic against an already-applied environment via
// SKIP_/ environment variables (e.g. `SKIP_teardown=true`) without paying the
// apply cost each run. See:
// https://terratest.gruntwork.io/docs/testing-best-practices/iterating-locally-using-test-stages/
func TestCloudTrailBasicExample(t *testing.T) {
	t.Parallel()

	// Copy the fixture to an isolated temp dir so parallel runs and the local
	// .terraform cache never collide with the source tree.
	workingDir := test_structure.CopyTerraformFolderToTemp(t, "..", "examples/basic")

	terraformOptions := &terraform.Options{
		TerraformDir: workingDir,
		// The example hardcodes the region in its provider block; passing it
		// as an env var keeps the SDK and Terraform in lockstep if the fixture
		// is later parameterized.
		EnvVars: map[string]string{
			"AWS_DEFAULT_REGION": awsRegion,
		},
		// Retry transient AWS eventual-consistency / throttling errors that are
		// safe to re-apply, rather than failing the whole run.
		MaxRetries:         3,
		TimeBetweenRetries: 15 * time.Second,
		RetryableTerraformErrors: map[string]string{
			".*RequestError: send request failed.*": "Transient AWS API error, retrying.",
			".*throttl.*":                           "AWS API throttling, retrying.",
			".*Throttling.*":                        "AWS API throttling, retrying.",
		},
	}

	// Ensure the working dir and options survive across stages.
	test_structure.SaveTerraformOptions(t, workingDir, terraformOptions)

	// Teardown always runs, even if validation panics or fails an assertion.
	defer test_structure.RunTestStage(t, "teardown", func() {
		opts := test_structure.LoadTerraformOptions(t, workingDir)
		terraform.Destroy(t, opts)
	})

	test_structure.RunTestStage(t, "setup", func() {
		opts := test_structure.LoadTerraformOptions(t, workingDir)
		terraform.InitAndApply(t, opts)
	})

	test_structure.RunTestStage(t, "validate", func() {
		opts := test_structure.LoadTerraformOptions(t, workingDir)
		validateOutputs(t, opts)
		validateLiveResources(t, opts)
	})
}

// validateOutputs asserts the module's outputs are shaped correctly before we
// spend AWS API calls on deeper checks. Cheap, fast-failing sanity gate.
func validateOutputs(t *testing.T, opts *terraform.Options) {
	trailARN := terraform.Output(t, opts, "trail_arn")
	trailName := terraform.Output(t, opts, "trail_name")
	bucketID := terraform.Output(t, opts, "s3_bucket_id")
	kmsKeyARN := terraform.Output(t, opts, "kms_key_arn")
	logGroupName := terraform.Output(t, opts, "cloudwatch_log_group_name")
	logPathPrefix := terraform.Output(t, opts, "s3_log_path_prefix")

	assert.Equal(t, "example-basic-trail", trailName, "trail_name should match the example input")
	assert.True(t, strings.HasPrefix(trailARN, "arn:aws:cloudtrail:"), "trail_arn should be a CloudTrail ARN")
	assert.Contains(t, trailARN, ":trail/"+trailName, "trail_arn should reference the trail name")

	assert.NotEmpty(t, bucketID, "s3_bucket_id must be populated when the module owns the bucket")
	assert.True(t, strings.HasPrefix(kmsKeyARN, "arn:aws:kms:"), "kms_key_arn should be a KMS key ARN")
	assert.NotEmpty(t, logGroupName, "cloudwatch_log_group_name must be set when CloudWatch delivery is enabled")

	// The log path prefix should carry the CloudTrail-managed AWSLogs segment.
	assert.Contains(t, logPathPrefix, "/AWSLogs/", "s3_log_path_prefix should include the AWSLogs segment")
	assert.True(t, strings.HasSuffix(logPathPrefix, "/CloudTrail"), "s3_log_path_prefix should end with /CloudTrail")
}

// validateLiveResources drives the AWS SDK to confirm the deployed environment
// matches the module's security contract: the trail is multi-region, actively
// logging, has file validation on, and is KMS-encrypted; the bucket blocks
// public access and has versioning enabled; the log group has the expected
// retention.
func validateLiveResources(t *testing.T, opts *terraform.Options) {
	ctx := context.Background()
	cfg, err := awsconfig.LoadDefaultConfig(ctx, awsconfig.WithRegion(awsRegion))
	require.NoError(t, err, "failed to load AWS SDK config")

	trailName := terraform.Output(t, opts, "trail_name")
	bucketID := terraform.Output(t, opts, "s3_bucket_id")
	kmsKeyARN := terraform.Output(t, opts, "kms_key_arn")
	logGroupName := terraform.Output(t, opts, "cloudwatch_log_group_name")

	assertTrailConfiguration(t, ctx, cfg, trailName, bucketID, kmsKeyARN, logGroupName)
	assertTrailIsLogging(t, ctx, cfg, trailName)
	assertBucketHardening(t, ctx, cfg, bucketID)
	assertLogGroupRetention(t, ctx, cfg, logGroupName)
}

// assertTrailConfiguration checks the durable, plan-visible security settings
// of the trail against the module's hardcoded and default guarantees.
func assertTrailConfiguration(
	t *testing.T,
	ctx context.Context,
	cfg aws.Config,
	trailName, bucketID, kmsKeyARN, logGroupName string,
) {
	client := cloudtrail.NewFromConfig(cfg)

	out, err := client.GetTrail(ctx, &cloudtrail.GetTrailInput{Name: aws.String(trailName)})
	require.NoError(t, err, "GetTrail failed for %q", trailName)
	require.NotNil(t, out.Trail, "GetTrail returned a nil trail")

	tr := out.Trail
	assert.True(t, aws.ToBool(tr.IsMultiRegionTrail), "trail must be multi-region (CIS 3.1)")
	assert.True(t, aws.ToBool(tr.IncludeGlobalServiceEvents), "trail must include global service events")
	assert.True(t, aws.ToBool(tr.LogFileValidationEnabled), "log file validation must be enabled and never regress")

	assert.Equal(t, bucketID, aws.ToString(tr.S3BucketName), "trail should deliver to the module-managed bucket")
	assert.Equal(t, kmsKeyARN, aws.ToString(tr.KmsKeyId), "trail must be encrypted with the module CMK")

	// CloudTrail requires the log group ARN with a trailing ":*"; the module
	// appends that suffix internally, so the wired value contains the group name.
	require.NotNil(t, tr.CloudWatchLogsLogGroupArn, "CloudWatch Logs group ARN must be wired on the trail")
	assert.Contains(t, aws.ToString(tr.CloudWatchLogsLogGroupArn), logGroupName,
		"trail's CloudWatch group ARN should reference the module log group")
	assert.NotEmpty(t, aws.ToString(tr.CloudWatchLogsRoleArn), "trail must have a CloudWatch Logs role ARN")
}

// assertTrailIsLogging polls GetTrailStatus until the trail reports IsLogging,
// tolerating the brief propagation delay after apply.
func assertTrailIsLogging(t *testing.T, ctx context.Context, cfg aws.Config, trailName string) {
	client := cloudtrail.NewFromConfig(cfg)
	deadline := time.Now().Add(loggingPollTimeout)

	for {
		status, err := client.GetTrailStatus(ctx, &cloudtrail.GetTrailStatusInput{Name: aws.String(trailName)})
		require.NoError(t, err, "GetTrailStatus failed for %q", trailName)

		if aws.ToBool(status.IsLogging) {
			return // success
		}
		if time.Now().After(deadline) {
			t.Fatalf("trail %q did not reach IsLogging=true within %s", trailName, loggingPollTimeout)
		}
		time.Sleep(loggingPollInterval)
	}
}

// assertBucketHardening confirms the log bucket blocks public access on all
// four dimensions and has versioning enabled — the core of the S3 contract.
func assertBucketHardening(t *testing.T, ctx context.Context, cfg aws.Config, bucketID string) {
	client := s3.NewFromConfig(cfg)

	pab, err := client.GetPublicAccessBlock(ctx, &s3.GetPublicAccessBlockInput{Bucket: aws.String(bucketID)})
	require.NoError(t, err, "GetPublicAccessBlock failed for %q", bucketID)
	require.NotNil(t, pab.PublicAccessBlockConfiguration, "public access block configuration must exist")

	c := pab.PublicAccessBlockConfiguration
	assert.True(t, aws.ToBool(c.BlockPublicAcls), "BlockPublicAcls must be true")
	assert.True(t, aws.ToBool(c.BlockPublicPolicy), "BlockPublicPolicy must be true")
	assert.True(t, aws.ToBool(c.IgnorePublicAcls), "IgnorePublicAcls must be true")
	assert.True(t, aws.ToBool(c.RestrictPublicBuckets), "RestrictPublicBuckets must be true")

	ver, err := client.GetBucketVersioning(ctx, &s3.GetBucketVersioningInput{Bucket: aws.String(bucketID)})
	require.NoError(t, err, "GetBucketVersioning failed for %q", bucketID)
	assert.Equal(t, s3types.BucketVersioningStatusEnabled, ver.Status, "bucket versioning must be Enabled")

	// The bucket policy must exist (ACL check + write + TLS-only deny).
	pol, err := client.GetBucketPolicy(ctx, &s3.GetBucketPolicyInput{Bucket: aws.String(bucketID)})
	require.NoError(t, err, "GetBucketPolicy failed for %q", bucketID)
	require.NotNil(t, pol.Policy, "bucket policy must be attached")
	assert.Contains(t, aws.ToString(pol.Policy), "aws:SecureTransport",
		"bucket policy must enforce TLS via an aws:SecureTransport deny statement")
}

// assertLogGroupRetention confirms the CloudWatch log group exists with the
// example's configured 365-day retention.
func assertLogGroupRetention(t *testing.T, ctx context.Context, cfg aws.Config, logGroupName string) {
	client := cloudwatchlogs.NewFromConfig(cfg)

	out, err := client.DescribeLogGroups(ctx, &cloudwatchlogs.DescribeLogGroupsInput{
		LogGroupNamePrefix: aws.String(logGroupName),
	})
	require.NoError(t, err, "DescribeLogGroups failed for %q", logGroupName)

	var found *cwltypes.LogGroup
	for i := range out.LogGroups {
		if aws.ToString(out.LogGroups[i].LogGroupName) == logGroupName {
			found = &out.LogGroups[i]
			break
		}
	}
	require.NotNil(t, found, "log group %q not found", logGroupName)
	assert.Equal(t, int32(365), aws.ToInt32(found.RetentionInDays),
		fmt.Sprintf("log group %q must retain for 365 days", logGroupName))
}

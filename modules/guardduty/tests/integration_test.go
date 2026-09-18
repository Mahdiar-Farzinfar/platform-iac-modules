// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Mahdiar Farzinfar

//go:build integration

// Package test contains Terratest-based integration tests for the AWS
// GuardDuty Terraform module.
//
// Overview
//
//	These tests provision *real* AWS infrastructure via the basic example
//	(examples/basic) and assert on the resulting Terraform outputs and, where
//	valuable, against the live AWS API through the AWS SDK for Go v2.
//
//	Unlike the native `terraform test` plan-only suite (guardduty.tftest.hcl),
//	this file exercises the full apply -> verify -> destroy lifecycle and is
//	intended to run in a disposable sandbox account within CI.
//
// Prerequisites
//
//   - Go >= 1.21
//   - Terraform >= 1.5.0 on PATH
//   - Valid AWS credentials for a DISPOSABLE sandbox account
//     (env vars, SSO, or a shared profile). GuardDuty is chargeable.
//   - The IAM principal must be able to create the GuardDuty service-linked
//     role and manage detectors, features, filters and IP sets.
//
// Execution
//
//	# Run the whole integration suite (build tag gates accidental runs):
//	go test -v -tags=integration -timeout 45m ./...
//
//	# Run a single test:
//	go test -v -tags=integration -run TestGuardDutyBasicExample -timeout 30m ./...
//
// Cost & Safety
//
//	Every test uses `defer terraform.Destroy` to guarantee teardown even on
//	assertion failure. A unique tag namespace is applied so orphaned resources
//	(should teardown ever fail) are trivially identifiable and scriptable to
//	clean up.
//
// Design Notes
//
//   - Region is randomized from an allow-list to reduce cross-test collisions
//     (only one detector may exist per account/region).
//   - Tests are marked t.Parallel() where they operate on independent example
//     copies; test_structure.CopyTerraformFolderToTemp isolates state.
//   - AWS SDK assertions are best-effort "trust but verify" checks layered on
//     top of the primary Terraform-output assertions.
package test

import (
	"context"
	"strings"
	"testing"

	"github.com/aws/aws-sdk-go-v2/aws"
	awsconfig "github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/guardduty"
	"github.com/gruntwork-io/terratest/modules/random"
	"github.com/gruntwork-io/terratest/modules/terraform"
	test_structure "github.com/gruntwork-io/terratest/modules/test-structure"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

const (
	// basicExampleRelPath is the path to the basic example relative to this
	// test file (modules/guardduty/tests/integration_test.go).
	basicExampleRelPath = "../examples/basic"

	// defaultDetectorFeatureCount is the number of protection planes enabled
	// by the module's secure defaults (see variables.tf detector_features).
	defaultDetectorFeatureCount = 6
)

// candidateRegions is the allow-list of Regions the suite may deploy into.
// Randomizing across a small set reduces the chance of colliding with a
// pre-existing detector (only one detector is permitted per account/region).
var candidateRegions = []string{
	"eu-central-1",
	"eu-west-1",
	"us-east-1",
	"us-east-2",
	"us-west-2",
}

// expectedDefaultFeatures mirrors the module's default detector_features map.
// Order is irrelevant; membership is what we assert.
var expectedDefaultFeatures = []string{
	"S3_DATA_EVENTS",
	"EKS_AUDIT_LOGS",
	"EBS_MALWARE_PROTECTION",
	"RDS_LOGIN_EVENTS",
	"LAMBDA_NETWORK_LOGS",
	"RUNTIME_MONITORING",
}

// -----------------------------------------------------------------------------
// Helpers
// -----------------------------------------------------------------------------
// newAWSGuardDutyClient builds an AWS SDK v2 GuardDuty client bound to the
// supplied Region using the ambient credential chain.
func newAWSGuardDutyClient(t *testing.T, region string) *guardduty.Client {
	t.Helper()

	cfg, err := awsconfig.LoadDefaultConfig(
		context.Background(),
		awsconfig.WithRegion(region),
	)
	require.NoError(t, err, "failed to load AWS SDK configuration for region %s", region)

	return guardduty.NewFromConfig(cfg)
}

// baseTerraformOptions returns a hardened options struct pointing at an
// isolated, temp-copied example directory. Copying keeps each test's state and
// .terraform cache independent, which is essential for t.Parallel().
func baseTerraformOptions(t *testing.T, exampleDir, region string, extraVars map[string]interface{}) *terraform.Options {
	t.Helper()

	vars := map[string]interface{}{
		"region": region,
	}
	for k, v := range extraVars {
		vars[k] = v
	}

	return terraform.WithDefaultRetryableErrors(t, &terraform.Options{
		TerraformDir: exampleDir,
		Vars:         vars,
		// Fail fast on unexpected interactive prompts in CI.
		NoColor: true,
		// Surface the AWS Region to the AWS provider without relying on the
		// caller's shell environment being pre-set.
		EnvVars: map[string]string{
			"AWS_REGION":         region,
			"AWS_DEFAULT_REGION": region,
		},
	})
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------
// TestGuardDutyBasicExample provisions the basic example end-to-end and
// asserts that:
//
//  1. A detector ID and ARN are emitted (module.enabled == true path).
//  2. Exactly the six default protection planes are activated.
//  3. The caller-supplied tags are merged into the effective tag set.
//  4. The live GuardDuty API confirms the detector exists and is ENABLED with
//     the default FIFTEEN_MINUTES publishing frequency.
func TestGuardDutyBasicExample(t *testing.T) {
	t.Parallel()

	// Isolate the example in a temp dir so parallel runs don't share state.
	exampleDir := test_structure.CopyTerraformFolderToTemp(t, "../..", basicExampleRelPath)

	region := candidateRegions[random.Random(0, len(candidateRegions)-1)]
	uniqueID := strings.ToLower(random.UniqueId())

	terraformOptions := baseTerraformOptions(t, exampleDir, region, map[string]interface{}{
		// Namespaced tags make orphaned resources identifiable if teardown
		// ever fails. The basic example forwards `tags` to the module.
		"tags": map[string]string{
			"Environment": "sandbox",
			"Project":     "guardduty-basic-example",
			"ManagedBy":   "terraform",
			"TestRun":     uniqueID,
		},
	})

	// Guarantee teardown even if an assertion panics/fails.
	defer terraform.Destroy(t, terraformOptions)

	terraform.InitAndApply(t, terraformOptions)

	// --- Output-contract assertions -----------------------------------------

	detectorID := terraform.Output(t, terraformOptions, "detector_id")
	require.NotEmpty(t, detectorID, "detector_id output must be non-empty when the module is enabled")

	detectorARN := terraform.Output(t, terraformOptions, "detector_arn")
	require.NotEmpty(t, detectorARN, "detector_arn output must be non-empty when the module is enabled")
	assert.True(t,
		strings.HasPrefix(detectorARN, "arn:aws"),
		"detector_arn should be a well-formed ARN, got %q", detectorARN,
	)

	featureIDs := terraform.OutputMap(t, terraformOptions, "detector_feature_ids")
	assert.Len(t, featureIDs, defaultDetectorFeatureCount,
		"expected %d default protection planes, got %d", defaultDetectorFeatureCount, len(featureIDs))
	for _, feature := range expectedDefaultFeatures {
		assert.Contains(t, featureIDs, feature,
			"default protection plane %q must be present in detector_feature_ids", feature)
	}

	effectiveTags := terraform.OutputMap(t, terraformOptions, "effective_tags")
	assert.Equal(t, "sandbox", effectiveTags["Environment"], "Environment tag must be propagated")
	assert.Equal(t, "guardduty-basic-example", effectiveTags["Project"], "Project tag must be propagated")
	assert.Equal(t, "terraform", effectiveTags["ManagedBy"], "ManagedBy tag must be propagated")
	assert.Equal(t, uniqueID, effectiveTags["TestRun"], "TestRun tag must be propagated for traceability")

	// --- Live AWS API verification (trust but verify) -----------------------

	client := newAWSGuardDutyClient(t, region)
	verifyDetectorLive(t, client, detectorID)
}

// TestGuardDutyDetectorIsUnique verifies that the emitted detector ID is
// present in the account's list of detectors for the deployed Region. This
// guards against a false-positive where an output is populated but the
// underlying resource was not actually created in the target Region.
func TestGuardDutyDetectorIsUnique(t *testing.T) {
	t.Parallel()

	exampleDir := test_structure.CopyTerraformFolderToTemp(t, "../..", basicExampleRelPath)

	region := candidateRegions[random.Random(0, len(candidateRegions)-1)]
	uniqueID := strings.ToLower(random.UniqueId())

	terraformOptions := baseTerraformOptions(t, exampleDir, region, map[string]interface{}{
		"tags": map[string]string{
			"Environment": "sandbox",
			"Project":     "guardduty-uniqueness-check",
			"ManagedBy":   "terraform",
			"TestRun":     uniqueID,
		},
	})

	defer terraform.Destroy(t, terraformOptions)
	terraform.InitAndApply(t, terraformOptions)

	detectorID := terraform.Output(t, terraformOptions, "detector_id")
	require.NotEmpty(t, detectorID, "detector_id output must be non-empty")

	client := newAWSGuardDutyClient(t, region)

	listOut, err := client.ListDetectors(context.
		Background(), &guardduty.ListDetectorsInput{})
	require.NoError(t, err, "failed to list detectors in region %s", region)

	found := false
	for _, id := range listOut.DetectorIds {
		if id == detectorID {
			found = true
			break
		}
	}

	assert.True(t, found, "detector %q should be visible in the AWS API list for region %s", detectorID, region)
}

// -----------------------------------------------------------------------------
// Live API Verification Helpers
// -----------------------------------------------------------------------------
func verifyDetectorLive(t *testing.T, client *guardduty.Client, detectorID string) {
	t.Helper()

	getOut, err := client.GetDetector(context.Background(), &guardduty.GetDetectorInput{
		DetectorId: aws.String(detectorID),
	})
	require.NoError(t, err, "failed to fetch detector state for ID %s", detectorID)

	// verify initial status
	assert.Equal(t, "ENABLED", string(getOut.Status), "detector should be ENABLED by default module configuration")
	assert.Equal(t, "FIFTEEN_MINUTES", string(getOut.FindingPublishingFrequency),
		"detector should use the default 15-minute publishing frequency")
}

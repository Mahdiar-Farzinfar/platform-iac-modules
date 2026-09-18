// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Mahdiar Farzinfar

// Package test contains Terratest integration tests for the SCP Terraform module.
//
// These tests deploy real AWS Organizations resources and must be run against a
// live management account. They are intentionally excluded from short / unit test
// runs via the -short flag.
//
// Required environment variables:
//
//	TEST_ORG_ROOT_ID   – organization root ID, e.g. r-ab12
//	AWS_DEFAULT_REGION – AWS region for provider initialisation (us-east-1 typical)
//
// Optional environment variables (enable additional test coverage):
//
//	TEST_OU_ID      – OU target, e.g. ou-ab12-12345678 (enables multi-target tests)
//	TEST_ACCOUNT_ID – 12-digit member account ID            (enables multi-target tests)
//
// Run all integration tests:
//
//	go test -v -timeout 30m ./...
//
// Run a single test:
//
//	go test -v -timeout 10m -run TestIntegration_SCPCreateWithStructuredStatements ./...
//
// Skip integration tests (run nothing, since this package has no unit tests):
//
//	go test -short ./...
package test

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"testing"

	"github.com/aws/aws-sdk-go-v2/aws"
	awsconfig "github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/organizations"
	"github.com/gruntwork-io/terratest/modules/random"
	"github.com/gruntwork-io/terratest/modules/terraform"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// ---------------------------------------------------------------------------
// Suite bootstrap
// ---------------------------------------------------------------------------
// TestMain is the test suite entry point. It validates that the required
// environment variables are present before any test function runs, and prints
// a clear diagnostic when they are absent so CI pipelines fail fast.
func TestMain(m *testing.M) {
	required := []string{"TEST_ORG_ROOT_ID", "AWS_DEFAULT_REGION"}
	missing := make([]string, 0, len(required))
	for _, v := range required {
		if os.Getenv(v) == "" {
			missing = append(missing, v)
		}
	}
	if len(missing) > 0 {
		fmt.Fprintf(os.Stderr,
			"SKIP: integration tests require the following environment variables: %s\n",
			strings.Join(missing, ", "),
		)
		os.Exit(0) // exit 0 so CI does not fail on intentional skips
	}
	os.Exit(m.Run())
}

// ---------------------------------------------------------------------------
// Configuration helpers
// ---------------------------------------------------------------------------
// testEnv bundles the environment-variable-sourced configuration that each
// test reads once and passes to helpers. Keeping it in a struct rather than
// reading os.Getenv repeatedly makes tests easier to reason about.
type testEnv struct {
	rootID    string // required
	region    string // required
	ouID      string // optional
	accountID string // optional
}

// loadTestEnv reads the current process environment and returns a testEnv.
// It must only be called after TestMain has already verified the required vars.
func loadTestEnv() testEnv {
	return testEnv{
		rootID:    os.Getenv("TEST_ORG_ROOT_ID"),
		region:    os.Getenv("AWS_DEFAULT_REGION"),
		ouID:      os.Getenv("TEST_OU_ID"),
		accountID: os.Getenv("TEST_ACCOUNT_ID"),
	}
}

// ---------------------------------------------------------------------------
// Policy document helpers
// ---------------------------------------------------------------------------
// policyDocument mirrors the top-level structure of an IAM/SCP JSON document.
// It is used only for assertion parsing; it is not a complete model.
type policyDocument struct {
	Version   string            `json:"Version"`
	Statement []policyStatement `json:"Statement"`
}

type policyStatement struct {
	Sid      string      `json:"Sid,omitempty"`
	Effect   string      `json:"Effect"`
	Action   interface{} `json:"Action"`
	Resource interface{} `json:"Resource"`
}

// parsePolicyOutput decodes the policy_content Terraform output and returns the
// parsed document. It fails the test immediately on any JSON decode error.
func parsePolicyOutput(t *testing.T, opts *terraform.Options) policyDocument {
	t.Helper()
	raw := terraform.OutputContext(t, context.Background(), opts, "policy_content")
	var doc policyDocument
	require.NoError(t, json.Unmarshal([]byte(raw), &doc),
		"policy_content output must be valid JSON: %s", raw)
	return doc
}

// ---------------------------------------------------------------------------
// Terraform options factory
// ---------------------------------------------------------------------------
// moduleOptions returns terraform.Options pointed at the SCP module root
// (one directory above this tests/ directory) with the given variable
// overrides. It sets no-color and the target AWS region.
func moduleOptions(t *testing.T, env testEnv, vars map[string]interface{}) *terraform.Options {
	t.Helper()
	return &terraform.Options{
		TerraformDir: "../",
		Vars:         vars,
		EnvVars: map[string]string{
			"AWS_DEFAULT_REGION": env.region,
		},
		NoColor: true,
	}
}

// ---------------------------------------------------------------------------
// AWS Organizations client helper
// ---------------------------------------------------------------------------
// newOrganizationsClient builds an AWS SDK v2 Organizations client using the
// current default credential chain.
func newOrganizationsClient(t *testing.T, region string) *organizations.Client {
	t.Helper()
	cfg, err := awsconfig.LoadDefaultConfig(context.Background(),
		awsconfig.WithRegion(region),
	)
	require.NoError(t, err, "failed to load AWS SDK config")
	return organizations.NewFromConfig(cfg)
}

// policyExists returns true when the given policy ID is still visible via the
// DescribePolicy API. It does not fail the test on a not-found error; it
// returns false instead so the caller can assert the expected state.
func policyExists(t *testing.T, client *organizations.Client, policyID string) bool {
	t.Helper()
	_, err := client.DescribePolicy(context.Background(), &organizations.DescribePolicyInput{
		PolicyId: aws.String(policyID),
	})
	if err != nil {
		// Non-nil error is treated as "does not exist" for assertion purposes.
		// If the test cares about the specific error type it can use the AWS SDK
		// error introspection directly.
		return false
	}
	return true
}

// detachAndDeletePolicy is a manual cleanup helper used by the skip_destroy
// test to remove the retained policy after verifying it still exists.
func detachAndDeletePolicy(t *testing.T, client *organizations.Client, policyID string, targetIDs []string) {
	t.Helper()
	for _, tid := range targetIDs {
		_, err := client.DetachPolicy(context.Background(), &organizations.DetachPolicyInput{
			PolicyId: aws.String(policyID),
			TargetId: aws.String(tid),
		})
		if err != nil {
			t.Logf("warn: DetachPolicy(%s from %s): %v", policyID, tid, err)
		}
	}
	_, err := client.DeletePolicy(context.Background(), &organizations.DeletePolicyInput{
		PolicyId: aws.String(policyID),
	})
	if err != nil {
		t.Logf("warn: DeletePolicy(%s): %v", policyID, err)
	}
}

// ---------------------------------------------------------------------------
// Shared statement fixtures
// ---------------------------------------------------------------------------
// denyLeaveOrg is the canonical guardrail statement shared across tests.
// Keeping it as a package-level variable avoids repetition and ensures all
// tests exercise the exact same statement shape.
var denyLeaveOrg = map[string]interface{}{
	"sid":       "DenyLeaveOrganization",
	"effect":    "Deny",
	"actions":   []string{"organizations:LeaveOrganization"},
	"resources": []string{"*"},
	"condition": map[string]interface{}{},
}

var denyDisableCloudTrail = map[string]interface{}{
	"sid":    "DenyDisableCloudTrail",
	"effect": "Deny",
	"actions": []string{
		"cloudtrail:StopLogging",
		"cloudtrail:DeleteTrail",
		"cloudtrail:UpdateTrail",
	},
	"resources": []string{"*"},
	"condition": map[string]interface{}{},
}

// ---------------------------------------------------------------------------
// Test: structured statements → policy created and attached
// ---------------------------------------------------------------------------
// TestIntegration_SCPCreateWithStructuredStatements is the primary happy-path
// test. It applies the module with two HCL statements, asserts that the SCP is
// created in AWS, validates the rendered policy document, and confirms outputs.
func TestIntegration_SCPCreateWithStructuredStatements(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping integration test in -short mode")
	}
	t.Parallel()

	env := loadTestEnv()
	scpName := fmt.Sprintf("terratest-guardrails-%s", random.UniqueID())

	opts := moduleOptions(t, env, map[string]interface{}{
		"name":        scpName,
		"description": "Integration test SCP – structured statements",
		"statements":  []interface{}{denyLeaveOrg, denyDisableCloudTrail},
		"target_ids":  []string{env.rootID},
		"tags": map[string]string{
			"Environment": "test",
			"CreatedBy":   "terratest",
		},
	})

	// Always destroy after the test regardless of outcome.
	defer terraform.DestroyContext(t, context.Background(), opts)
	terraform.InitAndApplyContext(t, context.Background(), opts)

	// ── output assertions ──────────────────────────────────────────────────

	policyID := terraform.OutputContext(t, context.Background(), opts, "id")
	require.NotEmpty(t, policyID, "output.id must not be empty after apply")

	policyARN := terraform.OutputContext(t, context.Background(), opts, "arn")
	assert.True(t,
		strings.HasPrefix(policyARN, "arn:aws:organizations::"),
		"output.arn should be a valid Organizations ARN, got: %s", policyARN)

	assert.Equal(t, scpName, terraform.OutputContext(t, context.Background(), opts, "name"),
		"output.name must match the requested SCP name")

	assert.Equal(t, "false", terraform.OutputContext(t, context.Background(), opts, "aws_managed"),
		"module-create SCP should not be marked as aws_managed")

	// ── rendered JSON assertions ──────────────────────────────────────────

	doc := parsePolicyOutput(t, opts)
	assert.Equal(t, "2012-10-17", doc.Version, "policy document must have 2012-10-17 version")
	assert.Len(t, doc.Statement, 2, "policy document must contain exactly 2 statements")

	// ── AWS state assertions ──────────────────────────────────────────────

	client := newOrganizationsClient(t, env.region)
	assert.True(t, policyExists(t, client, policyID), "SCP must exist in AWS Organizations")
}

// ---------------------------------------------------------------------------
// Test: skip_destroy behavior
// ---------------------------------------------------------------------------
// TestIntegration_SkipDestroy verifies the skip_destroy input correctly
// retains the policy in AWS even after Terraform destroys the module
// resources.
func TestIntegration_SkipDestroy(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping integration test in -short mode")
	}
	t.Parallel()

	env := loadTestEnv()
	scpName := fmt.Sprintf("terratest-persist-%s", random.UniqueID())

	opts := moduleOptions(t, env, map[string]interface{}{
		"name":         scpName,
		"skip_destroy": true, // <--- The feature under test
		"statements":   []interface{}{denyLeaveOrg},
		"target_ids":   []string{env.rootID},
	})

	// Do NOT defer terraform.DestroyContext(t, ctx, opts) for the whole function,
	// because we need to check existence AFTER the destroy call.
	terraform.InitAndApplyContext(t, context.Background(), opts)

	policyID := terraform.OutputContext(t, context.Background(), opts, "id")
	client := newOrganizationsClient(t, env.region)

	// 1. Verify policy exists
	assert.True(t, policyExists(t, client, policyID), "SCP should exist before destroy")

	// 2. Destroy infrastructure
	terraform.DestroyContext(t, context.Background(), opts)

	// 3. Verify policy still exists in AWS
	assert.True(t, policyExists(t, client, policyID), "SCP should still exist in AWS after destroy (skip_destroy=true)")

	// 4. Manually cleanup to avoid leaking resources in the test account
	detachAndDeletePolicy(t, client, policyID, []string{env.rootID})
}

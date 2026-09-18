// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Mahdiar Farzinfar

//go:build integration

// Package test contains integration tests for the KMS Terraform module.
//
// Scope — complements tests/kms.tftest.hcl, which already covers (mocked, no
// credentials): resource counts, secure defaults, policy composition, alias
// normalization, grant configuration, and variable validation. This file
// verifies only what mocks cannot:
//
//   - the module applies cleanly against real AWS (main.tf, variables.tf,
//     locals.tf, versions.tf, outputs.tf via examples/basic/main.tf)
//   - the created key's real server-side state (enabled, rotation, spec,
//     customer-managed, single-Region)
//   - the rendered key policy as stored by KMS (EnableRootAccountAccess)
//   - alias resolution through the KMS API, not just Terraform state
//   - a live Encrypt/Decrypt round trip through the alias
//   - tag propagation (module tags, caller tags, provider default_tags)
//   - apply idempotency (second plan is empty)
//   - clean destroy (deferred; key is scheduled for deletion, alias removed)
//
// Requirements:
//   - AWS credentials in the environment (assumed role / SSO / env vars) with
//     permission to manage KMS keys, aliases, and tags.
//   - This test creates billable resources. The key is created with a 7-day
//     deletion window (set in examples/basic) and is scheduled for deletion
//     on teardown.
//
// Run:
//
//	cd modules/kms/tests
//	go test -tags integration -timeout 45m -run TestKMSBasicExample -v
package test

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/kms"
	kmstypes "github.com/aws/aws-sdk-go-v2/service/kms/types"
	"github.com/gruntwork-io/terratest/modules/random"
	"github.com/gruntwork-io/terratest/modules/retry"
	"github.com/gruntwork-io/terratest/modules/terraform"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestKMSBasicExample(t *testing.T) {
	t.Parallel()

	// 1. Arrange — inputs and random suffix for name uniqueness
	uniqueID := strings.ToLower(random.UniqueId())
	aliasName := fmt.Sprintf("itest-%s", uniqueID)
	awsRegion := os.Getenv("AWS_REGION")
	if awsRegion == "" {
		awsRegion = "us-east-1"
	}

	exampleDir := filepath.Join("..", "examples", "basic")

	terraformOptions := terraform.WithDefaultRetryableErrors(t, &terraform.Options{
		TerraformDir: exampleDir,
		Vars: map[string]interface{}{
			"region": awsRegion,
			"name":   aliasName,
		},
		NoColor: true,
	})

	// 2. Teardown — defer destroy and AWS-side validation cleanup
	defer terraform.Destroy(t, terraformOptions)

	// 3. Act — Init & Apply
	terraform.InitAndApply(t, terraformOptions)

	// 4. Assert (Outputs)
	keyID := terraform.Output(t, terraformOptions, "key_id")
	keyARN := terraform.Output(t, terraformOptions, "key_arn")
	aliasARNOutput := terraform.Output(t, terraformOptions, "alias_arn")
	aliasNameOutput := terraform.Output(t, terraformOptions, "alias_name")

	assert.Regexp(t, regexp.MustCompile(`^[a-f0-9-]{36}$`), keyID, "Key ID must be a UUID.")
	assert.Contains(t, keyARN, keyID, "Key ARN must contain the Key ID.")
	assert.Contains(t, aliasARNOutput, aliasName, "Alias ARN must contain the alias name.")
	assert.Equal(t, fmt.Sprintf("alias/%s", aliasName), aliasNameOutput, "Alias name must be normalized.")

	// 5. Assert (Idempotency)
	plan := terraform.Plan(t, terraformOptions)
	assert.Contains(t, plan, "No changes.", "Apply must be idempotent; second plan must be empty.")

	// 6. Assert (AWS API Validation)
	sdkCfg, err := config.LoadDefaultConfig(context.TODO(), config.WithRegion(awsRegion))
	require.NoError(t, err, "Failed to load AWS SDK config.")
	kmsSvc := kms.NewFromConfig(sdkCfg)

	// A. Key metadata verification
	retry.DoWithRetry(t, "Describe KMS Key", 3, 5*time.Second, func() (string, error) {
		out, err := kmsSvc.DescribeKey(context.TODO(), &kms.DescribeKeyInput{KeyId: aws.String(keyID)})
		if err != nil {
			return "", err
		}

		m := out.KeyMetadata
		if m == nil {
			return "", fmt.Errorf("DescribeKey returned no key metadata")
		}

		assert.Equal(t, kmstypes.KeyStateEnabled, m.KeyState, "Key must be Enabled.")
		assert.Equal(t, kmstypes.CustomerMasterKeySpecSymmetricDefault, m.CustomerMasterKeySpec, "Spec must be SYMMETRIC_DEFAULT.")
		assert.Equal(t, kmstypes.KeyUsageTypeEncryptDecrypt, m.KeyUsage, "Usage must be ENCRYPT_DECRYPT.")
		assert.Equal(t, kmstypes.KeyManagerTypeCustomer, m.KeyManager, "Key must be Customer Managed (CMK).")
		assert.False(t, aws.ToBool(m.MultiRegion), "Basic example key must not be multi-Region.")
		assert.Contains(t, aws.ToString(m.Description), "kms/basic", "Description must match the example input.")

		return aws.ToString(m.KeyId), nil
	})

	// B. Key rotation status
	rotation, err := kmsSvc.GetKeyRotationStatus(context.TODO(), &kms.GetKeyRotationStatusInput{KeyId: aws.String(keyID)})
	require.NoError(t, err, "Failed to get key rotation status.")
	assert.True(t, rotation.KeyRotationEnabled, "Automatic annual key rotation must be enabled by default.")

	// C. Key policy verification
	policy, err := kmsSvc.GetKeyPolicy(context.TODO(), &kms.GetKeyPolicyInput{
		KeyId:      aws.String(keyID),
		PolicyName: aws.String("default"),
	})
	require.NoError(t, err, "Failed to fetch key policy.")
	assert.Contains(t, aws.ToString(policy.Policy), "EnableRootAccountAccess", "Policy must contain the safety-net root-access statement.")

	// D. Tag verification (provider default_tags + module-supplied tags)
	tags, err := kmsSvc.ListResourceTags(context.TODO(), &kms.ListResourceTagsInput{KeyId: aws.String(keyID)})
	require.NoError(t, err, "Failed to list key tags.")

	tagMap := make(map[string]string)
	for _, tag := range tags.Tags {
		tagMap[aws.ToString(tag.TagKey)] = aws.ToString(tag.TagValue)
	}

	assert.Equal(t, "kms/basic", tagMap["Example"], "Must inherit provider default_tags.")
	assert.Equal(t, "Terraform", tagMap["ManagedBy"], "Must inherit provider default_tags.")
	assert.Equal(t, "kms", tagMap["terraform-module"], "Must include module local tags.")
	assert.Equal(t, aliasName, tagMap["Name"], "Must include caller-supplied module tags.")

	// E. Functional Verification — Alias resolution & cryptographic use
	// Verifies the alias isn't just a record in state, but correctly routes
	// traffic in the AWS control plane.
	plainText := "Terraform Enterprise Grade KMS Module"

	encryptOut, err := kmsSvc.Encrypt(context.TODO(), &kms.EncryptInput{
		KeyId:     aws.String(aliasNameOutput), // Use the alias, not the ID
		Plaintext: []byte(plainText),
	})
	require.NoError(t, err, "Failed to encrypt plaintext via alias.")

	decryptOut, err := kmsSvc.Decrypt(context.TODO(), &kms.DecryptInput{
		KeyId:          aws.String(keyARN),
		CiphertextBlob: encryptOut.CiphertextBlob,
	})
	require.NoError(t, err, "Failed to decrypt ciphertext via key ARN.")

	assert.Equal(t, plainText, string(decryptOut.Plaintext), "Decrypted text must match original.")
}

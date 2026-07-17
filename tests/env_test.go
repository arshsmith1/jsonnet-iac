// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package jsonnet_iac_test

import (
	"encoding/json"
	"flag"
	"github.com/google/go-cmp/cmp"
	"github.com/google/go-jsonnet"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

var update = flag.Bool("update", false, "update golden files")

func TestEnv(t *testing.T) {
	testDataDir := "testdata"
	jsonnetFiles, err := filepath.Glob(filepath.Join(testDataDir, "*.jsonnet"))
	if err != nil {
		t.Fatalf("failed to glob testdata: %v", err)
	}
	if len(jsonnetFiles) == 0 {
		t.Fatal("no .jsonnet files found in testdata")
	}

	for _, inputPath := range jsonnetFiles {
		filename := filepath.Base(inputPath)
		testName := strings.TrimSuffix(filename, ".jsonnet")

		t.Run(testName, func(t *testing.T) {
			vm := jsonnet.MakeVM()
			absPath, err := filepath.Abs(".")
			if err != nil {
				t.Fatalf("failed to get absolute path: %v", err)
			}
			parentPath := filepath.Join(absPath, "..")
			importer := &jsonnet.FileImporter{
				JPaths: []string{absPath, parentPath},
			}
			vm.Importer(importer)

			jsonOutput, err := vm.EvaluateFile(inputPath)
			if err != nil {
				t.Fatalf("failed to evaluate jsonnet: %v", err)
			}

			var generatedFiles map[string]string
			if err := json.Unmarshal([]byte(jsonOutput), &generatedFiles); err != nil {
				t.Fatalf("failed to unmarshal jsonnet output: %v\nOutput: %s", err, jsonOutput)
			}

			// If the -update flag is passed, regenerate the golden files in the workspace.
			// CLI: blaze run //configs/cloud/gong/services/cloudsap/jsonnet_iac:env_test -- -update
			if *update {
				workspaceDir := os.Getenv("BUILD_WORKSPACE_DIRECTORY")
				if workspaceDir == "" {
					t.Fatal("build_workspace_directory is not set, please run with 'blaze run <target> -- -test.v -update'")
				}
				expectedDirName := testName + "_expected"
				expectedDir := filepath.Join(workspaceDir, "configs/cloud/gong/services/cloudsap/jsonnet_iac/testdata", expectedDirName)

				os.RemoveAll(expectedDir)
				if err := os.MkdirAll(expectedDir, 0755); err != nil {
					t.Fatalf("failed to create directory %s: %v", expectedDir, err)
				}
				for genFilename, content := range generatedFiles {
					outputPath := filepath.Join(expectedDir, genFilename)
					if err := os.WriteFile(outputPath, []byte(content), 0644); err != nil {
						t.Fatalf("failed to write output file %s: %v", outputPath, err)
					}
				}
				t.Logf("Updated testdata in %s", expectedDir)
				return // Test passes since we just generated the golden files.
			}

			expectedDirName := testName + "_expected"
			expectedDir := filepath.Join(testDataDir, expectedDirName)

			// verify expectedDir exists
			if _, err := os.Stat(expectedDir); os.IsNotExist(err) {
				t.Fatalf("expected directory %q does not exist, run with -update to generate", expectedDir)
			}

			// Iterate over generated files and compare with expected
			for genFilename, content := range generatedFiles {
				expectedPath := filepath.Join(expectedDir, genFilename)
				expectedBytes, err := os.ReadFile(expectedPath)
				if err != nil {
					t.Errorf("failed to read expected file %q: %v\nGenerated content:\n%s", genFilename, err, content)
					continue
				}
				expected := string(expectedBytes)

				if diff := cmp.Diff(expected, content); diff != "" {
					t.Errorf("content mismatch for %q (-want +got):\n%s", genFilename, diff)
				}
			}

			// Verify that no extra files are in expected directory
			expectedFiles, err := os.ReadDir(expectedDir)
			if err != nil {
				t.Fatalf("failed to read expected directory: %v", err)
			}

			for _, expectedFile := range expectedFiles {
				if _, ok := generatedFiles[expectedFile.Name()]; !ok {
					t.Errorf("extra file in expected directory: %q", expectedFile.Name())
				}
			}
		})
	}
}

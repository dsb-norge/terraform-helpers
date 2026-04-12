#!/usr/bin/env bats
load 'helpers/test_helper'

setup_module_fixture() {
  export _MODULE_DIR="${BATS_FILE_TMPDIR}/module_project_${BATS_TEST_NUMBER}"
  cp -r "${FIXTURES_DIR}/project_module" "${_MODULE_DIR}"
  cd "${_MODULE_DIR}"
  mock_standard_tools
  source "${SUT}"
  default_test_setup
}

# -- Phase 7: tf-status rich module output --

@test "tf-status in module repo shows root .tf files count" {
  setup_module_fixture
  _dsbTfLogInfo=1
  run _dsb_tf_report_status
  assert_clean_output_contains "Root .tf files"
}

@test "tf-status in module repo shows TFLint config status" {
  setup_module_fixture
  _dsbTfLogInfo=1
  run _dsb_tf_report_status
  assert_clean_output_contains "TFLint config"
  assert_clean_output_contains "found"
}

@test "tf-status in module repo shows lock file status" {
  setup_module_fixture
  _dsbTfLogInfo=1
  run _dsb_tf_report_status
  assert_clean_output_contains "Lock file"
}

@test "tf-status in module repo shows terraform-docs config" {
  setup_module_fixture
  _dsbTfLogInfo=1
  run _dsb_tf_report_status
  assert_clean_output_contains "terraform-docs config"
}

@test "tf-status in module repo shows example count" {
  setup_module_fixture
  _dsbTfLogInfo=1
  run _dsb_tf_report_status
  assert_clean_output_contains "Available examples"
  assert_clean_output_contains "(2)"
}

@test "tf-status in module repo shows test file counts" {
  setup_module_fixture
  _dsbTfLogInfo=1
  run _dsb_tf_report_status
  assert_clean_output_contains "Unit test files"
  assert_clean_output_contains "Integration test files"
}

# -- Phase 7: tf-check-dir module enhancements --

@test "tf-check-dir in module repo checks README.md" {
  setup_module_fixture
  _dsbTfLogInfo=1
  run tf-check-dir
  assert_success
  assert_clean_output_contains "README.md check"
  assert_clean_output_contains "passed"
}

@test "tf-check-dir in module repo checks LICENSE" {
  setup_module_fixture
  _dsbTfLogInfo=1
  run tf-check-dir
  assert_success
  assert_clean_output_contains "LICENSE check"
  assert_clean_output_contains "passed"
}

@test "tf-check-dir in module repo checks examples/ directory" {
  setup_module_fixture
  _dsbTfLogInfo=1
  run tf-check-dir
  assert_success
  assert_clean_output_contains "examples/ check"
  assert_clean_output_contains "present"
}

@test "tf-check-dir in module repo checks tests/ directory" {
  setup_module_fixture
  _dsbTfLogInfo=1
  run tf-check-dir
  assert_success
  assert_clean_output_contains "tests/ check"
  assert_clean_output_contains "present"
}

@test "tf-check-dir fails when README.md missing in module repo" {
  setup_module_fixture
  rm -f "${_MODULE_DIR}/README.md"
  _dsbTfLogErrors=1
  _dsbTfLogInfo=1
  run tf-check-dir
  assert_failure
  assert_clean_output_contains "README.md"
  assert_clean_output_contains "failed"
}

@test "tf-check-dir fails when LICENSE missing in module repo" {
  setup_module_fixture
  rm -f "${_MODULE_DIR}/LICENSE.md"
  rm -f "${_MODULE_DIR}/LICENSE"
  _dsbTfLogErrors=1
  _dsbTfLogInfo=1
  run tf-check-dir
  assert_failure
  assert_clean_output_contains "LICENSE"
}

@test "tf-check-dir warns when examples/ missing in module repo" {
  setup_module_fixture
  rm -rf "${_MODULE_DIR}/examples"
  _dsbTfLogInfo=1
  _dsbTfLogWarnings=1
  run tf-check-dir
  # Should still pass (examples are recommended, not required)
  assert_success
  assert_clean_output_contains "examples/"
  assert_clean_output_contains "not found"
}

@test "tf-check-dir warns when tests/ missing in module repo" {
  setup_module_fixture
  rm -rf "${_MODULE_DIR}/tests"
  _dsbTfLogInfo=1
  _dsbTfLogWarnings=1
  run tf-check-dir
  # Should still pass (tests are recommended, not required)
  assert_success
  assert_clean_output_contains "tests/"
  assert_clean_output_contains "not found"
}

# -- Phase 7: tf-check-prereqs module enhancements --

@test "tf-check-prereqs in module repo shows azure auth status" {
  setup_module_fixture
  _dsbTfLogInfo=1
  run tf-check-prereqs
  assert_success
  assert_clean_output_contains "Azure authentication check"
  assert_clean_output_contains "integration tests"
}

@test "tf-check-prereqs in module repo shows module-specific advice" {
  setup_module_fixture
  _dsbTfLogInfo=1
  run tf-check-prereqs
  assert_success
  assert_clean_output_contains "tf-status"
}

@test "tf-check-prereqs in project repo shows project-specific advice" {
  local project_dir
  project_dir="$(create_standard_project)"
  cd "${project_dir}"
  mock_standard_tools
  source "${SUT}"
  default_test_setup
  _dsbTfLogInfo=1

  run tf-check-prereqs
  assert_success
  assert_clean_output_contains "tf-select-env"
}

# -- Phase 7: tf-check-tools includes terraform-docs --

@test "tf-check-tools shows terraform-docs check" {
  setup_module_fixture
  _dsbTfLogInfo=1
  run tf-check-tools
  assert_success
  assert_clean_output_contains "terraform-docs"
}

@test "tf-check-tools warns when terraform-docs not installed but still passes" {
  setup_module_fixture
  mock_terraform_docs_not_installed
  _dsbTfLogInfo=1
  _dsbTfLogErrors=1
  run tf-check-tools
  # terraform-docs is optional, so check-tools should still pass
  assert_success
  assert_clean_output_contains "terraform-docs"
  assert_clean_output_contains "not found"
}

# -- Help system includes new groups --

@test "tf-help groups includes examples group in module repo" {
  setup_module_fixture
  _dsbTfLogInfo=1
  run tf-help groups
  assert_clean_output_contains "examples"
}

@test "tf-help groups includes testing group in module repo" {
  setup_module_fixture
  _dsbTfLogInfo=1
  run tf-help groups
  assert_clean_output_contains "testing"
}

@test "tf-help groups includes docs group in module repo" {
  setup_module_fixture
  _dsbTfLogInfo=1
  run tf-help groups
  assert_clean_output_contains "docs"
}

@test "tf-help examples shows example commands" {
  setup_module_fixture
  _dsbTfLogInfo=1
  run tf-help examples
  assert_clean_output_contains "tf-init-examples"
  assert_clean_output_contains "tf-validate-examples"
  assert_clean_output_contains "tf-lint-examples"
}

@test "tf-help testing shows testing commands" {
  setup_module_fixture
  _dsbTfLogInfo=1
  run tf-help testing
  assert_clean_output_contains "tf-test"
  assert_clean_output_contains "tf-test-unit"
  assert_clean_output_contains "tf-test-integration"
  assert_clean_output_contains "tf-test-examples"
}

@test "tf-help docs shows docs commands" {
  setup_module_fixture
  _dsbTfLogInfo=1
  run tf-help docs
  assert_clean_output_contains "tf-docs"
  assert_clean_output_contains "tf-docs-examples"
  assert_clean_output_contains "tf-docs-all"
}

@test "tf-help tf-init-examples shows help" {
  setup_module_fixture
  _dsbTfLogInfo=1
  run tf-help tf-init-examples
  assert_clean_output_contains "Initialize all or a specific example"
}

@test "tf-help tf-test shows help" {
  setup_module_fixture
  _dsbTfLogInfo=1
  run tf-help tf-test
  assert_clean_output_contains "terraform test"
}

@test "tf-help tf-docs shows help" {
  setup_module_fixture
  _dsbTfLogInfo=1
  run tf-help tf-docs
  assert_clean_output_contains "terraform-docs"
}

@test "tf-help commands in module repo shows new groups" {
  setup_module_fixture
  _dsbTfLogInfo=1
  run tf-help commands
  assert_clean_output_contains "tf-init-examples"
  assert_clean_output_contains "tf-test"
  assert_clean_output_contains "tf-docs"
}

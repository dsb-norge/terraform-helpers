#!/usr/bin/env bats
# shellcheck disable=SC2164,SC1090,SC1091,SC2030,SC2031,SC2034,SC2154,SC2317
load 'helpers/test_helper'

setup_module_fixture() {
  export _MODULE_DIR="${BATS_FILE_TMPDIR}/module_project_${BATS_TEST_NUMBER}"
  cp -r "${FIXTURES_DIR}/project_module" "${_MODULE_DIR}"
  cd "${_MODULE_DIR}"
  mock_standard_tools
  source "${SUT}"
  default_test_setup
}

setup_project_fixture() {
  source_script_in_project
  default_test_setup
}

# ===========================================================================
# tf-versions
# ===========================================================================

@test "tf-versions function exists" {
  setup_module_fixture
  assert_function_exists "tf-versions"
}

@test "tf-versions succeeds in module repo" {
  setup_module_fixture
  run tf-versions
  assert_success
}

@test "tf-versions shows version information in module repo" {
  setup_module_fixture
  _dsbTfLogInfo=1
  run tf-versions
  assert_success
  assert_clean_output_contains "Version Information"
  assert_clean_output_contains "Tool Versions"
  assert_clean_output_contains "Terraform CLI"
}

@test "tf-versions shows module root versions" {
  setup_module_fixture
  _dsbTfLogInfo=1
  run tf-versions
  assert_success
  assert_clean_output_contains "Module Root Versions"
}

@test "tf-versions succeeds in project repo" {
  setup_project_fixture
  run tf-versions
  assert_success
}

@test "tf-versions shows environment info in project repo" {
  setup_project_fixture
  _dsbTfLogInfo=1
  run tf-versions
  assert_success
  assert_clean_output_contains "Version Information"
  assert_clean_output_contains "Tool Versions"
}

@test "tf-versions help entry exists" {
  setup_module_fixture
  _dsbTfLogInfo=1
  run tf-help tf-versions
  assert_success
  assert_clean_output_contains "tf-versions"
  assert_clean_output_contains "version information"
}

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

# -- Phase 6: _dsb_tf_check_terraform_docs --

@test "_dsb_tf_check_terraform_docs succeeds when installed" {
  setup_module_fixture
  run _dsb_tf_check_terraform_docs
  assert_success
}

@test "_dsb_tf_check_terraform_docs fails when not installed" {
  setup_module_fixture
  mock_terraform_docs_not_installed
  _dsbTfLogErrors=1
  run _dsb_tf_check_terraform_docs
  assert_failure
  assert_clean_output_contains "terraform-docs not found"
}

# -- Phase 6: tf-docs --

@test "tf-docs succeeds in module repo" {
  setup_module_fixture
  run tf-docs
  assert_success
}

@test "tf-docs outputs generation info" {
  setup_module_fixture
  _dsbTfLogInfo=1
  run tf-docs
  assert_success
  assert_clean_output_contains "Generating terraform-docs for module root"
}

@test "tf-docs fails in project repo" {
  local project_dir
  project_dir="$(create_standard_project)"
  cd "${project_dir}"
  mock_standard_tools
  source "${SUT}"
  default_test_setup

  run tf-docs
  assert_failure
  assert_clean_output_contains "only available in Terraform module repos"
}

@test "tf-docs fails when terraform-docs not installed" {
  setup_module_fixture
  mock_terraform_docs_not_installed
  _dsbTfLogErrors=1
  run tf-docs
  assert_failure
  assert_clean_output_contains "terraform-docs not found"
}

# -- Phase 6: tf-docs-all-examples --

@test "tf-docs-all-examples succeeds in module repo" {
  setup_module_fixture
  run tf-docs-all-examples
  assert_success
}

@test "tf-docs-all-examples outputs per-example info" {
  setup_module_fixture
  _dsbTfLogInfo=1
  run tf-docs-all-examples
  assert_success
  assert_clean_output_contains "01-basic"
  assert_clean_output_contains "02-advanced"
}

@test "tf-docs-all-examples fails in project repo" {
  local project_dir
  project_dir="$(create_standard_project)"
  cd "${project_dir}"
  mock_standard_tools
  source "${SUT}"
  default_test_setup

  run tf-docs-all-examples
  assert_failure
  assert_clean_output_contains "only available in Terraform module repos"
}

@test "tf-docs-all-examples fails when examples docs config missing" {
  setup_module_fixture
  rm -f "${_MODULE_DIR}/examples/.terraform-docs.yml"
  _dsbTfLogErrors=1
  run tf-docs-all-examples
  assert_failure
  assert_clean_output_contains "config not found"
}

@test "tf-docs-all-examples fails when terraform-docs not installed" {
  setup_module_fixture
  mock_terraform_docs_not_installed
  _dsbTfLogErrors=1
  run tf-docs-all-examples
  assert_failure
  assert_clean_output_contains "terraform-docs not found"
}

# -- Phase 6: tf-docs-all --

@test "tf-docs-all succeeds in module repo" {
  setup_module_fixture
  run tf-docs-all
  assert_success
}

@test "tf-docs-all runs both root and examples" {
  setup_module_fixture
  _dsbTfLogInfo=1
  run tf-docs-all
  assert_success
  assert_clean_output_contains "Generating terraform-docs for module root"
  assert_clean_output_contains "Generating terraform-docs for examples"
}

@test "tf-docs-all fails in project repo" {
  local project_dir
  project_dir="$(create_standard_project)"
  cd "${project_dir}"
  mock_standard_tools
  source "${SUT}"
  default_test_setup

  run tf-docs-all
  assert_failure
  assert_clean_output_contains "only available in Terraform module repos"
}

# -- Singular docs-example command --

@test "tf-docs-example requires example name" {
  setup_module_fixture
  run tf-docs-example
  assert_failure
  assert_clean_output_contains "No example specified"
}

@test "tf-docs-example succeeds with valid example" {
  setup_module_fixture
  run tf-docs-example "01-basic"
  assert_success
}

@test "tf-docs-example fails for nonexistent example" {
  setup_module_fixture
  run tf-docs-example "nonexistent"
  assert_failure
  assert_clean_output_contains "not found"
}

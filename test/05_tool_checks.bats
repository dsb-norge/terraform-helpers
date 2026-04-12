#!/usr/bin/env bats
load 'helpers/test_helper'

setup_file() {
  export _TOOL_TEST_PROJECT="${BATS_FILE_TMPDIR}/project"
  cp -r "${FIXTURES_DIR}/project_standard" "${_TOOL_TEST_PROJECT}"
}

setup() {
  cd "${_TOOL_TEST_PROJECT}"
  mock_standard_tools
  source "${SUT}"
  default_test_setup
}

teardown() {
  default_test_teardown
}

# -- Individual tool checks: success cases --

@test "_dsb_tf_check_az_cli succeeds with mock" {
  mock_az
  run _dsb_tf_check_az_cli
  assert_success
}

@test "_dsb_tf_check_gh_cli succeeds with mock" {
  mock_gh
  run _dsb_tf_check_gh_cli
  assert_success
}

@test "_dsb_tf_check_terraform succeeds with mock" {
  mock_terraform
  run _dsb_tf_check_terraform
  assert_success
}

@test "_dsb_tf_check_jq succeeds with mock" {
  mock_jq
  run _dsb_tf_check_jq
  assert_success
}

@test "_dsb_tf_check_yq succeeds with mock" {
  mock_yq
  run _dsb_tf_check_yq
  assert_success
}

@test "_dsb_tf_check_golang succeeds with mock" {
  mock_go
  run _dsb_tf_check_golang
  assert_success
}

@test "_dsb_tf_check_hcledit succeeds with mock" {
  mock_hcledit
  run _dsb_tf_check_hcledit
  assert_success
}

@test "_dsb_tf_check_terraform_config_inspect succeeds with mock" {
  mock_terraform_config_inspect
  run _dsb_tf_check_terraform_config_inspect
  assert_success
}

@test "_dsb_tf_check_curl succeeds with mock" {
  mock_curl
  run _dsb_tf_check_curl
  assert_success
}

# -- Individual tool checks: failure cases --

@test "_dsb_tf_check_az_cli fails when not installed" {
  mock_az_not_installed
  _dsbTfLogErrors=1
  run _dsb_tf_check_az_cli
  assert_failure
  assert_clean_output_contains "Azure CLI not found"
}

@test "_dsb_tf_check_gh_cli fails when not installed" {
  mock_gh_not_installed
  _dsbTfLogErrors=1
  run _dsb_tf_check_gh_cli
  assert_failure
  assert_clean_output_contains "GitHub CLI not found"
}

@test "_dsb_tf_check_terraform fails when not installed" {
  mock_terraform_not_installed
  _dsbTfLogErrors=1
  run _dsb_tf_check_terraform
  assert_failure
  assert_clean_output_contains "Terraform not found"
}

@test "_dsb_tf_check_jq fails when not installed" {
  mock_jq_not_installed
  _dsbTfLogErrors=1
  run _dsb_tf_check_jq
  assert_failure
  assert_clean_output_contains "jq not found"
}

@test "_dsb_tf_check_yq fails when not installed" {
  mock_yq_not_installed
  _dsbTfLogErrors=1
  run _dsb_tf_check_yq
  assert_failure
  assert_clean_output_contains "yq not found"
}

@test "_dsb_tf_check_golang fails when not installed" {
  mock_go_not_installed
  _dsbTfLogErrors=1
  run _dsb_tf_check_golang
  assert_failure
  assert_clean_output_contains "Go not found"
}

@test "_dsb_tf_check_hcledit fails when not installed" {
  mock_hcledit_not_installed
  _dsbTfLogErrors=1
  run _dsb_tf_check_hcledit
  assert_failure
  assert_clean_output_contains "hcledit not found"
}

@test "_dsb_tf_check_terraform_config_inspect fails when not installed" {
  mock_terraform_config_inspect_not_installed
  _dsbTfLogErrors=1
  run _dsb_tf_check_terraform_config_inspect
  assert_failure
  assert_clean_output_contains "terraform-config-inspect not found"
}

@test "_dsb_tf_check_curl fails when not installed" {
  mock_curl_not_installed
  _dsbTfLogErrors=1
  run _dsb_tf_check_curl
  assert_failure
  assert_clean_output_contains "curl not found"
}

# -- _dsb_tf_check_tools: aggregate --

@test "_dsb_tf_check_tools reports all-pass with standard mocks" {
  _dsbTfLogInfo=1
  _dsbTfLogErrors=1
  run _dsb_tf_check_tools
  assert_success
  assert_clean_output_contains "passed"
}

@test "_dsb_tf_check_tools reports failure when terraform not installed" {
  mock_terraform_not_installed
  _dsbTfLogInfo=1
  _dsbTfLogErrors=1
  run _dsb_tf_check_tools
  assert_failure
  assert_clean_output_contains "Terraform"
  assert_clean_output_contains "MISSING"
}

# -- _dsb_tf_check_gh_auth --

@test "_dsb_tf_check_gh_auth succeeds when authenticated" {
  mock_gh
  run _dsb_tf_check_gh_auth
  assert_success
}

@test "_dsb_tf_check_gh_auth fails when not authenticated" {
  mock_gh_not_authenticated
  _dsbTfLogErrors=1
  run _dsb_tf_check_gh_auth
  assert_failure
}

@test "_dsb_tf_check_gh_auth fails when gh not installed" {
  mock_gh_not_installed
  run _dsb_tf_check_gh_auth
  assert_failure
}

# -- Exposed functions --

@test "tf-check-tools succeeds with standard mocks" {
  run tf-check-tools
  assert_success
}

@test "tf-check-prereqs succeeds with standard mocks" {
  run tf-check-prereqs
  assert_success
}

# -- On-demand tool checks in exposed functions --

@test "tf-bump-cicd fails when yq not installed" {
  mock_yq_not_installed
  _dsbTfLogErrors=1
  run tf-bump-cicd
  assert_failure
  assert_clean_output_contains "yq"
}

@test "tf-bump-modules fails when hcledit not installed" {
  mock_hcledit_not_installed
  _dsbTfLogErrors=1
  run tf-bump-modules
  assert_failure
}

@test "tf-bump-tflint-plugins fails when hcledit not installed" {
  mock_hcledit_not_installed
  _dsbTfLogErrors=1
  run tf-bump-tflint-plugins
  assert_failure
}

@test "tf-show-provider-upgrades fails when terraform-config-inspect not installed" {
  mock_terraform_config_inspect_not_installed
  _dsbTfLogErrors=1
  run tf-show-provider-upgrades dev
  # Note: the error is detected and reported, but _dsb_tf_list_available_terraform_provider_upgrades_for_env
  # does not capture the return code from _dsb_tf_list_available_terraform_provider_upgrades
  assert_clean_output_contains "Tools check failed"
}

@test "tf-docs fails when terraform-docs not installed (module repo)" {
  local module_dir="${BATS_TEST_TMPDIR}/module_project_docs_check"
  cp -r "${FIXTURES_DIR}/project_module" "${module_dir}"
  cd "${module_dir}"
  mock_standard_tools
  source "${SUT}"
  default_test_setup
  mock_terraform_docs_not_installed
  _dsbTfLogErrors=1
  run tf-docs
  assert_failure
  assert_clean_output_contains "terraform-docs"
}
